// Script tạm để lấy danh sách "speech" từng đoạn của một chương, phục vụ test
// tổng hợp giọng ngoài Rust — dùng đúng buildChunks/normalizeForSpeech của app.
//
// Chạy: dart tool/chunk_for_test.dart <file.txt> <ten_chuong> > out.txt
// In mỗi đoạn "speech" trên một dòng, ngăn cách bằng dòng "---".
import 'dart:io';

import '../lib/core/chunker.dart';
import '../lib/models/book.dart';

void main(List<String> args) {
  final path = args[0];
  final title = args.length > 1 ? args[1] : '';
  // parseTxt (đường nhập sách thật) chuẩn hoá CRLF trước khi cắt đoạn — làm
  // y hệt ở đây, không thì file Windows (CRLF) bị hiểu nhầm dòng trống thành
  // "\n\r\n" chứ không phải "\n\n", nên bộ tách đoạn văn không nhận ra ranh
  // giới đoạn thật.
  final text = File(path).readAsStringSync().replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  final result = buildChunks([RawChapter(title, text)]);
  for (final chunk in result.chunks) {
    stdout.write(chunk.speech);
    stdout.write('\n---\n');
  }
}
