// Ứng viên nhân vật gọi bằng chức vị: "Khang thân vương", "tiểu quận chúa", "Trần Tổng đà chủ".
// Truyện dịch (Lộc Đỉnh Ký) gọi nhân vật như thế suốt cả hồi; luật tên chỉ nhận chuỗi âm tiết viết
// hoa nên bỏ sót, và lời của họ bị Laya gán cho ứng viên dự phòng (Khang Hy) — đo trên hồi 10–11:
// 123 câu sai giọng chỉ vì thế.
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/nhan_vat.dart';

void main() {
  final chuong = [
    'Khang thân vương cười nói: “Tiểu huynh đệ ngồi đi.”. Vi Tiểu Bảo đáp: “Đa tạ vương gia.”.',
    'Khang thân vương lại nói: “Uống rượu đã.”. Tiểu quận chúa hỏi: “Ngươi là ai?”.',
    'Vi Tiểu Bảo cười nói: “Ta là Quế công công.”. Tiểu quận chúa lại nói: “Láo!”.',
    'Vi Tiểu Bảo nói: “Thật mà.”. Thái hậu quát: “Câm miệng!”. Thái hậu lại quát: “Lui ra!”.',
  ];

  test('nhận tên + chức vị và danh xưng viết thường làm ứng viên', () {
    final ten = {for (final (t, _) in timUngVien([chuong])) t};
    expect(ten, containsAll(['Khang thân vương', 'Tiểu quận chúa', 'Thái hậu', 'Vi Tiểu Bảo']));
    expect(ten, isNot(contains('Khang')), reason: 'không cắt cụt thành "Khang"');
  });

  test('"Trần Tổng đà chủ" là tên Trần + chức tổng đà chủ, không phải "Trần Tổng" + "đà chủ"', () {
    final c = [
      'Trần Tổng đà chủ nói: “Mời ngồi.”. Trần Tổng đà chủ lại nói: “Uống trà.”.',
      'Vi Tiểu Bảo đáp: “Vâng.”. Vi Tiểu Bảo nói: “Đa tạ.”.',
    ];
    final ten = {for (final (t, _) in timUngVien([c])) t};
    expect(ten, contains('Trần tổng đà chủ'));
    expect(ten, isNot(contains('Trần Tổng')));
  });

  test('giới tính theo chức vị và danh xưng', () async {
    expect(await doanGioiTinh(_KhongHoi(), 'Tiểu quận chúa', ''), 'nu');
    expect(await doanGioiTinh(_KhongHoi(), 'Thái hậu', ''), 'nu');
    expect(await doanGioiTinh(_KhongHoi(), 'Hồng phu nhân', ''), 'nu');
    expect(await doanGioiTinh(_KhongHoi(), 'Khang thân vương', ''), 'nam');
    expect(await doanGioiTinh(_KhongHoi(), 'Tiền lão bản', ''), 'nam');
  });
}

/// Laya không được gọi tới: giới tính phải ra từ chức vị.
class _KhongHoi implements LayaKhach {
  @override
  Future<List<double>> chon(String huongDan, String doan, String? thoai, List<(String, String)> luaChon) =>
      throw StateError('không được hỏi Laya khi chức vị đã nói giới tính');
}
