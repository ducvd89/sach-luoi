/// Kiểm thử lái danh sách chương bằng tay cầm.
///
/// Hai điều phải giữ, cả hai đều là lỗi đã gặp thật:
/// 1. Mở bảng chọn chương ra là trỏ sẵn vào chương ĐANG NGHE, không phải chương
///    đầu sách.
/// 2. Lên/xuống chỉ chạy trong danh sách. Trước đây mỗi chương là một điểm nhận
///    tiêu điểm, mà danh sách chỉ dựng những dòng đang nhìn thấy, nên tới mép là
///    dòng kế chưa tồn tại và tiêu điểm nhảy ra một ô lạc lõng bên ngoài.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/models/book.dart';
import 'package:sach_noi/services/tay_cam.dart';
import 'package:sach_noi/ui/danh_sach_chuong.dart';
import 'package:sach_noi/ui/dieu_khien_tay_cam.dart';

/// Sách 300 chương — đủ dài để chương đang nghe nằm ngoài khung nhìn.
Book _sach() {
  final chapters = [
    for (var i = 0; i < 300; i++)
      Chapter(index: i, title: 'Chương $i', firstChunk: i * 10, chunkCount: 10, charCount: 4000),
  ];
  return Book(
    id: 'sach',
    title: 'Sách thử',
    author: 'Tác giả',
    language: 'vi',
    sourceFile: '',
    format: 'txt',
    addedAt: DateTime(2026),
    chapters: chapters,
    chunkCount: 3000,
    charCount: 1200000,
    expandNumbers: true,
  );
}

void main() {
  late StreamController<LenhTayCam> lenh;
  late GlobalKey<NavigatorState> khoa;
  late List<Chapter> daChon;
  late FocusNode ngoai;

  setUp(() {
    lenh = StreamController<LenhTayCam>.broadcast();
    khoa = GlobalKey<NavigatorState>();
    daChon = [];
    ngoai = FocusNode(debugLabel: 'ngoài danh sách');
  });

  tearDown(() {
    lenh.close();
    ngoai.dispose();
  });

  /// Bảng chọn chương, kèm một nút NGOÀI danh sách để soi việc tiêu điểm có
  /// nhảy ra ngoài giữa chừng hay không.
  Widget app(Book sach, Chapter dangNghe) => MaterialApp(
        navigatorKey: khoa,
        builder: (context, child) => DieuKhienTayCam(
          khoaDieuHuong: khoa,
          nguonLenh: lenh.stream,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Column(
            children: [
              TextButton(focusNode: ngoai, onPressed: () {}, child: const Text('Ngoài')),
              Expanded(
                child: DanhSachChuong(
                  book: sach,
                  currentChapter: dangNghe,
                  tuNhanTieuDiem: true,
                  onChon: daChon.add,
                ),
              ),
            ],
          ),
        ),
      );

  Future<void> gui(WidgetTester tester, LenhTayCam l) async {
    lenh.add(l);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('mở ra là trỏ sẵn vào chương đang nghe', (tester) async {
    final sach = _sach();
    await tester.pumpWidget(app(sach, sach.chapters[120]));
    await tester.pumpAndSettle();

    // Bấm A ngay: phải ra đúng chương đang nghe chứ không phải chương đầu sách.
    await gui(tester, LenhTayCam.chon);
    expect(daChon.single.index, 120);
  });

  testWidgets('lên xuống đi từng chương một quanh chỗ đang nghe', (tester) async {
    final sach = _sach();
    await tester.pumpWidget(app(sach, sach.chapters[120]));
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.xuong);
    await gui(tester, LenhTayCam.xuong);
    await gui(tester, LenhTayCam.len);
    await gui(tester, LenhTayCam.chon);
    expect(daChon.single.index, 121);
  });

  testWidgets('đi cả chục bước vẫn không rơi ra ngoài danh sách', (tester) async {
    final sach = _sach();
    await tester.pumpWidget(app(sach, sach.chapters[120]));
    await tester.pumpAndSettle();

    // Đủ xa để chắc chắn đã đi qua mép khung nhìn nhiều lần — đúng chỗ mà bản
    // trước để tiêu điểm nhảy lung tung.
    for (var i = 0; i < 30; i++) {
      await gui(tester, LenhTayCam.xuong);
    }
    expect(ngoai.hasFocus, isFalse, reason: 'tiêu điểm không được rời khỏi danh sách');

    await gui(tester, LenhTayCam.chon);
    expect(daChon.single.index, 150);
  });

  testWidgets('tới cuối sách thì dừng chứ không chạy quá', (tester) async {
    final sach = _sach();
    await tester.pumpWidget(app(sach, sach.chapters[297]));
    await tester.pumpAndSettle();

    for (var i = 0; i < 10; i++) {
      await gui(tester, LenhTayCam.xuong);
    }
    expect(ngoai.hasFocus, isFalse, reason: 'hết sách rồi thì đứng yên, đừng văng ra ngoài');
    await gui(tester, LenhTayCam.chon);
    expect(daChon.single.index, 299, reason: 'dừng ở chương cuối');
  });

  testWidgets('chạm vào một chương vẫn chọn được như cũ', (tester) async {
    final sach = _sach();
    await tester.pumpWidget(app(sach, sach.chapters[0]));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Chương 2'));
    await tester.pumpAndSettle();
    expect(daChon.single.index, 2);
  });
}
