// Truyện dịch kiểu Kim Dung (Thần Điêu Đại Hiệp): tên Hán-Việt nối gạch hoặc cách, thoại mở bằng
// gạch ngang, dòng bị ngắt cứng giữa câu. Chạy quy trình THẬT (tìm ứng viên, Laya, gán người nói)
// trên các hồi đã có nhãn của Opus và chấm lại.
//
// Cần: TDDH_EPUB (file EPUB), TDDH_NHAN (thư mục có hoiNN.txt và opus_hoiNN.json), LAYA_DIR,
// ORT_DYLIB_PATH và thư viện Rust đã dựng; thiếu thì tự bỏ qua. Sách có bản quyền nên không nằm
// trong repo.
//
// Vì sao có bài này: bản đầu dùng luật "tên là từ viết hoa chưa từng viết thường" (đúng cho Fred,
// Harry) và chỉ nhận ra `Khưu`, `Doãn` cùng vài mảnh lỗi OCR trên cuốn này, bỏ sót Lục Vô Song,
// Trình Anh, Dương Qua — vì âm tiết của tên Hán-Việt cũng là từ thường (trình, dương, quá).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/core/nhan_vat.dart';
import 'package:sach_noi/services/import_worker.dart';
import 'package:sach_noi/services/laya_native.dart';

void main() {
  final epub = Platform.environment['TDDH_EPUB'];
  final nhan = Platform.environment['TDDH_NHAN'];
  final thuMuc = Platform.environment['LAYA_DIR'];
  final thuVien = File(p.join(Directory.current.parent.path, 'native', 'vieneu', 'target', 'release', tenThuVienNative()));
  final thieu = epub == null || nhan == null || thuMuc == null || Platform.environment['ORT_DYLIB_PATH'] == null || !thuVien.existsSync()
      ? 'cần TDDH_EPUB, TDDH_NHAN, LAYA_DIR, ORT_DYLIB_PATH và thư viện Rust đã dựng'
      : null;

  test('ứng viên nhân vật gồm các nhân vật chính, không có mảnh rác', () async {
    final s = await doanVanSachTrongNen(bytes: File(epub!).readAsBytesSync(), fileName: 'tddh.epub');
    final ung = {for (final (t, _) in timUngVien(s.doanVan)) khoaTen(t)};
    for (final ten in ['dương qua', 'hoàng dung', 'tiểu long nữ', 'quách tỉnh', 'lục vô song', 'trình anh', 'lý mạc thu']) {
      expect(ung, contains(ten), reason: 'thiếu nhân vật chính "$ten"; có: $ung');
    }
    // Lỗi OCR và từ vụn không được lọt vào làm nhân vật.
    for (final rac in ['duơng', 'dươn', 'dườn', 'lãlùn']) {
      expect(ung, isNot(contains(rac)));
    }
  }, skip: thieu, timeout: const Timeout(Duration(minutes: 3)));

  test('gán người nói trên hồi 11, 28, 43 khớp nhãn Opus', () async {
    final s = await doanVanSachTrongNen(bytes: File(epub!).readAsBytesSync(), fileName: 'tddh.epub');
    final cac = <String, String>{'hoi11': 'Hồi 11', 'hoi28': 'Hồi 28', 'hoi43': 'Hồi 43'};
    final idx = {for (final e in cac.entries) e.key: s.tieuDe.indexWhere((t) => t.trim() == e.value)};
    expect(idx.values.every((i) => i >= 0), isTrue, reason: 'không thấy tiêu đề các hồi: $idx');

    final kq = await phanTichTrongNen(
      doanVan: s.doanVan,
      thuMucLaya: thuMuc!,
      thuVien: thuVien.path,
      chuong: idx.values.toSet(),
    );

    var tong = 0, dung = 0, sai = 0, bo = 0;
    final loi = <String>[];
    for (final e in idx.entries) {
      final dong = File(p.join(nhan!, '${e.key}.txt')).readAsLinesSync();
      final opus = jsonDecode(File(p.join(nhan, 'opus_${e.key}.json')).readAsStringSync()) as Map<String, dynamic>;
      final nguoiNoi = (opus['nguoi_noi'] as Map).cast<String, dynamic>();
      final ds = s.doanVan[e.value];
      for (final m in nguoiNoi.entries) {
        if (m.value == 'KHAC') continue;
        final goc = dong[int.parse(m.key)];
        final dau = goc.substring(0, goc.length.clamp(0, 22));
        final j = ds.indexWhere((d) => d.contains(dau));
        if (j < 0) continue; // đoạn văn đã bị nối/đổi chữ: không đối chiếu được
        tong++;
        final laya = kq.nguoiNoi.entries.where((x) => x.key.startsWith('${e.value}:$j:')).firstOrNull?.value;
        if (laya == null) {
          bo++;
        } else if (khoaTen(laya) == khoaTen(m.value as String)) {
          dung++;
        } else {
          sai++;
          if (loi.length < 12) loi.add('${e.key} dòng ${m.key}: Laya=$laya | Opus=${m.value} | ${goc.length > 50 ? goc.substring(0, 50) : goc}');
        }
      }
    }
    // ignore: avoid_print
    print('KẾT QUẢ: $tong câu có nhãn Opus: gán đúng $dung (${(100 * dung / tong).toStringAsFixed(1)}%), '
        'gán sai $sai, bỏ cho người dẫn $bo');
    // ignore: avoid_print
    for (final l in loi) {
      print('  sai: $l');
    }
    // ignore: avoid_print
    print('NHÂN VẬT: ${kq.nhanVat.take(14).map((n) => '${n.ten}(${n.gioi},${n.soCau})').join(', ')}');
    expect(tong, greaterThan(100));
    expect(dung / tong, greaterThan(0.6), reason: 'quy trình phải gán đúng người nói cho phần lớn câu');
    expect(sai / tong, lessThan(0.15), reason: 'gán nhầm giọng tệ hơn để người dẫn đọc: phải hiếm');
  }, skip: thieu, timeout: const Timeout(Duration(minutes: 15)));
}
