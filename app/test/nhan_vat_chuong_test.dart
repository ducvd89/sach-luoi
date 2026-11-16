// Phân tích nhân vật THEO CHƯƠNG và danh bạ nhân vật của cả sách.
//
// Hỏi Laya từng câu thoại mất ~0,1 giây, cả cuốn dày là hàng chục phút, nên người dùng phân tích
// chương đang nghe thôi. Hai điều phải giữ đúng, vì sai là giọng gán nhầm người mà không báo:
//  - chỉ chương được yêu cầu mới bị hỏi Laya và mới có nhãn người nói;
//  - nhân vật đã biết giữ NGUYÊN giọng và giới tính khi gặp lại ở chương khác (kể cả đã sửa tay),
//    và phân tích lại một chương thì thay nhãn cũ của chương ấy chứ không đếm đôi.
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/nhan_vat.dart';

/// Laya giả: chọn chủ ngữ của dòng dẫn ngay trước câu thoại (tên đứng sớm nhất trong dòng ấy).
class _LayaGia implements LayaKhach {
  final cauNguoiNoi = <String>[]; // câu thoại đã hỏi
  final cauGioiTinh = <String>[]; // tên đã hỏi giới tính

  @override
  Future<List<double>> chon(String huongDan, String doan, String? thoai, List<(String, String)> luaChon) async {
    if (thoai == null) {
      cauGioiTinh.add(RegExp('character (.+?) in').firstMatch(huongDan)!.group(1)!);
      return [0.9, 0.1];
    }
    cauNguoiNoi.add(thoai);
    final vt = doan.indexOf(thoai);
    final dong = (vt < 0 ? doan : doan.substring(0, vt)).trimRight().split('\n').last;
    var tot = 0, vi = 1 << 30;
    for (var k = 0; k < luaChon.length; k++) {
      final p = dong.indexOf(luaChon[k].$1);
      if (p >= 0 && p < vi) {
        vi = p;
        tot = k;
      }
    }
    final ra = List<double>.filled(luaChon.length, 0.02);
    ra[tot] = 1 - 0.02 * (luaChon.length - 1);
    return ra;
  }
}

List<String> _chuong(String a, String b, int soCap) => [
      for (var i = 0; i < soCap; i++) ...[
        '$a nói:',
        '“Câu thứ $i của $a.”',
        '$b hỏi:',
        '“Câu đáp thứ $i của $b?”',
      ],
      'Trời tối dần.',
    ];

void main() {
  // Chương 0: Fred và Harry. Chương 1: Fred và Ginny (Fred gặp lại, Ginny là người mới).
  final sach = [_chuong('Fred', 'Harry', 3), _chuong('Fred', 'Ginny', 3)];

  test('chỉ hỏi Laya các câu thoại của chương được yêu cầu, nhãn chỉ có ở chương ấy', () async {
    final laya = _LayaGia();
    final kq = await phanTichNhanVat(sach, laya, chuong: {1});
    expect(laya.cauNguoiNoi, hasLength(6), reason: 'chương 1 có 3 cặp = 6 câu thoại, chương 0 không bị hỏi');
    expect(laya.cauNguoiNoi.every((c) => c.contains('Fred') || c.contains('Ginny')), isTrue);
    expect(kq.nguoiNoi.keys.every((k) => k.startsWith('1:')), isTrue);
    expect({for (final n in kq.nhanVat) n.ten}, {'Fred', 'Ginny'});
  });

  test('báo tiến độ theo số câu thoại của chương được chọn, không phải cả cuốn', () async {
    var cuoi = (0, 0);
    await phanTichNhanVat(sach, _LayaGia(), chuong: {0}, tienDo: (x, t) => cuoi = (x, t));
    expect(cuoi, (6, 6));
  });

  test('nhân vật đã biết không bị hỏi giới tính lại, và giữ giới tính đã có', () async {
    final laya = _LayaGia();
    final kq = await phanTichNhanVat(sach, laya, chuong: {1}, gioiDaBiet: {'Fred': 'nu'});
    expect(laya.cauGioiTinh, isNot(contains('Fred')), reason: 'đã biết thì không gọi Laya');
    expect(laya.cauGioiTinh, contains('Ginny'));
    expect(kq.nhanVat.firstWhere((n) => n.ten == 'Fred').gioi, 'nu', reason: 'giữ nguyên chỗ người dùng đã sửa');
  });

  group('danh bạ NhanVatSach', () {
    Future<NhanVatSach> phanTich(NhanVatSach? cu, int chuong) async {
      final kq = await phanTichNhanVat(sach, _LayaGia(),
          chuong: {chuong}, gioiDaBiet: {for (final n in cu?.nhanVat ?? const <NhanVat>[]) n.ten: n.gioi});
      final nv = cu ?? NhanVatSach();
      nv.hopNhatChuong(kq, {chuong});
      return nv;
    }

    test('gặp lại nhân vật ở chương khác thì giữ giọng đã chọn; chỉ người mới được thêm', () async {
      final nv = await phanTich(null, 0);
      expect({for (final n in nv.nhanVat) n.ten}, {'Fred', 'Harry'});
      nv.tim('Fred')!.giong = 'Mạnh Dũng';
      nv.tim('Harry')!.giong = 'Xuân Vĩnh';

      await phanTich(nv, 1);
      expect({for (final n in nv.nhanVat) n.ten}, {'Fred', 'Harry', 'Ginny'});
      expect(nv.giongCua('Fred'), 'Mạnh Dũng', reason: 'Fred xuất hiện lại ở chương 1: giọng đã lưu được giữ');
      expect(nv.giongCua('Harry'), 'Xuân Vĩnh', reason: 'không có ở chương 1 nhưng vẫn còn trong danh bạ');
      expect(nv.giongCua('Ginny'), '', reason: 'người mới chưa chọn giọng');
      expect(nv.chuongDaPhanTich, {0, 1});
      expect(nv.daPhanTich(1), isTrue);
    });

    test('số câu thoại cộng đủ qua các chương và KHÔNG đếm đôi khi phân tích lại', () async {
      final nv = await phanTich(null, 0);
      await phanTich(nv, 1);
      expect(nv.tim('Fred')!.soCau, 6, reason: '3 câu ở mỗi chương');
      await phanTich(nv, 1); // phân tích lại chương 1
      await phanTich(nv, 1);
      expect(nv.tim('Fred')!.soCau, 6);
      expect(nv.nguoiNoi.length, 12);
    });

    test('phân tích lại một chương thay nhãn cũ của chương ấy, không đụng chương khác', () async {
      final nv = await phanTich(null, 0);
      await phanTich(nv, 1);
      final truocChuong0 = {for (final e in nv.nguoiNoi.entries) if (e.key.startsWith('0:')) e.key: e.value};
      nv.nguoiNoi['1:1'] = 'Nhãn cũ lạc chỗ'; // giả lập nhãn cũ cần bị thay
      await phanTich(nv, 1);
      expect(nv.nguoiNoi.containsValue('Nhãn cũ lạc chỗ'), isFalse);
      expect({for (final e in nv.nguoiNoi.entries) if (e.key.startsWith('0:')) e.key: e.value}, truocChuong0);
    });

    test('nhân vật hết câu thoại mà chưa chọn giọng thì bỏ khỏi danh bạ, đã chọn giọng thì giữ', () {
      final nv = NhanVatSach(nhanVat: [
        NhanVat(ten: 'A', gioi: 'nam', soCau: 0),
        NhanVat(ten: 'B', gioi: 'nam', soCau: 0, giong: 'Adam'),
        NhanVat(ten: 'C', gioi: 'nu', soCau: 0),
      ], nguoiNoi: {'0:1': 'C'});
      nv.tinhLaiSoCau();
      expect({for (final n in nv.nhanVat) n.ten}, {'B', 'C'});
      expect(nv.tim('C')!.soCau, 1);
    });

    test('trongChuong liệt kê ai có thoại ở chương đó', () async {
      final nv = await phanTich(null, 0);
      await phanTich(nv, 1);
      expect(nv.trongChuong(0), {'Fred', 'Harry'});
      expect(nv.trongChuong(1), {'Fred', 'Ginny'});
      expect(nv.trongChuong(7), isEmpty);
    });

    test('lưu và đọc lại giữ danh sách chương; file bản cũ (cả cuốn) vẫn đọc được', () async {
      final nv = await phanTich(null, 0);
      final lai = NhanVatSach.fromJson(nv.toJson());
      expect(lai.chuongDaPhanTich, {0});
      expect(lai.nguoiNoi, nv.nguoiNoi);

      // Bản 1 không có trường "chuong": mọi chương có nhãn coi như đã phân tích.
      final cu = NhanVatSach.fromJson({
        'phienBan': 1,
        'bat': true,
        'nhanVat': [
          {'ten': 'Fred', 'gioi': 'nam', 'soCau': 2},
        ],
        'nguoiNoi': {'0:1': 'Fred', '3:5': 'Fred'},
      });
      expect(cu.chuongDaPhanTich, {0, 3});
      expect(cu.bat, isTrue);
    });
  });
}
