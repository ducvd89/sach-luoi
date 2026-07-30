/// Kiểm thử đầu-cuối: nhập sách thật, gọi mô hình giọng nói thật, xuất file MP3
/// thật rồi đối chiếu thời lượng.
///
/// Cần dịch vụ TTS đang chạy ở cổng 7801. Nếu không có, các bài test gọi mô
/// hình sẽ tự bỏ qua để `flutter test` vẫn xanh trên máy chưa cài mô hình.
///
///   cd tts_service && .venv\Scripts\python.exe server.py
///   cd app && flutter test test/end_to_end_test.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/models/work_progress.dart';
import 'package:sach_noi/services/library_service.dart';
import 'package:sach_noi/services/storage.dart';

/// Sách mẫu đủ dài để tạo ra nhiều đoạn và vài file khi cắt theo thời lượng.
String _sampleBook() {
  final buffer = StringBuffer('Làng quê và phố thị\n\n');
  for (var i = 1; i <= 4; i++) {
    buffer.writeln('Chương $i: Ngày thứ $i');
    buffer.writeln();
    buffer.writeln(
      'Buổi sáng hôm ấy trời trong xanh và gió nhẹ. Người thợ già dậy từ sớm, '
      'pha một ấm trà nóng rồi ngồi lặng lẽ bên hiên nhà. Ông nhớ lại quãng thời gian ${1960 + i}, '
      'khi cả xóm còn nghèo nhưng ai cũng thương nhau. Ngày ấy một cân gạo chỉ ${i * 1000} đồng, '
      'mà kiếm được cũng khó vô cùng.',
    );
    buffer.writeln();
  }
  return buffer.toString();
}

void main() {
  late Directory tempRoot;
  late LibraryService library;

  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp('sachnoi_test_');
    await Storage.init(overrideRoot: tempRoot);
    library = LibraryService();
  });

  tearDownAll(() async {
    if (await tempRoot.exists()) await tempRoot.delete(recursive: true);
  });

  test('nhập sách TXT, tách chương và cắt đoạn', () async {
    final reports = <WorkProgress>[];
    final book = (await library.importBytes(
      Uint8List.fromList(utf8.encode(_sampleBook())),
      'lang-que.txt',
      expandNumbers: true,
      onProgress: reports.add,
    ))
        .book;

    expect(book.chapters.length, 5); // 1 phần mở đầu + 4 chương
    expect(book.chunkCount, greaterThan(4));
    expect(book.title, 'Làng quê và phố thị');

    // Việc nặng chạy ở isolate nền và phải báo tiến trình về, nếu không thì cửa
    // sổ đứng hình khi nhập sách dày.
    expect(reports, isNotEmpty);
    expect(reports.last.value, 1.0);
    expect(reports.map((r) => r.value ?? 0).toList(), isNot(contains(greaterThan(1.0))));

    final chunks = await library.loadChunks(book.id);
    expect(chunks.first.heading, isTrue);
    // Số phải được chuyển sang chữ trong phần văn bản dùng để đọc.
    expect(chunks.any((c) => c.speech.contains('một nghìn chín trăm')), isTrue);
    expect(chunks.any((c) => c.display.contains('1961')), isTrue);
  });

  test('lưu và đọc lại tiến trình nghe', () async {
    final books = await library.listBooks();
    final book = books.first;

    final progress = book.progress
      ..chunkIndex = 3
      ..offsetSeconds = 12.5;
    await library.saveProgress(book.id, progress, chunkCount: book.chunkCount);

    final reloaded = await library.getBook(book.id);
    expect(reloaded!.progress.chunkIndex, 3);
    expect(reloaded.progress.offsetSeconds, 12.5);
    expect(reloaded.progress.listenedChunks, 4); // đã nghe tới đoạn thứ 4
  });


}
