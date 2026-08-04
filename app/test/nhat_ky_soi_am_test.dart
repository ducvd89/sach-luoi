/// Khung nhật ký soi âm trong màn hình xuất file: ba trạng thái của một đoạn
/// phải đọc ra được bằng mắt, và dòng mới nhất phải nằm trong tầm nhìn.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/models/export_job.dart';
import 'package:sach_noi/models/settings.dart';
import 'package:sach_noi/ui/export_page.dart';

ExportJob _job(List<MucNhatKy> nhatKy, {int chuaDat = 0}) => ExportJob(
      id: 'x',
      bookId: 'x',
      bookTitle: 'Sách thử',
      author: '',
      createdAt: DateTime.now(),
      engineId: 'vieneu',
      voiceId: 'g',
      voiceName: 'Giọng',
      speed: 1,
      pauseMs: 0,
      splitMode: SplitMode.single,
      partMinutes: 30,
      alignChapter: false,
      fromChunk: 0,
      toChunk: 100,
      outputDir: '',
      doanChuaDat: chuaDat,
      nhatKy: nhatKy,
    );

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(body: SizedBox(width: 520, child: child)),
    );

void main() {
  testWidgets('đang đọc lại thì báo đang chạy lượt kế tiếp', (tester) async {
    await tester.pumpWidget(_wrap(KhungNhatKy(
      job: _job([MucNhatKy(doan: 41, soTu: 17, soAm: 9, soLan: 2)]),
    )));

    expect(find.textContaining('Đoạn 42'), findsOneWidget);
    expect(find.textContaining('9/17 âm (53%)'), findsOneWidget);
    expect(find.textContaining('đang đọc lại lần 3'), findsOneWidget);
    // Vòng quay nhỏ ở góc khung: còn đoạn đang dở thì phải thấy nó.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('đọc lại xong đã khớp', (tester) async {
    await tester.pumpWidget(_wrap(KhungNhatKy(
      job: _job([MucNhatKy(doan: 0, soTu: 17, soAm: 17, soLan: 3, xong: true, dat: true)]),
    )));

    expect(find.textContaining('17/17 âm (100%)'), findsOneWidget);
    expect(find.textContaining('đã khớp sau 3 lượt'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('hết lượt vẫn lệch thì nói rõ là lấy bản gần nhất', (tester) async {
    await tester.pumpWidget(_wrap(KhungNhatKy(
      job: _job(
        [MucNhatKy(doan: 7, soTu: 20, soAm: 14, soLan: 6, xong: true)],
        chuaDat: 1,
      ),
    )));

    expect(find.textContaining('14/20 âm (70%)'), findsOneWidget);
    expect(find.textContaining('vẫn lệch sau 6 lượt'), findsOneWidget);
    expect(find.textContaining('1 đoạn vẫn lệch'), findsOneWidget);
  });

  testWidgets('nhiều dòng thì thấy dòng mới nhất chứ không phải dòng cũ nhất',
      (tester) async {
    await tester.pumpWidget(_wrap(KhungNhatKy(
      job: _job([
        for (var i = 0; i < 30; i++)
          MucNhatKy(doan: i, soTu: 20, soAm: 12, soLan: 6, xong: true),
      ]),
    )));

    // Khung chỉ cao 116 nên chỉ vài dòng lọt vào; dòng của đoạn cuối phải là
    // dòng thấy được, còn dòng đầu tiên thì đã trôi lên trên.
    expect(find.textContaining('Đoạn 30 ·'), findsOneWidget);
    expect(find.textContaining('Đoạn 1 ·'), findsNothing);
  });
}
