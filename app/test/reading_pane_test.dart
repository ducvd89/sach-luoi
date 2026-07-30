/// Kiểm thử khung đọc: mở đúng đoạn đang dở, nhả quyền khi người đọc cuộn, và
/// tự bám lại sau 30 giây.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/models/book.dart';
import 'package:sach_noi/ui/reading_pane.dart';

/// Một chương 200 đoạn — đủ dài để đoạn giữa chương chắc chắn nằm ngoài khung
/// nhìn, đúng tình huống mà bản trước cuộn sai.
({List<Chunk> chunks, Chapter chapter}) _book() {
  final chunks = [
    for (var i = 0; i < 200; i++)
      Chunk(index: i, chapter: 0, display: 'Đoạn thứ $i của chương thử nghiệm.',
          speech: 'Đoạn thứ $i.', heading: i == 0),
  ];
  return (
    chunks: chunks,
    chapter: const Chapter(
        index: 0, title: 'Chương thử', firstChunk: 0, chunkCount: 200, charCount: 8000),
  );
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: SizedBox(height: 600, child: child)));

void main() {
  testWidgets('mở lại sách thì thấy ngay đoạn đang dở, không phải đầu chương', (tester) async {
    final data = _book();
    await tester.pumpWidget(_wrap(ReadingPane(
      chapter: data.chapter,
      currentIndex: 120,
      chunks: data.chunks,
      onTapChunk: (_) {},
    )));
    await tester.pumpAndSettle();

    // Đoạn 120 phải nằm trong khung nhìn; đoạn 0 thì không.
    expect(find.textContaining('Đoạn thứ 120 '), findsOneWidget);
    expect(find.textContaining('Đoạn thứ 0 '), findsNothing);
  });

  testWidgets('đoạn đọc đổi thì khung tự bám theo', (tester) async {
    final data = _book();
    var current = 10;
    late StateSetter setOuter;

    await tester.pumpWidget(_wrap(StatefulBuilder(
      builder: (context, setState) {
        setOuter = setState;
        return ReadingPane(
          chapter: data.chapter,
          currentIndex: current,
          chunks: data.chunks,
          onTapChunk: (_) {},
        );
      },
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đoạn thứ 150 '), findsNothing);

    setOuter(() => current = 150);
    await tester.pumpAndSettle();
    expect(find.textContaining('Đoạn thứ 150 '), findsOneWidget);
  });

  testWidgets('người đọc cuộn thì nhả quyền, 30 giây sau bám lại', (tester) async {
    final data = _book();
    await tester.pumpWidget(_wrap(ReadingPane(
      chapter: data.chapter,
      currentIndex: 100,
      chunks: data.chunks,
      onTapChunk: (_) {},
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đoạn thứ 100 '), findsOneWidget);

    // Cuộn tay lên xem lại phần trước.
    await tester.drag(find.byType(ReadingPane), const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đoạn thứ 100 '), findsNothing,
        reason: 'đã cuộn đi thì không được giật về ngay');
    // Có nút quay lại ngay cho người không muốn đợi.
    expect(find.text('Về chỗ đang đọc'), findsOneWidget);

    // Chưa tới 30 giây thì vẫn để yên.
    await tester.pump(const Duration(seconds: 25));
    expect(find.textContaining('Đoạn thứ 100 '), findsNothing);

    // Quá 30 giây thì tự bám lại.
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đoạn thứ 100 '), findsOneWidget);
    expect(find.text('Về chỗ đang đọc'), findsNothing);
  });

  testWidgets('bấm nút quay lại thì về ngay không cần đợi', (tester) async {
    final data = _book();
    await tester.pumpWidget(_wrap(ReadingPane(
      chapter: data.chapter,
      currentIndex: 100,
      chunks: data.chunks,
      onTapChunk: (_) {},
    )));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ReadingPane), const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đoạn thứ 100 '), findsNothing);

    await tester.tap(find.text('Về chỗ đang đọc'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đoạn thứ 100 '), findsOneWidget);
  });
}
