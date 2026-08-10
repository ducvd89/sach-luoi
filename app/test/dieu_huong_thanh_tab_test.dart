/// Kiểm thử việc lái thanh điều hướng bằng tay cầm.
///
/// Dựng đúng hình dạng của `home_shell.dart` ở màn hình hẹp: nội dung trang có
/// điểm chọn riêng, còn thanh tab bốn mục nổi ở đáy trong một tấm kính.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/services/tay_cam.dart';
import 'package:sach_noi/ui/dieu_khien_tay_cam.dart';
import 'package:sach_noi/ui/kinh.dart';
import 'package:sach_noi/ui/nut_sac.dart';
import 'package:sach_noi/ui/theme.dart';

void main() {
  late StreamController<LenhTayCam> lenh;
  late GlobalKey<NavigatorState> khoa;

  setUp(() {
    lenh = StreamController<LenhTayCam>.broadcast();
    khoa = GlobalKey<NavigatorState>();
  });

  tearDown(() => lenh.close());

  const nhan = ['Thư viện', 'Nghe', 'Xuất file', 'Cài đặt'];

  Widget app({int dangChon = 0}) => MaterialApp(
        navigatorKey: khoa,
        builder: (context, child) => DieuKhienTayCam(
          khoaDieuHuong: khoa,
          nguonLenh: lenh.stream,
          child: child ?? const SizedBox.shrink(),
        ),
        home: Scaffold(
          extendBody: true,
          body: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 90),
              child: Column(
                children: [
                  // Đúng hình dạng LibraryPage: ListView bọc một GridView lồng
                  // trong (thêm một Scrollable nữa).
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(22, 20, 22, 26),
                      children: [
                        const Text('Thư viện'),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: 4,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 1,
                            mainAxisExtent: 234,
                          ),
                          itemBuilder: (_, i) => NutSac(
                              nhan: 'Sách $i', hinh: Icons.book, onNhan: () {}),
                        ),
                      ],
                    ),
                  ),
                  // MiniPlayer: hiện khi đang nghe dở và không ở tab Nghe.
                  Row(
                    children: [
                      const Expanded(child: Text('Đang nghe')),
                      IconButton(onPressed: () {}, icon: const Icon(Icons.skip_previous)),
                      IconButton(onPressed: () {}, icon: const Icon(Icons.play_arrow)),
                      IconButton(onPressed: () {}, icon: const Icon(Icons.skip_next)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          bottomNavigationBar: Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Kinh(
              bo: 28,
              child: NavigationBar(
                selectedIndex: dangChon,
                onDestinationSelected: (_) {},
                backgroundColor: Colors.transparent,
                indicatorColor: Colors.transparent,
                indicatorShape: const CircleBorder(),
                destinations: [
                  for (var i = 0; i < 4; i++)
                    NavigationDestination(
                      icon: const SizedBox.square(
                          dimension: 36, child: Center(child: Icon(Icons.circle))),
                      selectedIcon:
                          const HinhTronSac(hinh: Icons.circle, sac: SacNut.chinh, canh: 36),
                      label: nhan[i],
                    ),
                ],
              ),
            ),
          ),
        ),
      );

  Future<void> gui(WidgetTester tester, LenhTayCam l) async {
    lenh.add(l);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Các điểm nhận tiêu điểm nằm trong thanh tab, xếp từ trái sang phải.
  List<FocusNode> mucTrongThanh(WidgetTester tester) {
    final thanh = tester.getRect(find.byType(NavigationBar));
    return FocusManager.instance.rootScope.traversalDescendants
        .where((n) =>
            n.rect.center.dy >= thanh.top &&
            n.rect.center.dy <= thanh.bottom &&
            n.rect.width > 0)
        .toList()
      ..sort((a, b) => a.rect.center.dx.compareTo(b.rect.center.dx));
  }

  /// Mục thứ mấy trên thanh tab đang giữ tiêu điểm, null nếu tiêu điểm đã rơi
  /// ra khỏi thanh.
  int? mucDangTro(WidgetTester tester) {
    final node = FocusManager.instance.primaryFocus;
    if (node == null) return null;
    final at = mucTrongThanh(tester).indexWhere((n) => n == node);
    return at < 0 ? null : at;
  }

  testWidgets('đi hết bốn mục trên thanh tab bằng nút phải', (tester) async {
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();

    final muc = mucTrongThanh(tester);
    expect(muc.length, 4, reason: 'thanh tab phải có đúng bốn điểm chọn');

    muc.first.requestFocus();
    await tester.pumpAndSettle();
    expect(mucDangTro(tester), 0, reason: 'bắt đầu ở Thư viện');

    for (var mong = 1; mong <= 3; mong++) {
      await gui(tester, LenhTayCam.phai);
      expect(mucDangTro(tester), mong,
          reason: 'bấm phải lần $mong phải sang mục "${nhan[mong]}", '
              'không được rơi ra khỏi thanh tab');
    }

    // Quay ngược lại được đủ đường.
    for (var mong = 2; mong >= 0; mong--) {
      await gui(tester, LenhTayCam.trai);
      expect(mucDangTro(tester), mong, reason: 'trái phải lùi về "${nhan[mong]}"');
    }
  });

  testWidgets('với tới được nút ở góc phải trên dù không cùng cột', (tester) async {
    // Đúng hình dạng Thư viện: "THÊM SÁCH" nằm góc phải trên, còn "Nghe tiếp"
    // nằm mé trái trong thẻ sách — hai cái không chồng cột nào cả. Bắt buộc
    // chồng cột thì nửa trên màn hình thành ngõ cụt.
    final themSach = FocusNode(debugLabel: 'thêm sách');
    final ngheTiep = FocusNode(debugLabel: 'nghe tiếp');
    addTearDown(themSach.dispose);
    addTearDown(ngheTiep.dispose);

    await tester.pumpWidget(MaterialApp(
      navigatorKey: khoa,
      builder: (context, child) => DieuKhienTayCam(
        khoaDieuHuong: khoa,
        nguonLenh: lenh.stream,
        child: child ?? const SizedBox.shrink(),
      ),
      // Đặt theo đúng tỉ lệ đo trên máy thật (ảnh chụp 1240×1080): "THÊM SÁCH"
      // ở góc phải trên, "Nghe tiếp" mé trái giữa trang — không chồng cột nào.
      home: Scaffold(
        body: Stack(
          children: [
            Positioned(
              left: 515,
              top: 61,
              width: 253,
              height: 53,
              child: TextButton(
                focusNode: themSach,
                onPressed: () {},
                child: const Text('THÊM SÁCH'),
              ),
            ),
            Positioned(
              left: 55,
              top: 364,
              width: 174,
              height: 50,
              child: TextButton(
                focusNode: ngheTiep,
                onPressed: () {},
                child: const Text('Nghe tiếp'),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    ngheTiep.requestFocus();
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.len);
    expect(themSach.hasFocus, isTrue,
        reason: 'lên phải với tới nút ở góc phải trên, dù lệch cột');

    await gui(tester, LenhTayCam.xuong);
    expect(ngheTiep.hasFocus, isTrue, reason: 'và xuống lại được chỗ cũ');
  });

  testWidgets('thanh trải hết bề ngang vẫn là một điểm chọn', (tester) async {
    // Thanh chọn chương ở đầu màn hình Nghe rộng bằng cả màn hình mà chỉ cao
    // hơn trăm pixel. Chỉ được coi là "khung bọc cả trang" khi to ở CẢ HAI
    // chiều; đòi phải nhỏ ở cả hai thì mọi thanh ngang đều bị loại oan.
    final thanhChuong = FocusNode(debugLabel: 'thanh chương');
    final nutDuoi = FocusNode(debugLabel: 'nút dưới');
    addTearDown(thanhChuong.dispose);
    addTearDown(nutDuoi.dispose);

    await tester.pumpWidget(MaterialApp(
      navigatorKey: khoa,
      builder: (context, child) => DieuKhienTayCam(
        khoaDieuHuong: khoa,
        nguonLenh: lenh.stream,
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(
              width: double.infinity,
              height: 60,
              child: InkWell(
                focusNode: thanhChuong,
                onTap: () {},
                child: const Center(child: Text('Chương 321')),
              ),
            ),
            const Spacer(),
            TextButton(
              focusNode: nutDuoi,
              onPressed: () {},
              child: const Text('Phát'),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    nutDuoi.requestFocus();
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.len);
    expect(thanhChuong.hasFocus, isTrue,
        reason: 'phải trỏ lên được thanh chọn chương dù nó rộng hết màn hình');

    // Và vòng sáng phải vẽ cho nó — trỏ tới được mà không thấy gì thì cũng như không.
    expect(find.byType(AnimatedPositioned), findsOneWidget);
  });

  testWidgets('không khoanh vòng sáng quanh ô chiếm phần lớn màn hình', (tester) async {
    // Bảng chọn chương cao 85% màn hình và tự vẽ viền cho chương đang trỏ.
    // Khoanh thêm một vòng sáng quanh cả bảng chỉ làm chữ khó đọc.
    final bangTo = FocusNode(debugLabel: 'bảng to');
    final nutNho = FocusNode(debugLabel: 'nút nhỏ');
    addTearDown(bangTo.dispose);
    addTearDown(nutNho.dispose);

    await tester.pumpWidget(MaterialApp(
      navigatorKey: khoa,
      builder: (context, child) => DieuKhienTayCam(
        khoaDieuHuong: khoa,
        nguonLenh: lenh.stream,
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: Column(
          children: [
            TextButton(focusNode: nutNho, onPressed: () {}, child: const Text('Nút')),
            // Cao 500/600 ≈ 83% màn hình, đúng cỡ bảng chương thật (85%).
            SizedBox(
              width: double.infinity,
              height: 500,
              child: InkWell(
                focusNode: bangTo,
                onTap: () {},
                child: const Center(child: Text('Bảng chương')),
              ),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    nutNho.requestFocus();
    await tester.pumpAndSettle();
    await gui(tester, LenhTayCam.xuong);
    expect(bangTo.hasFocus, isTrue, reason: 'vẫn phải trỏ tới được');
    expect(find.byType(AnimatedPositioned), findsNothing,
        reason: 'nhưng đừng khoanh vòng sáng quanh cả bảng');
  });

  /// Bố cục màn hình rộng: thanh điều hướng DỌC bên trái, nội dung bên phải.
  Widget appRong() => MaterialApp(
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
                padding: const EdgeInsets.only(left: 92),
                child: ListView(
                  children: [
                    for (var i = 0; i < 6; i++)
                      NutSac(nhan: 'Sách $i', hinh: Icons.book, onNhan: () {}),
                  ],
                ),
              ),
              Positioned(
                left: 8,
                top: 8,
                bottom: 8,
                width: 76,
                child: Kinh(
                  bo: 26,
                  child: NavigationRail(
                    selectedIndex: 0,
                    onDestinationSelected: (_) {},
                    labelType: NavigationRailLabelType.all,
                    backgroundColor: Colors.transparent,
                    indicatorColor: Colors.transparent,
                    indicatorShape: const CircleBorder(),
                    destinations: [
                      for (var i = 0; i < 4; i++)
                        NavigationRailDestination(
                          icon: const SizedBox.square(
                              dimension: 40, child: Center(child: Icon(Icons.circle))),
                          label: Text(nhan[i]),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  /// Các điểm chọn trên thanh dọc, xếp từ trên xuống.
  List<FocusNode> mucTrongThanhDoc(WidgetTester tester) {
    final thanh = tester.getRect(find.byType(NavigationRail));
    return FocusManager.instance.rootScope.traversalDescendants
        .where((n) =>
            n.rect.width > 0 &&
            n.rect.center.dx >= thanh.left &&
            n.rect.center.dx <= thanh.right)
        .toList()
      ..sort((a, b) => a.rect.center.dy.compareTo(b.rect.center.dy));
  }

  testWidgets('thanh dọc: đi hết bốn mục bằng nút xuống, không rơi ra ngoài',
      (tester) async {
    await tester.pumpWidget(appRong());
    await tester.pumpAndSettle();

    final muc = mucTrongThanhDoc(tester);
    expect(muc.length, 4, reason: 'thanh dọc phải có đúng bốn điểm chọn');

    muc.first.requestFocus();
    await tester.pumpAndSettle();

    for (var mong = 1; mong <= 3; mong++) {
      await gui(tester, LenhTayCam.xuong);
      final at = mucTrongThanhDoc(tester)
          .indexWhere((n) => n == FocusManager.instance.primaryFocus);
      expect(at, mong,
          reason: 'xuống lần $mong phải tới "${nhan[mong]}", '
              'chứ không rơi ra khỏi thanh');
    }
  });

  testWidgets('thanh dọc: bấm phải thì sang nội dung, và phải là một điểm chọn thật',
      (tester) async {
    await tester.pumpWidget(appRong());
    await tester.pumpAndSettle();

    mucTrongThanhDoc(tester).first.requestFocus();
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.phai);
    final node = FocusManager.instance.primaryFocus!;
    final man = tester.view.physicalSize / tester.view.devicePixelRatio;

    // Đây là chỗ hỏng: tiêu điểm rơi vào khung cuộn to bằng cả trang, mà vòng
    // sáng thì không vẽ cho khung cỡ đó nên nhìn như tiêu điểm biến mất.
    expect(node.rect.width < man.width * 0.9 && node.rect.height < man.height * 0.9,
        isTrue,
        reason: 'sang phải phải rơi vào một điểm chọn thật, '
            'không phải khung cuộn bọc cả trang (${node.debugLabel})');
  });
}
