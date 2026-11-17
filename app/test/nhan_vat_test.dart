// Phân tích nhân vật: tìm ứng viên, gán người nói, đoán giới tính — với Laya giả.
//
// Laya thật cần mô hình 645 MB nên test này dùng một bản giả có hành vi dễ đoán: chọn chủ ngữ
// của dòng dẫn ngay trước câu thoại (tên đứng sớm nhất trong dòng ấy, như "Fred hỏi:").
// Thứ cần canh ở đây là phần luật và việc nối dây, không phải độ chính xác của mô hình — con số
// ấy đã đo riêng bên repo huấn luyện (HP ch.5: 84/90 tự động hoàn toàn).
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/nhan_vat.dart';

class _LayaGia implements LayaKhach {
  _LayaGia({this.tinCay = 0.9});

  final double tinCay;
  final goi = <(String, String?, List<String>)>[];

  @override
  Future<List<double>> chon(String huongDan, String doan, String? thoai, List<(String, String)> luaChon) async {
    goi.add((huongDan, thoai, [for (final (n, _) in luaChon) n]));
    if (thoai == null) {
      // giới tính: nghiêng nữ nếu đoạn trích có "nàng"
      return doan.contains('nàng') ? [0.1, 0.9] : [0.9, 0.1];
    }
    // Chủ ngữ của dòng dẫn ngay trước câu thoại: tên xuất hiện SỚM NHẤT trong dòng ấy.
    final vt = doan.indexOf(thoai);
    final truoc = vt < 0 ? doan : doan.substring(0, vt);
    final dong = truoc.trimRight().split('\n').last;
    var tot = 0, vi = 1 << 30;
    for (var k = 0; k < luaChon.length; k++) {
      final p = dong.indexOf(luaChon[k].$1);
      if (p >= 0 && p < vi) {
        vi = p;
        tot = k;
      }
    }
    final ra = List<double>.filled(luaChon.length, (1 - tinCay) / (luaChon.length - 1));
    ra[tot] = tinCay;
    return ra;
  }
}

const _chuong = [
  'Fred đưa một tay ra kéo Harry đứng lên, hồi hộp hỏi:', //                          0
  '“Nó có ăn không?”', //                                                            1  Fred
  'Harry đứng thẳng lên:', //                                                        2
  '“Có. Mà đó là cái gì vậy?”', //                                                   3  Harry
  'Fred nhe răng cười:', //                                                          4
  '“Kẹo bơ đó. Thử đi.”', //                                                        5  Fred
  'Bà Weasley nạt:', //                                                              6
  '“Hai đứa này, im ngay!”', //                                                      7  Bà Weasley
  'Harry nói:', //                                                                   8
  '“Dạ.”', //                                                                       9  Harry
  'Bà Weasley hỏi:', //                                                              10
  '“Ai đây?”', //                                                                   11 Bà Weasley
  'Rồi trời tối dần, mọi người đi ngủ.', //                                         12
];

void main() {
  test('nhận ra đoạn thoại: ngoặc kép, ngoặc nháy, gạch đầu dòng; lời dẫn thì không', () {
    expect(laDoanThoai('“Nó có ăn không?”'), isTrue);
    expect(laDoanThoai('"Đi đi."'), isTrue);
    expect(laDoanThoai('«Vâng»'), isTrue);
    expect(laDoanThoai('- Xin sư phụ biết cho con'), isTrue);
    expect(laDoanThoai('— Ai đó?'), isTrue);
    expect(laDoanThoai('Fred đưa một tay ra kéo Harry đứng lên'), isFalse);
    expect(laDoanThoai('-5 độ C ngoài trời'), isFalse, reason: 'dấu trừ dính liền số không phải gạch thoại');
    expect(laDoanThoai(''), isFalse);
  });

  test('ứng viên là tên đứng chủ ngữ ở dòng dẫn thoại, giữ chức danh, bỏ từ thường viết hoa', () {
    final ung = {for (final (t, n) in timUngVien([_chuong])) t: n};
    expect(ung.keys, containsAll(['Fred', 'Harry', 'Bà Weasley']));
    expect(ung.keys, isNot(contains('Rồi')), reason: '"rồi" có viết thường trong sách nên không phải tên');
    expect(ung.keys, isNot(contains('Weasley')), reason: 'họ trần bị bỏ khi đã có Bà Weasley');
    expect(ung['Fred']! >= toiThieuLanDan, isTrue);
  });

  test('gán người nói cho từng câu thoại và bỏ trống lời dẫn', () async {
    final kq = await phanTichNhanVat([_chuong], _LayaGia());
    String ai(int i) => kq.nguoiCua(0, i, 0);
    expect([ai(1), ai(3), ai(5), ai(7), ai(9), ai(11)],
        ['Fred', 'Harry', 'Fred', 'Bà Weasley', 'Harry', 'Bà Weasley']);
    for (final i in [0, 2, 4, 6, 8, 10, 12]) {
      expect(ai(i), '', reason: 'đoạn $i là lời dẫn nên để người dẫn đọc');
    }
  });

  test('nhân vật được xếp theo số câu, có giới tính; chức danh Bà ghi đè', () async {
    final kq = await phanTichNhanVat([_chuong], _LayaGia());
    final theoTen = {for (final n in kq.nhanVat) n.ten: n};
    expect(theoTen['Fred']!.soCau, 2);
    expect(theoTen['Harry']!.soCau, 2);
    expect(theoTen['Bà Weasley']!.soCau, 2);
    expect(theoTen['Bà Weasley']!.gioi, 'nu', reason: 'chức danh Bà thắng mọi đoán của mô hình');
    expect(theoTen['Fred']!.gioi, 'nam');
    expect([for (final n in kq.nhanVat) n.soCau], orderedEquals([...kq.nhanVat.map((n) => n.soCau)]..sort((a, b) => b.compareTo(a))));
  });

  test('Laya không chắc (dưới ngưỡng) thì để người dẫn đọc, không đoán bừa một giọng', () async {
    final kq = await phanTichNhanVat([_chuong], _LayaGia(tinCay: 0.4));
    expect(kq.nguoiNoi, isEmpty);
    expect(kq.nhanVat, isEmpty);
  });

  test('chỉ đưa Laya những tên đứng gần câu thoại cộng người dẫn đầu, không quá toiDaUngVien', () async {
    final laya = _LayaGia();
    await phanTichNhanVat([_chuong], laya);
    final nguoiNoi = laya.goi.where((g) => g.$2 != null);
    expect(nguoiNoi, isNotEmpty);
    for (final g in nguoiNoi) {
      expect(g.$1, huongDanNguoiNoi, reason: 'phải đúng chữ hướng dẫn lúc huấn luyện');
      expect(g.$3.length, inInclusiveRange(2, toiDaUngVien));
    }
  });

  test('tiến độ được báo và huỷ giữa chừng thì trả phần đã có', () async {
    final moc = <int>[];
    var dem = 0;
    final kq = await phanTichNhanVat([_chuong], _LayaGia(),
        tienDo: (x, t) => moc.add(x), huy: () => ++dem > 3);
    expect(moc, isNotEmpty);
    expect(moc.last, lessThan(6), reason: 'bị huỷ sớm nên chưa hỏi đủ 6 câu thoại');
    expect(kq.nguoiNoi.length, lessThan(6));
  });

  test('sách quá ít nhân vật (một người hoặc không ai) thì không phân tích', () async {
    final kq = await phanTichNhanVat([
      ['Trời đã tối.', 'Mọi người đi ngủ.'],
    ], _LayaGia());
    expect(kq.nhanVat, isEmpty);
    expect(kq.nguoiNoi, isEmpty);
  });

  test('NhanVat lưu và đọc lại, giọng đã chọn được giữ', () {
    final n = NhanVat(ten: 'Fred', gioi: 'nam', soCau: 8, giong: 'Mạnh Dũng');
    final lai = NhanVat.fromJson(n.toJson());
    expect((lai.ten, lai.gioi, lai.soCau, lai.giong), ('Fred', 'nam', 8, 'Mạnh Dũng'));
    expect(NhanVat(ten: 'A', gioi: 'nu', soCau: 1).toJson().containsKey('giong'), isFalse);
  });
}
