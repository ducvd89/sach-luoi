import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/ui/nut_sac.dart';

void main() {
  Future<void> dung(WidgetTester t, Widget con) => t.pumpWidget(
        MaterialApp(home: Scaffold(body: ListView(children: [con]))),
      );

  testWidgets('nút đứng trong Row có Spacer thì vẫn hiện', (t) async {
    await dung(
      t,
      Row(children: [
        const Text('Thư viện'),
        const Spacer(),
        NutSac(nhan: 'THÊM SÁCH', hinh: Icons.add, onNhan: () {}),
      ]),
    );
    expect(loiGanNhat(), isNull);
    expect(find.text('THÊM SÁCH'), findsOneWidget);
  });

  testWidgets('nút trải hết bề ngang thì cắt bớt chữ quá dài', (t) async {
    await dung(
      t,
      NutSac(nhan: 'MỘT CÁI NHÃN RẤT DÀI ' * 6, hinh: Icons.add, rongHet: true, onNhan: () {}),
    );
    expect(loiGanNhat(), isNull);
  });
}

Object? loiGanNhat() => TestWidgetsFlutterBinding.instance.takeException();
