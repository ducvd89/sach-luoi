/// Phân tích file sách ở isolate nền.
///
/// Giải nén EPUB, tách chương, cắt đoạn và chuẩn hoá văn bản đều là việc CPU
/// thuần: với sách dày phải mất hàng chục giây. Chạy thẳng trên isolate giao
/// diện thì cửa sổ đứng hình và Windows báo "Not Responding", nên toàn bộ được
/// đẩy sang isolate riêng, chỉ gửi về mốc tiến trình để vẽ thanh chạy.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/boilerplate.dart';
import '../core/chunker.dart';
import '../core/epub_parser.dart';
import '../core/txt_parser.dart';
import '../models/book.dart';
import '../models/work_progress.dart';

typedef ProgressCallback = void Function(WorkProgress progress);

/// Kết quả phân tích một file sách, đã sẵn sàng ghi ra đĩa.
class ParsedResult {
  const ParsedResult({
    required this.title,
    required this.author,
    required this.language,
    required this.chapters,
    required this.chunkCount,
    required this.charCount,
    required this.chunksJson,
    required this.contentHash,
    this.cleanupSummary = '',
  });

  final String title;
  final String author;
  final String language;
  final List<Chapter> chapters;
  final int chunkCount;
  final int charCount;

  /// JSON của toàn bộ đoạn — mã hoá sẵn ở isolate nền để bên kia chỉ việc ghi file.
  final String chunksJson;

  /// 8 ký tự đầu của SHA-1 nội dung file, dùng đặt mã sách.
  final String contentHash;

  /// Mô tả phần rác đã dọn, rỗng nếu sách vốn đã sạch.
  final String cleanupSummary;
}

/// Lỗi khi nhập sách. Giữ nguyên thông báo gốc để hiện thẳng cho người dùng.
class ImportException implements Exception {
  const ImportException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Phân tích file sách ở isolate nền, báo tiến trình qua [onProgress].
Future<ParsedResult> parseBookInBackground({
  required Uint8List bytes,
  required String fileName,
  required bool expandNumbers,
  bool removeBoilerplate = true,
  ProgressCallback? onProgress,
}) async {
  final receive = ReceivePort();
  final done = Completer<ParsedResult>();

  void fail(Object error) {
    if (!done.isCompleted) done.completeError(error);
  }

  final subscription = receive.listen((message) {
    if (message is WorkProgress) {
      onProgress?.call(message);
    } else if (message is ParsedResult) {
      if (!done.isCompleted) done.complete(message);
    } else if (message is _Failure) {
      fail(ImportException(message.message));
    } else if (message is List) {
      // onError của Isolate.spawn gửi [lỗi, stack] dạng chuỗi.
      fail(ImportException('${message.isEmpty ? 'Lỗi không rõ' : message.first}'));
    } else if (message == null) {
      // onExit: isolate kết thúc mà chưa gửi kết quả nào.
      fail(const ImportException('Việc đọc sách dừng giữa chừng'));
    }
  });

  try {
    await Isolate.spawn(
      _parseEntry,
      _Request(receive.sendPort, bytes, fileName, expandNumbers, removeBoilerplate),
      onError: receive.sendPort,
      onExit: receive.sendPort,
      debugName: 'nhap-sach',
      errorsAreFatal: true,
    );
    return await done.future;
  } finally {
    await subscription.cancel();
    receive.close();
  }
}

class _Request {
  const _Request(this.port, this.bytes, this.fileName, this.expandNumbers, this.removeBoilerplate);
  final SendPort port;
  final Uint8List bytes;
  final String fileName;
  final bool expandNumbers;
  final bool removeBoilerplate;
}

class _Failure {
  const _Failure(this.message);
  final String message;
}

/// Trọng số các bước, cộng lại bằng 1 — để thanh tiến trình chạy đều tay.
const _parseShare = 0.40;
const _chunkShare = 0.52;

void _parseEntry(_Request request) {
  var lastPercent = -1;
  var lastPhase = '';

  void report(String phase, double value) {
    final percent = (value * 100).round();
    if (percent == lastPercent && phase == lastPhase) return;
    lastPercent = percent;
    lastPhase = phase;
    request.port.send(WorkProgress(phase, value: value.clamp(0.0, 1.0)));
  }

  double ratio(int done, int total) => total <= 0 ? 1 : done / total;

  try {
    final extension = p.extension(request.fileName).toLowerCase();
    final baseName = p.basenameWithoutExtension(request.fileName);
    final bytes = request.bytes;
    final isZip = bytes.length > 2 && bytes[0] == 0x50 && bytes[1] == 0x4B;
    final isEpub = extension == '.epub' || (isZip && extension != '.txt');

    report(isEpub ? 'Đang giải nén EPUB…' : 'Đang đọc file văn bản…', 0.01);

    final parsed = isEpub
        ? parseEpub(
            bytes,
            onChapter: (done, total) =>
                report('Đang tách chương ($done/$total)', _parseShare * ratio(done, total)),
          )
        : parseTxt(decodeTextFile(bytes), baseName);

    // Dọn rác trước khi cắt đoạn: bỏ được cả chương mục lục thì khỏi tốn công
    // chuẩn hoá và cắt đoạn cho phần không bao giờ đọc tới.
    var chapters = parsed.chapters;
    var cleanupSummary = '';
    if (request.removeBoilerplate) {
      report('Đang dọn quảng cáo và mục lục…', _parseShare);
      final cleaned = stripBoilerplate(chapters);
      chapters = cleaned.chapters;
      cleanupSummary = cleaned.summary;
    }

    report('Đang cắt đoạn…', _parseShare);
    final result = buildChunks(
      chapters,
      expandNumbers: request.expandNumbers,
      onChapter: (done, total) => report(
        'Đang cắt đoạn và chuẩn hoá văn bản ($done/$total chương)',
        _parseShare + _chunkShare * ratio(done, total),
      ),
    );
    if (result.chunks.isEmpty) {
      throw const FormatException('Sách không có nội dung nào để đọc');
    }

    report('Đang đóng gói…', _parseShare + _chunkShare);
    final chunksJson = jsonEncode(result.chunks.map((c) => c.toJson()).toList());
    final title = parsed.title.trim().isEmpty ? baseName : parsed.title.trim();

    request.port.send(ParsedResult(
      title: title,
      author: parsed.author,
      language: parsed.language,
      chapters: result.chapters,
      chunkCount: result.chunks.length,
      charCount: result.chunks.fold<int>(0, (sum, c) => sum + c.display.length),
      chunksJson: chunksJson,
      contentHash: sha1.convert(bytes).toString().substring(0, 8),
      cleanupSummary: cleanupSummary,
    ));
  } catch (err) {
    request.port.send(_Failure(err is FormatException ? err.message : '$err'));
  }
}
