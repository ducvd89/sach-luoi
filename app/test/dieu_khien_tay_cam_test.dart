/// Kiểm thử lớp lái giao diện bằng tay cầm: cần gạt đổi điểm chọn, A bấm,
/// B quay lại, và vòng sáng chỉ hiện khi đang dùng tay cầm.
///
/// Bơm lệnh thẳng vào qua [DieuKhienTayCam.nguonLenh] nên không cần tay cầm
/// thật, cũng không cần Windows hay Android.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/services/tay_cam.dart';
import 'package:sach_noi/ui/dieu_khien_tay_cam.dart';

void main() {
  late StreamController<LenhTayCam> lenh;
  late GlobalKey<NavigatorState> khoa;
  late List<String> daBam;
  late List<FocusNode> nut;

  setUp(() {
    lenh = StreamController<LenhTayCam>.broadcast();
    khoa = GlobalKey<NavigatorState>();
    daBam = [];
    nut = [FocusNode(debugLabel: 'một'), FocusNode(debugLabel: 'hai'), FocusNode(debugLabel: 'ba')];
  });

  tearDown(() {
    lenh.close();
    for (final n in nut) {
      n.dispose();
    }
  });

  /// Ba nút xếp dọc, nút đầu nhận tiêu điểm sẵn.
  Widget app() => MaterialApp(
        navigatorKey: khoa,
        builder: (context, child) => DieuKhienTayCam(
          khoaDieuHuong: khoa,
          nguonLenh: lenh.stream,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: Column(
            children: [
              for (var i = 0; i < 3; i++)
                TextButton(
                  focusNode: nut[i],
                  autofocus: i == 0,
                  onPressed: () => daBam.add('nút $i'),
                  child: Text('Nút $i'),
                ),
            ],
          ),
        ),
      );

  /// Gửi một lệnh rồi chờ giao diện lắng xuống.
  Future<void> gui(WidgetTester tester, LenhTayCam l) async {
    lenh.add(l);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('cần gạt xuống thì đổi sang điểm chọn kế tiếp', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(nut[0].hasFocus, isTrue);

    await gui(tester, LenhTayCam.xuong);
    expect(nut[1].hasFocus, isTrue, reason: 'phải nhảy xuống nút kế');

    await gui(tester, LenhTayCam.xuong);
    expect(nut[2].hasFocus, isTrue);

    await gui(tester, LenhTayCam.len);
    expect(nut[1].hasFocus, isTrue, reason: 'lên thì quay lại nút trên');
  });

  testWidgets('nút A bấm đúng cái đang trỏ tới', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.chon);
    expect(daBam, ['nút 0']);

    await gui(tester, LenhTayCam.xuong);
    await gui(tester, LenhTayCam.chon);
    expect(daBam, ['nút 0', 'nút 1']);
  });

  testWidgets('nút B quay lại màn hình trước', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    khoa.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Màn hình con')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Màn hình con'), findsOneWidget);

    await gui(tester, LenhTayCam.quayLai);
    await tester.pumpAndSettle();
    expect(find.text('Màn hình con'), findsNothing);
  });

  testWidgets('vòng sáng chỉ hiện khi đang dùng tay cầm', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedPositioned), findsNothing,
        reason: 'chưa đụng tới tay cầm thì đừng vẽ gì thêm');

    await gui(tester, LenhTayCam.xuong);
    expect(find.byType(AnimatedPositioned), findsOneWidget);

    // Chạm vào màn hình là người dùng đã chuyển sang tay/chuột.
    await tester.tap(find.text('Nút 2'));
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedPositioned), findsNothing);
  });

  testWidgets('đang đứng ở khung bọc cả trang thì nhảy vào điểm chọn đầu tiên',
      (tester) async {
    // Đúng hình dạng của màn hình Nghe: cả trang nằm trong một Focus để bắt
    // phím tắt, và chính nó giữ tiêu điểm lúc mở màn hình. Tính hướng từ cái
    // khung to bằng cả màn hình ấy thì chẳng ra điểm chọn nào.
    final khungTrang = FocusNode(debugLabel: 'cả trang');
    addTearDown(khungTrang.dispose);

    await tester.pumpWidget(MaterialApp(
      navigatorKey: khoa,
      builder: (context, child) => DieuKhienTayCam(
        khoaDieuHuong: khoa,
        nguonLenh: lenh.stream,
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: Focus(
          focusNode: khungTrang,
          autofocus: true,
          child: Column(
            children: [
              for (var i = 0; i < 3; i++)
                TextButton(
                  focusNode: nut[i],
                  onPressed: () => daBam.add('nút $i'),
                  child: Text('Nút $i'),
                ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(khungTrang.hasPrimaryFocus, isTrue);

    await gui(tester, LenhTayCam.xuong);
    expect(nut[0].hasFocus, isTrue, reason: 'phải vào được nút đầu tiên trong trang');
  });

  testWidgets('không có sách nào mở thì nút Y không làm sập ứng dụng', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // Bài này không có AppScope phía trên — đúng cảnh màn hình khởi động.
    await gui(tester, LenhTayCam.phatDung);
    expect(tester.takeException(), isNull);
  });
}
