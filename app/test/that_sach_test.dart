/// Chạy bộ lọc rác trên chính các file sách thật trong thư viện của người dùng.
///
/// Mẫu tự nghĩ ra bao giờ cũng dễ hơn thực tế. Bài này mở file EPUB thật, dọn,
/// rồi in ra bỏ được những gì — không có sách thì tự bỏ qua.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/core/boilerplate.dart';
import 'package:sach_noi/core/epub_parser.dart';

/// Thư mục sách của ứng dụng trên máy đang chạy test.
Directory? _booksDir() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null) return null;
  final dir = Directory(p.join(appData, 'com.sachnoi', 'Sach noi tieng Viet', 'books'));
  return dir.existsSync() ? dir : null;
}

void main() {
  test('dọn rác trên sách thật trong thư viện', () async {
    final books = _booksDir();
    if (books == null) {
      markTestSkipped('Máy này chưa có thư viện sách — bỏ qua');
      return;
    }

    final sources = books
        .listSync()
        .whereType<Directory>()
        .map((d) => File(p.join(d.path, 'source.epub')))
        .where((f) => f.existsSync())
        .toList();

    if (sources.isEmpty) {
      markTestSkipped('Chưa có sách EPUB nào trong thư viện — bỏ qua');
      return;
    }

    for (final source in sources) {
      final parsed = parseEpub(await source.readAsBytes());
      final before = parsed.chapters.fold<int>(0, (sum, c) => sum + c.text.length);

      final report = stripBoilerplate(parsed.chapters);
      final after = report.chapters.fold<int>(0, (sum, c) => sum + c.text.length);

      final saved = Duration(seconds: ((before - after) / 14.5).round());
      // ignore: avoid_print
      print('\n${p.basename(source.parent.path)}\n'
          '  ${parsed.chapters.length} chương -> ${report.chapters.length} chương\n'
          '  bỏ ${report.removedChapters} chương, ${report.removedLines} dòng\n'
          '  ${before - after} ký tự, tiết kiệm ~${saved.inMinutes} phút nghe');

      // Không được dọn quá tay: nội dung thật phải còn gần như nguyên vẹn.
      expect(report.chapters, isNotEmpty);
      expect(after, greaterThan(before * 0.5),
          reason: 'dọn mất hơn nửa cuốn sách thì chắc chắn có gì đó sai');
    }
  });
}
