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

    // Sách cắt MỘT lần, không cần nhãn: mỗi lời nói đã là một Chunk riêng mang chỉ số câu thoại.
    final cat = await parseBookInBackground(bytes: bytes, fileName: ten, expandNumbers: true, removeBoilerplate: false);
    final chunks = decodeChunks(cat.chunksJson);
    final theoCau = {for (final c in chunks) if (c.cau.isNotEmpty) '${c.chapter}:${c.cau}': c};

    // Mọi lời nói Laya đã gán đều có Chunk của riêng nó, và Chunk ấy chỉ chứa chữ của lời nói đó.
    final thieu = <String>[];
    for (final e in kq.nguoiNoi.entries) {
      final c = theoCau[e.key];
      if (c == null) {
        thieu.add(e.key);
        continue;
      }
      expect(nguoiNoiCuaDoan(kq.nguoiNoi, c), e.value);
      final p = e.key.split(':');
      final doan = doanVan[int.parse(p[0])][int.parse(p[1])];
      expect(doan.contains(c.display.replaceFirst(RegExp(r'\.$'), '').trim().split(' ').first), isTrue);
    }
    expect(thieu, isEmpty, reason: 'mọi lời nói đã gán phải có Chunk riêng');
    // Lời dẫn không bao giờ mang người nói.
    expect(chunks.where((c) => c.cau.isEmpty).every((c) => nguoiNoiCuaDoan(kq.nguoiNoi, c).isEmpty), isTrue);
  }, skip: thieu, timeout: const Timeout(Duration(minutes: 10)));
}
