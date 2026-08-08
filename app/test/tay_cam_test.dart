/// Kiểm thử phần dịch tín hiệu tay cầm thành lệnh.
///
/// Chỗ này không đụng tới máy thật nên chạy được ở mọi nơi: vùng chết, giữ để
/// lặp và chuyện nút chỉ tính lúc bấm xuống đều là logic thuần.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/services/tay_cam.dart';

/// Đưa một loạt trạng thái vào bộ dịch, mỗi lần cách nhau [buoc].
List<LenhTayCam> chay(
  BoDichTayCam bo,
  List<TrangThaiTayCam> chuoi, {
  Duration buoc = const Duration(milliseconds: 16),
  Duration tu = Duration.zero,
}) {
  final ra = <LenhTayCam>[];
  var luc = tu;
  for (final t in chuoi) {
    ra.addAll(bo.capNhat(t, luc));
    luc += buoc;
  }
  return ra;
}

void main() {
  group('Cần gạt', () {
    test('đẩy nhẹ thì không đi đâu cả', () {
      final bo = BoDichTayCam();
      // 0,4 là đã ra khỏi vùng chết của XInput nhưng chưa tới ngưỡng đi ô.
      final ra = chay(bo, List.filled(20, const TrangThaiTayCam(x: 0.4)));
      expect(ra, isEmpty);
    });

    test('đẩy hẳn sang phải thì đi đúng một ô', () {
      final bo = BoDichTayCam();
      final ra = chay(bo, List.filled(10, const TrangThaiTayCam(x: 1)));
      expect(ra, [LenhTayCam.phai], reason: 'giữ chưa đủ lâu thì chưa được lặp');
    });

    test('giữ lâu thì lặp đều', () {
      final bo = BoDichTayCam(
        choLanDau: const Duration(milliseconds: 400),
        nhipLap: const Duration(milliseconds: 100),
      );
      // Giữ 1 giây: một lần lúc đẩy, rồi lặp ở mốc 400, 500, 600, 700, 800, 900.
      final ra = chay(bo, List.filled(63, const TrangThaiTayCam(y: -1)));
      expect(ra.first, LenhTayCam.xuong);
      expect(ra.every((l) => l == LenhTayCam.xuong), isTrue);
      expect(ra.length, 7);
    });

    test('thả ra rồi đẩy lại thì tính là một lần mới', () {
      final bo = BoDichTayCam();
      final ra = chay(bo, [
        ...List.filled(5, const TrangThaiTayCam(x: -1)),
        ...List.filled(5, TrangThaiTayCam.khong),
        ...List.filled(5, const TrangThaiTayCam(x: -1)),
      ]);
      expect(ra, [LenhTayCam.trai, LenhTayCam.trai]);
    });

    test('giữ nghiêng lưng chừng không làm hướng nhấp nháy', () {
      final bo = BoDichTayCam();
      // Vào bằng cú đẩy mạnh rồi thả về mức giữa hai ngưỡng: vẫn coi là đang
      // giữ, không được nhả ra rồi bắt lại thành một lệnh nữa.
      final ra = chay(bo, [
        const TrangThaiTayCam(x: 1),
        ...List.filled(10, const TrangThaiTayCam(x: 0.45)),
      ]);
      expect(ra, [LenhTayCam.phai]);
    });

    test('đẩy chéo thì chỉ ăn theo trục lấn hơn', () {
      final bo = BoDichTayCam();
      expect(chay(bo, [const TrangThaiTayCam(x: 0.9, y: 0.6)]), [LenhTayCam.phai]);

      final bo2 = BoDichTayCam();
      expect(chay(bo2, [const TrangThaiTayCam(x: 0.6, y: 0.9)]), [LenhTayCam.len]);
    });

    test('trục dọc: dương là lên', () {
      final bo = BoDichTayCam();
      expect(chay(bo, [const TrangThaiTayCam(y: 1)]), [LenhTayCam.len]);
      final bo2 = BoDichTayCam();
      expect(chay(bo2, [const TrangThaiTayCam(y: -1)]), [LenhTayCam.xuong]);
    });
  });

  group('Nút', () {
    test('giữ nút không bắn ra hàng loạt lệnh', () {
      final bo = BoDichTayCam();
      final ra = chay(bo, List.filled(60, const TrangThaiTayCam(chon: true)));
      expect(ra, [LenhTayCam.chon]);
    });

    test('nhả rồi bấm lại thì thành hai lệnh', () {
      final bo = BoDichTayCam();
      final ra = chay(bo, const [
        TrangThaiTayCam(chon: true),
        TrangThaiTayCam.khong,
        TrangThaiTayCam(chon: true),
      ]);
      expect(ra, [LenhTayCam.chon, LenhTayCam.chon]);
    });

    test('ba nút đi đúng ba lệnh', () {
      final bo = BoDichTayCam();
      expect(chay(bo, const [TrangThaiTayCam(quayLai: true)]), [LenhTayCam.quayLai]);
      final bo2 = BoDichTayCam();
      expect(chay(bo2, const [TrangThaiTayCam(phatDung: true)]), [LenhTayCam.phatDung]);
    });

    test('bấm nút trong lúc đang giữ cần gạt thì cả hai đều tới', () {
      final bo = BoDichTayCam();
      final ra = chay(bo, const [
        TrangThaiTayCam(x: 1),
        TrangThaiTayCam(x: 1, chon: true),
      ]);
      expect(ra, [LenhTayCam.phai, LenhTayCam.chon]);
    });
  });

  group('Nút vai và cò', () {
    test('L1/L2 và R1/R2 ra lệnh chuyển tab', () {
      final bo = BoDichTayCam();
      expect(chay(bo, const [TrangThaiTayCam(vaiTrai: true)]), [LenhTayCam.tabTruoc]);
      final bo2 = BoDichTayCam();
      expect(chay(bo2, const [TrangThaiTayCam(vaiPhai: true)]), [LenhTayCam.tabSau]);
    });

    test('giữ nút vai không chạy hết cả bốn tab', () {
      final bo = BoDichTayCam();
      final ra = chay(bo, List.filled(120, const TrangThaiTayCam(vaiPhai: true)));
      expect(ra, [LenhTayCam.tabSau], reason: 'chuyển tab không được lặp khi giữ');
    });
  });

  group('Cần phải cuộn chữ', () {
    test('đẩy lên là cuộn lên, đẩy xuống là cuộn xuống', () {
      final bo = BoDichTayCam();
      expect(chay(bo, [const TrangThaiTayCam(yPhai: 1)]), [LenhTayCam.cuonLen]);
      final bo2 = BoDichTayCam();
      expect(chay(bo2, [const TrangThaiTayCam(yPhai: -1)]), [LenhTayCam.cuonXuong]);
    });

    test('cuộn chạy ngay chứ không chờ như khi đi giữa các điểm chọn', () {
      final bo = BoDichTayCam();
      // Trong 200 ms đầu: cần trái mới đi được một ô (chờ 420 ms mới lặp), còn
      // cần phải đã cuộn được vài nhịp.
      final cuon = chay(bo, List.filled(13, const TrangThaiTayCam(yPhai: -1)));
      expect(cuon.length, greaterThan(1));
      expect(cuon.every((l) => l == LenhTayCam.cuonXuong), isTrue);
    });

    test('đẩy mạnh thì cuộn nhanh hơn đẩy nhẹ', () {
      final nhe = chay(BoDichTayCam(), List.filled(63, const TrangThaiTayCam(yPhai: 0.6)));
      final manh = chay(BoDichTayCam(), List.filled(63, const TrangThaiTayCam(yPhai: 1)));
      expect(manh.length, greaterThan(nhe.length));
    });

    test('cần trái và cần phải không lẫn vào nhau', () {
      final bo = BoDichTayCam();
      final ra = chay(bo, [const TrangThaiTayCam(y: 1, yPhai: -1)]);
      expect(ra, [LenhTayCam.len, LenhTayCam.cuonXuong]);
    });
  });

  group('Vòng lặp đọc', () {
    test('không có nguồn nào thì không hỗ trợ và không nổ', () async {
      final tayCam = TayCam(onLenh: (_) {}, nguon: _NguonRong());
      expect(tayCam.hoTro, isTrue);
      await tayCam.batDau();
      await tayCam.dungLai();
    });

    test('nguồn trả về lệnh thì đi tới nơi nhận', () async {
      final nhan = <LenhTayCam>[];
      final nguon = _NguonGia();
      final tayCam = TayCam(onLenh: nhan.add, nguon: nguon);
      await tayCam.batDau();

      nguon.trangThai = const TrangThaiTayCam(chon: true);
      // Nhịp hỏi là 16 ms; chờ vài nhịp cho chắc.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await tayCam.dungLai();

      expect(nhan, contains(LenhTayCam.chon));
    });
  });
}

class _NguonRong implements NguonTayCam {
  @override
  bool get coTayCam => false;
  @override
  TrangThaiTayCam doc() => TrangThaiTayCam.khong;
  @override
  Future<void> mo(void Function() danhThuc) async {}
  @override
  Future<void> dong() async {}
}

class _NguonGia implements NguonTayCam {
  var trangThai = TrangThaiTayCam.khong;
  @override
  bool get coTayCam => true;
  @override
  TrangThaiTayCam doc() => trangThai;
  @override
  Future<void> mo(void Function() danhThuc) async {}
  @override
  Future<void> dong() async {}
}
