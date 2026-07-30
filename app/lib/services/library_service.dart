/// Thư viện sách: nhập file, đọc danh sách, lưu tiến trình nghe.
///
/// Mỗi cuốn sách là một thư mục `books/<mã sách>/` gồm meta.json (thông tin +
/// danh sách chương), chunks.json (toàn bộ đoạn đã cắt sẵn), progress.json
/// (vị trí đang nghe) và bản sao file gốc để dựng lại khi cần.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../models/book.dart';
import '../models/work_progress.dart';
import 'import_worker.dart';
import 'storage.dart';

/// Sách vừa nhập xong, kèm mô tả phần rác đã dọn để báo lại cho người dùng.
class ImportResult {
  const ImportResult(this.book, this.cleanupSummary);
  final Book book;

  /// Ví dụ "đã bỏ 2 mục lục/trang giới thiệu và 7.401 dòng quảng cáo".
  final String cleanupSummary;
}

/// Trên ngưỡng này thì việc giải mã JSON được đẩy sang isolate nền.
const _decodeInBackgroundOver = 512 * 1024;

/// Giải mã danh sách đoạn. Là hàm cấp cao nhất để chạy được ở isolate nền.
List<Chunk> decodeChunks(String text) {
  final list = jsonDecode(text) as List<dynamic>;
  return list.map((c) => Chunk.fromJson(c as Map<String, dynamic>)).toList();
}

class LibraryService {
  final _storage = Storage.instance;

  File _metaFile(String id) => File(p.join(_storage.bookDir(id).path, 'meta.json'));
  File _chunksFile(String id) => File(p.join(_storage.bookDir(id).path, 'chunks.json'));
  File _progressFile(String id) => File(p.join(_storage.bookDir(id).path, 'progress.json'));

  /// Danh sách sách, sách nghe gần đây nhất lên đầu.
  Future<List<Book>> listBooks() async {
    if (!await _storage.booksDir.exists()) return [];
    final books = <Book>[];

    await for (final entity in _storage.booksDir.list()) {
      if (entity is! Directory) continue;
      final json = await Storage.readJsonMap(_metaFile(p.basename(entity.path)));
      if (json == null) continue;
      final book = Book.fromJson(json);
      book.progress = await loadProgress(book.id);
      books.add(book);
    }

    books.sort((a, b) => b.progress.updatedAt.compareTo(a.progress.updatedAt));
    return books;
  }

  Future<Book?> getBook(String id) async {
    final json = await Storage.readJsonMap(_metaFile(id));
    if (json == null) return null;
    final book = Book.fromJson(json);
    book.progress = await loadProgress(id);
    return book;
  }

  Future<List<Chunk>> loadChunks(String id) async {
    final file = _chunksFile(id);
    if (!await file.exists()) return [];
    final String text;
    try {
      text = await file.readAsString(encoding: utf8);
    } catch (_) {
      return [];
    }
    // chunks.json của sách dày lên tới vài chục MB: giải mã ngay trên isolate
    // giao diện là đứng hình vài giây, đúng lúc người dùng vừa bấm Nghe hoặc Xuất.
    if (text.length < _decodeInBackgroundOver) return decodeChunks(text);
    return Isolate.run(() => decodeChunks(text));
  }

  Future<Progress> loadProgress(String id) async {
    final json = await Storage.readJsonMap(_progressFile(id));
    return json == null ? Progress() : Progress.fromJson(json);
  }

  Future<Progress> saveProgress(String id, Progress progress, {required int chunkCount}) async {
    progress.chunkIndex = progress.chunkIndex.clamp(0, chunkCount > 0 ? chunkCount - 1 : 0);
    if (progress.offsetSeconds < 0) progress.offsetSeconds = 0;
    // "Đã nghe xa nhất" chỉ tăng, không tụt khi người dùng tua lại.
    final reached = progress.chunkIndex + 1;
    if (reached > progress.listenedChunks) progress.listenedChunks = reached;
    progress.updatedAt = DateTime.now();
    await Storage.writeJson(_progressFile(id), progress.toJson());
    return progress;
  }

  /// Nhập một cuốn sách mới từ file trên máy.
  Future<ImportResult> importFile(
    String path, {
    required bool expandNumbers,
    bool removeBoilerplate = true,
    ProgressCallback? onProgress,
  }) async {
    onProgress?.call(const WorkProgress('Đang mở file…'));
    final bytes = await File(path).readAsBytes();
    return importBytes(
      bytes,
      p.basename(path),
      expandNumbers: expandNumbers,
      removeBoilerplate: removeBoilerplate,
      onProgress: onProgress,
    );
  }

  Future<ImportResult> importBytes(
    Uint8List bytes,
    String fileName, {
    required bool expandNumbers,
    bool removeBoilerplate = true,
    ProgressCallback? onProgress,
  }) async {
    final extension = p.extension(fileName).toLowerCase();

    // Phần nặng (giải nén, tách chương, chuẩn hoá) chạy ở isolate nền.
    final parsed = await parseBookInBackground(
      bytes: bytes,
      fileName: fileName,
      expandNumbers: expandNumbers,
      removeBoilerplate: removeBoilerplate,
      onProgress: onProgress,
    );

    final slug = _slugify(parsed.title);
    final id = '${slug.isEmpty ? 'sach' : slug}-${parsed.contentHash}';
    final book = Book(
      id: id,
      title: parsed.title,
      author: parsed.author,
      language: parsed.language,
      sourceFile: 'source$extension',
      format: extension.replaceFirst('.', '').isEmpty ? 'txt' : extension.replaceFirst('.', ''),
      addedAt: DateTime.now(),
      chapters: parsed.chapters,
      chunkCount: parsed.chunkCount,
      charCount: parsed.charCount,
      expandNumbers: expandNumbers,
    );

    onProgress?.call(const WorkProgress('Đang lưu vào thư viện…', value: 0.94));
    final dir = _storage.bookDir(id);
    await dir.create(recursive: true);
    await Storage.writeJsonText(_chunksFile(id), parsed.chunksJson);
    await Storage.writeJson(_metaFile(id), book.toJson());
    await File(p.join(dir.path, book.sourceFile)).writeAsBytes(bytes);
    if (!await _progressFile(id).exists()) {
      await Storage.writeJson(_progressFile(id), Progress().toJson());
    }

    book.progress = await loadProgress(id);
    onProgress?.call(const WorkProgress('Xong', value: 1));
    return ImportResult(book, parsed.cleanupSummary);
  }

  /// Cắt lại các đoạn, ví dụ khi bật/tắt chuẩn hoá số hay dọn quảng cáo.
  /// Giữ tiến trình nghe theo tỉ lệ.
  Future<ImportResult> rebuild(
    String id, {
    required bool expandNumbers,
    bool removeBoilerplate = true,
    ProgressCallback? onProgress,
  }) async {
    final existing = await getBook(id);
    if (existing == null) throw StateError('Không tìm thấy sách');

    final sourceFile = File(p.join(_storage.bookDir(id).path, existing.sourceFile));
    if (!await sourceFile.exists()) throw StateError('Không còn file gốc để dựng lại');

    onProgress?.call(const WorkProgress('Đang mở file gốc…'));
    final bytes = await sourceFile.readAsBytes();
    final parsed = await parseBookInBackground(
      bytes: bytes,
      fileName: existing.sourceFile,
      expandNumbers: expandNumbers,
      removeBoilerplate: removeBoilerplate,
      onProgress: onProgress,
    );

    final ratio = existing.chunkCount == 0 ? 0.0 : existing.progress.chunkIndex / existing.chunkCount;

    final book = Book(
      id: existing.id,
      title: existing.title,
      author: existing.author,
      language: existing.language,
      sourceFile: existing.sourceFile,
      format: existing.format,
      addedAt: existing.addedAt,
      chapters: parsed.chapters,
      chunkCount: parsed.chunkCount,
      charCount: parsed.charCount,
      expandNumbers: expandNumbers,
    );

    onProgress?.call(const WorkProgress('Đang lưu vào thư viện…', value: 0.94));
    await Storage.writeJsonText(_chunksFile(id), parsed.chunksJson);
    await Storage.writeJson(_metaFile(id), book.toJson());

    final progress = existing.progress
      ..chunkIndex = (ratio * book.chunkCount).floor()
      ..offsetSeconds = 0;
    book.progress = await saveProgress(id, progress, chunkCount: book.chunkCount);
    onProgress?.call(const WorkProgress('Xong', value: 1));
    return ImportResult(book, parsed.cleanupSummary);
  }

  Future<void> deleteBook(String id) async {
    final dir = _storage.bookDir(id);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

const _viMarks = {
  'à': 'a', 'á': 'a', 'ả': 'a', 'ã': 'a', 'ạ': 'a', 'ă': 'a', 'ằ': 'a', 'ắ': 'a',
  'ẳ': 'a', 'ẵ': 'a', 'ặ': 'a', 'â': 'a', 'ầ': 'a', 'ấ': 'a', 'ẩ': 'a', 'ẫ': 'a', 'ậ': 'a',
  'è': 'e', 'é': 'e', 'ẻ': 'e', 'ẽ': 'e', 'ẹ': 'e', 'ê': 'e', 'ề': 'e', 'ế': 'e',
  'ể': 'e', 'ễ': 'e', 'ệ': 'e', 'ì': 'i', 'í': 'i', 'ỉ': 'i', 'ĩ': 'i', 'ị': 'i',
  'ò': 'o', 'ó': 'o', 'ỏ': 'o', 'õ': 'o', 'ọ': 'o', 'ô': 'o', 'ồ': 'o', 'ố': 'o',
  'ổ': 'o', 'ỗ': 'o', 'ộ': 'o', 'ơ': 'o', 'ờ': 'o', 'ớ': 'o', 'ở': 'o', 'ỡ': 'o', 'ợ': 'o',
  'ù': 'u', 'ú': 'u', 'ủ': 'u', 'ũ': 'u', 'ụ': 'u', 'ư': 'u', 'ừ': 'u', 'ứ': 'u',
  'ử': 'u', 'ữ': 'u', 'ự': 'u', 'ỳ': 'y', 'ý': 'y', 'ỷ': 'y', 'ỹ': 'y', 'ỵ': 'y',
  'đ': 'd',
};

String _slugify(String text) {
  final buffer = StringBuffer();
  for (final char in text.toLowerCase().split('')) {
    buffer.write(_viMarks[char] ?? char);
  }
  final slug = buffer
      .toString()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return slug.length > 40 ? slug.substring(0, 40).replaceAll(RegExp(r'-+$'), '') : slug;
}

/// Dùng khi cần chuyển tên sách sang chuỗi không dấu (đặt tên file).
String slugify(String text) => _slugify(text);
