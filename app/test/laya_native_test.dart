// Laya thật qua cầu nối Dart: cần mô hình ONNX 645 MB nên tự bỏ qua khi máy chưa có, giống các
// bài test cần mô hình khác của dự án (xem CLAUDE.md, mục "Test cần mô hình").
//
// Cần ba thứ: biến LAYA_DIR (thư mục có laya.onnx, tokenizer.json, rl_agent_config.json), thư
// viện Rust đã `cargo build --release` (đường dẫn suy từ gốc repo), và ORT_DYLIB_PATH trỏ vào một
// onnxruntime.dll. LAYA_CHUONG5 (tuỳ chọn) là file chương Harry Potter 5 đã có nhãn ở repo huấn
// luyện — bài đo end-to-end chạy trên đó.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/core/nhan_vat.dart';
import 'package:sach_noi/services/laya_native.dart';

String? _thuVien() {
  final goc = Directory.current.parent.path; // test chạy từ app/
  final f = p.join(goc, 'native', 'vieneu', 'target', 'release', tenThuVienNative());
  return File(f).existsSync() ? f : null;
}

void main() {
  final thuMuc = Platform.environment['LAYA_DIR'];
  final thuVien = _thuVien();
  final thieu = thuMuc == null || thuVien == null || Platform.environment['ORT_DYLIB_PATH'] == null
      ? 'cần LAYA_DIR, ORT_DYLIB_PATH và thư viện Rust đã dựng'
      : null;

  test('Laya thật: chọn đúng người nói và giới tính từ Dart', () async {
    final laya = LayaNative.mo(thuMuc!, thuVien: thuVien);
    addTearDown(laya.dong);
    final p1 = await laya.chon(
      huongDanNguoiNoi,
      'Fred đưa một tay ra kéo Harry đứng lên, hồi hộp hỏi:\n“Nó có ăn không?”\nHarry đứng thẳng lên:',
      '“Nó có ăn không?”',
      [for (final t in ['Harry', 'Ron', 'Fred', 'George', 'Hermione']) (t, t)],
    );
    expect(p1.length, 5);
    expect(p1.reduce((a, b) => a + b), closeTo(1, 1e-4));
    expect(p1.indexOf(p1.reduce((a, b) => a > b ? a : b)), 2, reason: 'Fred');
    // số đo bên Python (ONNX float16) cho đúng câu này: Fred ≈ 0,936
    expect(p1[2], closeTo(0.936, 0.01));

    final g = await laya.chon(
      'Is the character Lục Vô Song in `passage` male or female?',
      'Lục Vô Song vọt tới đánh một quyền vào giữa mặt y, nàng tức giận quát lớn.',
      null,
      [('nam', 'male (nam giới)'), ('nữ', 'female (nữ giới)')],
    );
    expect(g[1], greaterThan(0.9));
  }, skip: thieu);

  test('Laya thật: hỏi sai thì báo lỗi rõ, không sập', () async {
    final laya = LayaNative.mo(thuMuc!, thuVien: thuVien);
    addTearDown(laya.dong);
    expect(() => laya.chon('x', 'y', null, [('chỉ một', 'lựa chọn')]), throwsA(isA<StateError>()));
  }, skip: thieu);

  test('mở thư mục không có mô hình thì ném lỗi dễ hiểu', () {
    final tam = Directory.systemTemp.createTempSync('laya_trong');
    addTearDown(() => tam.deleteSync(recursive: true));
    expect(() => LayaNative.mo(tam.path, thuVien: thuVien),
        throwsA(isA<StateError>().having((e) => e.message, 'thông báo', contains('rl_agent_config'))));
  }, skip: thuVien == null ? 'chưa dựng thư viện Rust' : null);

  test('end-to-end trong isolate: tự tìm nhân vật và gán người nói chương HP 5', () async {
    final f = File(Platform.environment['LAYA_CHUONG5']!);
    final doanVan = [
      [for (final l in f.readAsLinesSync()) if (l.trim().isNotEmpty) l.trim()],
    ];
    var moc = 0;
    final kq = await phanTichTrongNen(
      doanVan: doanVan,
      thuMucLaya: thuMuc!,
      thuVien: thuVien,
      tienDo: (x, t) => moc = x,
    );
    // Xuất kết quả để chấm với nhãn gán tay bên Python (LAYA_RA_JSON, tuỳ chọn).
    final ra = Platform.environment['LAYA_RA_JSON'];
    if (ra != null) File(ra).writeAsStringSync(jsonEncode(kq.toJson()));
    final ten = {for (final n in kq.nhanVat) n.ten: n};
    // chương này có Harry, Ron, Fred, Percy, Bà/Ông Weasley, Hermione, Ginny...
    expect(ten.keys, containsAll(['Harry', 'Ron', 'Fred', 'Bà Weasley']));
    expect(ten['Bà Weasley']!.gioi, 'nu');
    expect(ten['Harry']!.gioi, 'nam');
    expect(kq.nguoiNoi.length, greaterThan(60), reason: '~90 câu thoại, Laya chắc chắn ở phần lớn');
    expect(moc, greaterThan(60));
  },
      skip: thieu ?? (Platform.environment['LAYA_CHUONG5'] == null ? 'cần LAYA_CHUONG5' : null),
      timeout: const Timeout(Duration(minutes: 10)));
}
