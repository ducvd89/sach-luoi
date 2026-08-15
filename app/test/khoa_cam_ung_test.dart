/// Khoá cảm ứng: lớp phủ phải chắn được MỌI thao tác, và chỉ mở khi trượt đủ xa.
///
/// Bài này canh đúng điều khiến tính năng có nghĩa. Chắn hụt một đường thôi là
/// mất sạch tác dụng: người dùng bỏ máy vào túi, một cú quệt nhảy mất mười đoạn.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/ui/khoa_man_hinh.dart';

void main() {
  testWidgets('đang khoá thì nút bên dưới không nhận được chạm', (tester) async {
    var demBam = 0;
    var khoa = true;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            // Dựng lại đúng cách KhoaManHinh chắn: AbsorbPointer quanh nội dung.
            AbsorbPointer(
              absorbing: khoa,
              child: Center(
                child: ElevatedButton(
                  onPressed: () => demBam++,
                  child: const Text('Phát'),
                ),
              ),
            ),
          ],
        ),
      ),
    ));

    await tester.tap(find.text('Phát'), warnIfMissed: false);
    await tester.pump();
    expect(demBam, 0, reason: 'đang khoá mà vẫn bấm được thì lớp chắn vô dụng');

    // Mở khoá ra thì nút phải nhận lại được chạm.
    khoa = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AbsorbPointer(
          absorbing: khoa,
          child: Center(
            child: ElevatedButton(
              onPressed: () => demBam++,
              child: const Text('Phát'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Phát'));
    await tester.pump();
    expect(demBam, 1);
  });

  test('ngưỡng mở phải đủ xa để không quệt nhẹ cũng bung', () {
    expect(nguongMoKhoa, greaterThan(0.5));
  });

  group('núm phải nằm đúng dưới ngón tay', () {
    // Đúng cỡ rãnh thật: cao 62, lề 5 nên núm đường kính 52.
    const rong = 340.0, duongKinh = 52.0, le = 5.0;
    double tienDo(double x) =>
        tienDoTuToaDo(x, rong: rong, duongKinh: duongKinh, le: le);

    test('đặt ngón ở đầu rãnh thì tiến độ bằng 0', () {
      expect(tienDo(duongKinh / 2 + le), 0);
    });

    test('đặt ngón ở cuối rãnh thì tiến độ bằng 1', () {
      expect(tienDo(rong - duongKinh / 2 - le), 1);
    });

    test('ngón đi được bao nhiêu thì núm đi đúng bấy nhiêu', () {
      // Đây chính là chỗ bản trước sai: nó cộng dồn delta rồi chia cho một
      // quãng đường giả định, nên núm trôi chậm hơn ngón và phải kéo xa hơn hẳn
      // chỗ nhìn thấy.
      final quangDuong = rong - duongKinh - le * 2;
      for (final x in [80.0, 150.0, 220.0, 280.0]) {
        final keo = tienDo(x);
        // Vị trí vẽ núm trong widget: left = le + quangDuong * keo, nên tâm núm
        // nằm ở le + quangDuong*keo + duongKinh/2. Phải trùng đúng toạ độ ngón.
        final tamNum = le + quangDuong * keo + duongKinh / 2;
        expect(tamNum, closeTo(x, 0.001), reason: 'ngón ở $x mà núm ở $tamNum');
      }
    });

    test('ra ngoài hai đầu thì kẹp lại chứ không vọt', () {
      expect(tienDo(-500), 0);
      expect(tienDo(9999), 1);
    });
  });
}
