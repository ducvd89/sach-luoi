/// Kiểm thử thanh kéo chỉnh bằng tay cầm: A vào chế độ chỉnh, trái/phải đổi
/// giá trị, A chốt, B bỏ và trả về như cũ.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/services/tay_cam.dart';
import 'package:sach_noi/ui/dieu_khien_tay_cam.dart';
import 'package:sach_noi/ui/thanh_keo_tay_cam.dart';

void main() {
  late StreamController<LenhTayCam> lenh;
  late GlobalKey<NavigatorState> khoa;

  setUp(() {
    lenh = StreamController<LenhTayCam>.broadcast();
    khoa = GlobalKey<NavigatorState>();
  });
  tearDown(() => lenh.close());

  /// Thanh kéo giống ô "khoảng nghỉ giữa các đoạn": 0-2000, 40 nấc, tức mỗi
  /// bước 50. Bên dưới có một nút để soi việc tiêu điểm có bỏ đi hay không.
  Widget app(
    double batDau, {
    required void Function(double) onChanged,
    void Function(double)? onChangeEnd,
    required FocusNode nutDuoi,
  }) {
    var giaTri = batDau;
    return MaterialApp(
      navigatorKey: khoa,
      builder: (context, child) => DieuKhienTayCam(
        khoaDieuHuong: khoa,
        nguonLenh: lenh.stream,
        child: child ?? const SizedBox.shrink(),
      ),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Column(
            children: [
              ThanhKeoTayCam(
                value: giaTri,
                min: 0,
                max: 2000,
                divisions: 40,
                autofocus: true,
                onChanged: (v) {
                  setState(() => giaTri = v);
                  onChanged(v);
                },
                onChangeEnd: onChangeEnd,
              ),
              TextButton(focusNode: nutDuoi, onPressed: () {}, child: const Text('Nút dưới')),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> gui(WidgetTester tester, LenhTayCam l) async {
    lenh.add(l);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('chưa bấm A thì trái/phải vẫn là đi giữa các điểm chọn', (tester) async {
    final nutDuoi = FocusNode();
    addTearDown(nutDuoi.dispose);
    final doi = <double>[];
    await tester.pumpWidget(app(500, onChanged: doi.add, nutDuoi: nutDuoi));
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.xuong);
    expect(doi, isEmpty, reason: 'không được đổi giá trị khi chưa vào chế độ chỉnh');
    expect(nutDuoi.hasFocus, isTrue, reason: 'tiêu điểm phải đi xuống nút dưới');
  });

  testWidgets('A vào chế độ chỉnh, trái phải đổi từng nấc, A chốt', (tester) async {
    final nutDuoi = FocusNode();
    addTearDown(nutDuoi.dispose);
    final doi = <double>[];
    final chot = <double>[];
    await tester.pumpWidget(
      app(500, onChanged: doi.add, onChangeEnd: chot.add, nutDuoi: nutDuoi),
    );
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.chon);
    expect(find.textContaining('chỉnh'), findsOneWidget, reason: 'phải nói rõ đang chỉnh');

    await gui(tester, LenhTayCam.phai);
    await gui(tester, LenhTayCam.phai);
    expect(doi, [550, 600], reason: 'mỗi lần một nấc 50');

    // Lên/xuống trong lúc chỉnh không được để tiêu điểm bỏ đi.
    await gui(tester, LenhTayCam.xuong);
    expect(nutDuoi.hasFocus, isFalse);

    await gui(tester, LenhTayCam.chon);
    expect(chot, [600], reason: 'chốt đúng giá trị đang có');
    expect(find.textContaining('chỉnh'), findsNothing, reason: 'đã ra khỏi chế độ chỉnh');
  });

  testWidgets('B bỏ chế độ chỉnh và trả giá trị về như trước', (tester) async {
    final nutDuoi = FocusNode();
    addTearDown(nutDuoi.dispose);
    final doi = <double>[];
    await tester.pumpWidget(app(500, onChanged: doi.add, nutDuoi: nutDuoi));
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.chon);
    await gui(tester, LenhTayCam.trai);
    await gui(tester, LenhTayCam.trai);
    expect(doi, [450, 400]);

    await gui(tester, LenhTayCam.quayLai);
    expect(doi.last, 500, reason: 'phải trả về đúng giá trị lúc chưa chỉnh');
    expect(find.textContaining('chỉnh'), findsNothing);
  });

  testWidgets('không chỉnh gì thì B để cho màn hình quay lại như thường', (tester) async {
    final nutDuoi = FocusNode();
    addTearDown(nutDuoi.dispose);
    await tester.pumpWidget(app(500, onChanged: (_) {}, nutDuoi: nutDuoi));
    await tester.pumpAndSettle();

    khoa.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('Màn hình con')),
    ));
    await tester.pumpAndSettle();

    await gui(tester, LenhTayCam.quayLai);
    await tester.pumpAndSettle();
    expect(find.text('Màn hình con'), findsNothing);
  });
}
