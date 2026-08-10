/// Kiểm thử việc cuộn trang bằng cần phải, và hai luật tiêu điểm đi kèm:
/// cuộn xong thì bắt đầu lại từ mục đầu tiên còn thấy, và trỏ tới ô nằm ngoài
/// màn hình thì trang phải cuộn theo.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/services/tay_cam.dart';
import 'package:sach_noi/ui/cuon_tay_cam.dart';
import 'package:sach_noi/ui/dieu_khien_tay_cam.dart';

void main() {
  late StreamController<LenhTayCam> lenh;
  late GlobalKey<NavigatorState> khoa;
  late ScrollController cuon;
  late List<FocusNode> nut;

  setUp(() {
    lenh = StreamController<LenhTayCam>.broadcast();
    khoa = GlobalKey<NavigatorState>();
    cuon = ScrollController();
    nut = [for (var i = 0; i < 20; i++) FocusNode(debugLabel: 'nút $i')];
  });

  tearDown(() {
    lenh.close();
    cuon.dispose();
    for (final n in nut) {
      n.dispose();
    }
  });

  /// Trang danh sách dài: 20 nút, mỗi nút cao 80 nên vượt xa khung nhìn 600.
  Widget app() => MaterialApp(
        navigatorKey: khoa,
        builder: (context, child) => DieuKhienTayCam(
          khoaDieuHuong: khoa,
          nguonLenh: lenh.stream,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          body: CuonTayCam(
            controller: cuon,
            child: ListView(
              controller: cuon,
              children: [
                for (var i = 0; i < 20; i++)
                  SizedBox(
                    height: 80,
                    child: TextButton(
                      focusNode: nut[i],
                      onPressed: () {},
                      child: Text('Nút $i'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );

  Future<void> gui(WidgetTester tester, LenhTayCam l) async {
    lenh.add(l);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('cần phải cuộn được trang danh sách', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(cuon.offset, 0);

    await gui(tester, LenhTayCam.cuonXuong);
    await tester.pumpAndSettle();
    final sauKhiCuon = cuon.offset;
    expect(sauKhiCuon, greaterThan(0), reason: 'đẩy cần phải xuống thì trang phải cuộn');

    await gui(tester, LenhTayCam.cuonLen);
    await tester.pumpAndSettle();
    expect(cuon.offset, lessThan(sauKhiCuon), reason: 'đẩy lên thì cuộn ngược lại');
  });

  testWidgets('cuộn tới đầu trang rồi thì đứng yên', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.cuonLen);
    await tester.pumpAndSettle();
    expect(cuon.offset, 0, reason: 'đang ở đầu trang, không cuộn ngược lên nữa');
  });

  testWidgets('cuộn xong bấm hướng thì bắt đầu từ mục đầu tiên đang thấy',
      (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // Đang trỏ ở nút đầu trang.
    nut[0].requestFocus();
    await tester.pumpAndSettle();

    // Cuộn thật xa, nút 0 trôi hẳn khỏi màn hình.
    cuon.jumpTo(900);
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.xuong);
    expect(nut[0].hasFocus, isFalse, reason: 'không được giữ tiêu điểm ở ô đã trôi đi');

    // Nút đầu tiên còn thấy: 900/80 ≈ 11, cho phép lệch một nút do phần đệm.
    final dangTro = nut.indexWhere((n) => n.hasFocus);
    expect(dangTro, inInclusiveRange(10, 12),
        reason: 'phải nhảy tới mục đầu tiên đang hiển thị, không phải mục kế của ô cũ');
  });

  testWidgets('không trỏ vào mục đã khuất sau thanh dưới đáy', (tester) async {
    // Đúng hình dạng khung chính: trang chừa 200px ở đáy cho thanh điều hướng
    // và thanh phát thu nhỏ. Mục cuộn quá đáy khung cuộn vẫn nằm TRONG màn hình
    // nhưng đã bị cắt và khuất sau hai thanh ấy — không được trỏ vào.
    await tester.pumpWidget(MaterialApp(
      navigatorKey: khoa,
      builder: (context, child) => DieuKhienTayCam(
        khoaDieuHuong: khoa,
        nguonLenh: lenh.stream,
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 200),
              child: ListView(
                controller: cuon,
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(
                      height: 80,
                      child: TextButton(
                        focusNode: nut[i],
                        onPressed: () {},
                        child: Text('Nút $i'),
                      ),
                    ),
                ],
              ),
            ),
            // Hai thanh nổi ở đáy, đè lên 200px cuối màn hình.
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 200,
              child: ColoredBox(color: Colors.black),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Khung cuộn cao 400 (600 - 200), nên nút cuối còn thấy trọn là nút 4.
    nut[4].requestFocus();
    await tester.pumpAndSettle();
    expect(nut[4].rect.bottom, lessThanOrEqualTo(400));

    await gui(tester, LenhTayCam.xuong);
    await tester.pumpAndSettle();

    final dangTro = nut.indexWhere((n) => n.hasFocus);
    expect(dangTro, 5, reason: 'phải sang nút kế');
    expect(nut[5].rect.bottom, lessThanOrEqualTo(400),
        reason: 'và trang phải cuộn để nó nằm trên hai thanh dưới đáy, '
            'chứ không để nó khuất phía sau');
  });

  testWidgets('trỏ tới ô ngoài màn hình thì trang cuộn theo', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    // Nút cuối cùng còn nhìn thấy trọn vẹn. Phải loại node chưa gắn vào cây:
    // rect của chúng bằng 0 nên "bottom <= 600" khớp nhầm hết.
    final cuoiManHinh = nut.lastIndexWhere(
        (n) => n.context != null && n.rect.height > 0 && n.rect.bottom <= 600);
    nut[cuoiManHinh].requestFocus();
    await tester.pumpAndSettle();
    expect(cuon.offset, 0);

    await gui(tester, LenhTayCam.xuong);
    await tester.pumpAndSettle();

    expect(cuon.offset, greaterThan(0),
        reason: 'đi xuống quá mép màn hình thì trang phải cuộn tới chỗ đó');
    final dangTro = nut.indexWhere((n) => n.hasFocus);
    expect(dangTro, cuoiManHinh + 1, reason: 'và trỏ đúng vào nút kế tiếp');
  });
}
