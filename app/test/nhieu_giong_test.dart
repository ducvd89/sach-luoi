// Đường đi thật của đọc nhiều giọng, từ file sách tới Chunk: đoạn văn đưa cho phân tích phải là
// ĐÚNG đoạn văn bộ cắt đoạn nhìn thấy, không thì nhãn người nói lệch chỗ và giọng gán nhầm người.
//
// Cần mô hình Laya (LAYA_DIR, ORT_DYLIB_PATH, thư viện Rust đã dựng) và LAYA_CHUONG5 — xem
// `laya_native_test.dart`; thiếu thì tự bỏ qua như các bài test cần mô hình khác.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/core/nhan_vat.dart';
import 'package:sach_noi/models/book.dart';
import 'package:sach_noi/services/import_worker.dart';
import 'package:sach_noi/services/laya_native.dart';
import 'package:sach_noi/services/library_service.dart';

void main() {
  final thuMuc = Platform.environment['LAYA_DIR'];
  final chuong5 = Platform.environment['LAYA_CHUONG5'];
  final thuVien = File(p.join(Directory.current.parent.path, 'native', 'vieneu', 'target', 'release', tenThuVienNative()));
  final thieu = thuMuc == null || chuong5 == null || Platform.environment['ORT_DYLIB_PATH'] == null || !thuVien.existsSync()
      ? 'cần LAYA_DIR, LAYA_CHUONG5, ORT_DYLIB_PATH và thư viện Rust đã dựng'
      : null;

  test('nhập sách -> phân tích -> cắt lại: mỗi câu thoại thành một Chunk đúng người nói', () async {
    // Mỗi dòng của chương một đoạn văn (như sách EPUB thật: mỗi <p> một đoạn), ngăn bằng dòng trống.
    final dong = [for (final l in File(chuong5!).readAsLinesSync()) if (l.trim().isNotEmpty) l.trim()];
    final bytes = Uint8List.fromList(utf8.encode(dong.join('\n\n')));
    const ten = 'chuong5.txt';

    final doanVan = (await doanVanSachTrongNen(bytes: bytes, fileName: ten, removeBoilerplate: false)).doanVan;
    final soDoan = doanVan.fold<int>(0, (a, c) => a + c.length);
    expect(soDoan, greaterThan(100), reason: 'phải tách được từng dòng thành một đoạn văn');

    final kq = await phanTichTrongNen(doanVan: doanVan, thuMucLaya: thuMuc!, thuVien: thuVien.path);
    expect(kq.nguoiNoi.length, greaterThan(60));

    // Cắt như thường: mọi Chunk không có người nói.
    final thuong = await parseBookInBackground(bytes: bytes, fileName: ten, expandNumbers: true, removeBoilerplate: false);
    final chunkThuong = decodeChunks(thuong.chunksJson);
    expect(chunkThuong.every((c) => c.speaker.isEmpty), isTrue);

    // Cắt theo người nói.
    final theo = await parseBookInBackground(
        bytes: bytes, fileName: ten, expandNumbers: true, removeBoilerplate: false, nguoiNoi: kq.nguoiNoi);
    final chunks = decodeChunks(theo.chunksJson);

    // Mỗi đoạn văn được gán người nói phải nằm trong một Chunk mang đúng người ấy. Hai câu thoại liền
    // nhau của CÙNG một người được gộp vào một Chunk (cùng người nói thì được gộp), nên kiểm theo
    // nội dung chứa chứ không đòi mỗi câu một Chunk riêng.
    var khop = 0;
    final thieu = <String>[];
    for (final e in kq.nguoiNoi.entries) {
      final doan = doanVan[int.parse(e.key.split(':')[0])][int.parse(e.key.split(':')[1])];
      final c = chunks.where((c) => c.speaker == e.value && c.display.contains(doan.substring(0, doan.length.clamp(0, 20)))).toList();
      if (c.isNotEmpty) {
        khop++;
      } else {
        final cuaNo = chunks.where((c) => c.display.contains(doan.substring(0, doan.length.clamp(0, 20)))).toList();
        thieu.add('${e.key} (${e.value}): $doan => chunk chứa nó: '
            '${[for (final c in cuaNo) '[người nói="${c.speaker}" dài ${c.display.length}: ${c.display.length > 90 ? c.display.substring(0, 90) : c.display}]']}');
      }
    }
    expect(khop, kq.nguoiNoi.length,
        reason: 'mọi câu thoại đã gán phải có Chunk riêng đúng người nói; thiếu: $thieu');

    // Không Chunk nào có người nói mà lại lẫn lời của người khác: chunk thoại chỉ chứa thoại.
    final coNguoi = chunks.where((c) => c.speaker.isNotEmpty).toList();
    expect(coNguoi.length, greaterThanOrEqualTo(kq.nguoiNoi.length));
    // Câu thoại dài quá trần 280 ký tự bị chia thành nhiều mẩu (mẩu sau không còn dấu mở thoại),
    // nên kiểm theo NỘI DUNG: mọi chữ của một Chunk có người nói phải nằm trong một câu thoại đã
    // gán cho đúng người ấy (bỏ dấu chấm cuối mà bộ cắt đoạn tự thêm khi thiếu dấu kết câu).
    // Hai câu thoại liền nhau của cùng một người gộp vào một Chunk, nên tách Chunk thành từng câu
    // thoại (ranh giới "” “") rồi kiểm từng câu.
    for (final c in coNguoi) {
      final cuaNguoiNay = [
        for (final e in kq.nguoiNoi.entries)
          if (e.value == c.speaker) doanVan[int.parse(e.key.split(':')[0])][int.parse(e.key.split(':')[1])],
      ];
      for (final mau in c.display.trim().split(RegExp('(?<=”)\\s+(?=“)'))) {
        final chu = mau.trim().replaceFirst(RegExp(r'\.$'), '');
        expect(cuaNguoiNay.any((d) => d.contains(chu)), isTrue,
            reason: 'Chunk của ${c.speaker} chứa chữ không thuộc câu thoại nào của họ: "$chu" trong ${c.display}');
      }
    }
    // Cắt theo người nói cho nhiều Chunk hơn (câu thoại không bị gộp với lời dẫn).
    expect(chunks.length, greaterThan(chunkThuong.length));
    // Vẫn đủ chữ: tổng độ dài hiển thị không đổi đáng kể.
    int tong(List<Chunk> l) => l.fold(0, (a, c) => a + c.display.length);
    expect((tong(chunks) - tong(chunkThuong)).abs(), lessThan(tong(chunkThuong) ~/ 20));
  }, skip: thieu, timeout: const Timeout(Duration(minutes: 10)));
}
