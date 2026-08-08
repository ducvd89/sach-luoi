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

  testWidgets('đoạn văn không nằm trong đường đi của tay cầm', (tester) async {
    // Từng đoạn văn là một InkWell nên mặc định nhận được tiêu điểm. Với tay cầm
    // thì cả chương 200 đoạn thành 200 điểm chọn: gạt cần xuống một cái là trôi
    // vào giữa bài đọc rồi cuộn mãi không ra được.
    final data = _book();
    final tren = FocusNode(debugLabel: 'trên');
    final duoi = FocusNode(debugLabel: 'dưới');
    addTearDown(tren.dispose);
    addTearDown(duoi.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            TextButton(
              focusNode: tren,
              autofocus: true,
              onPressed: () {},
              child: const Text('Trên'),
            ),
            Expanded(
              child: ReadingPane(
                chapter: data.chapter,
                currentIndex: 0,
                chunks: data.chunks,
                onTapChunk: (_) {},
              ),
            ),
            TextButton(focusNode: duoi, onPressed: () {}, child: const Text('Dưới')),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tren.hasFocus, isTrue);

    // Một bước xuống phải sang thẳng nút dưới, không rơi vào giữa bài đọc.
    tren.focusInDirection(TraversalDirection.down);
    await tester.pumpAndSettle();
    expect(duoi.hasFocus, isTrue);
  });

  testWidgets('chạm vào đoạn văn vẫn nhảy tới đoạn ấy như cũ', (tester) async {
    // Bỏ khỏi đường tiêu điểm KHÔNG được làm mất khả năng chạm: hai việc đó đi
    // bằng hai đường khác nhau, nhưng lỡ chặn quá tay thì người dùng chuột và
    // cảm ứng mất hẳn cách nhảy tới một đoạn.
    final data = _book();
    final daBam = <int>[];
    await tester.pumpWidget(_wrap(ReadingPane(
      chapter: data.chapter,
      currentIndex: 0,
      chunks: data.chunks,
      onTapChunk: daBam.add,
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('Đoạn thứ 3 '));
    await tester.pumpAndSettle();
    expect(daBam, [3]);
  });
}
