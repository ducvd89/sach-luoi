/// Kiểm chứng cổng C của sea-g2p: Dart gọi ra phải giống hệt bản Python.
///
/// Nếu âm vị lệch dù chỉ một ký tự thì mô hình sẽ đọc sai, mà lỗi kiểu đó rất
/// khó phát hiện bằng tai. Các kết quả mong đợi trong bài này được sinh trực
/// tiếp từ thư viện Python đang chạy trên máy (xem scripts trong tts_service).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/services/tts/sea_g2p.dart';

/// Thư viện Rust vừa build và từ điển đi kèm engine Python.
String? _libraryPath() {
  final path = p.join(
    r'C:\Software\Ebookreader\native\sea-g2p\target\release',
    'sea_g2p_rs.dll',
  );
  return File(path).existsSync() ? path : null;
}

String? _dictPath() {
  final path = p.join(
    r'C:\Software\Ebookreader\tts_service\.venv-vieneu\Lib\site-packages\sea_g2p',
    'sea_g2p.bin',
  );
  return File(path).existsSync() ? path : null;
}

void main() {
  test('âm vị sinh ra khớp với bản Python', () {
    final lib = _libraryPath();
    final dict = _dictPath();
    if (lib == null || dict == null) {
      markTestSkipped('Chưa build thư viện sea-g2p hoặc chưa có từ điển — bỏ qua');
      return;
    }

    // Kết quả đối chiếu do chính thư viện Python sinh ra, cất sẵn thành file để
    // bài test không phải gọi Python lúc chạy.
    final expectedFile = File(p.join(
      r'C:\Software\Ebookreader\tts_service',
      'test_data',
      'am_vi_mau.json',
    ));
    if (!expectedFile.existsSync()) {
      markTestSkipped('Chưa có file đối chiếu âm vị — chạy tts_service/sinh_mau_am_vi.py');
      return;
    }

    final expected = jsonDecode(expectedFile.readAsStringSync()) as Map<String, dynamic>;
    final g2p = SeaG2p.open(dictPath: dict, libraryPath: lib);
    addTearDown(g2p.close);

    var checked = 0;
    for (final entry in (expected['cases'] as List<dynamic>)) {
      final data = entry as Map<String, dynamic>;
      final text = data['text'] as String;
      final puncNorm = data['punc_norm'] as bool;

      expect(
        g2p.phonemize(text, puncNorm: puncNorm),
        data['phonemes'] as String,
        reason: 'lệch âm vị ở: "$text"',
      );
      expect(
        g2p.normalize(text, puncNorm: puncNorm),
        data['normalized'] as String,
        reason: 'lệch chuẩn hoá ở: "$text"',
      );
      checked++;
    }

    expect(checked, greaterThan(5), reason: 'phải có đủ mẫu để tin được');
    // ignore: avoid_print
    print('Đã đối chiếu $checked câu, khớp hoàn toàn với bản Python.');
  });

  test('gọi với chuỗi rỗng và đóng hai lần không sập', () {
    final lib = _libraryPath();
    final dict = _dictPath();
    if (lib == null || dict == null) {
      markTestSkipped('Chưa build thư viện sea-g2p — bỏ qua');
      return;
    }

    final g2p = SeaG2p.open(dictPath: dict, libraryPath: lib);
    expect(g2p.phonemize(''), '');
    expect(g2p.normalize(''), '');
    g2p.close();
    g2p.close(); // đóng lại lần nữa phải im lặng bỏ qua
  });

  test('từ điển không tồn tại thì báo lỗi rõ ràng', () {
    expect(
      () => SeaG2p.open(dictPath: r'C:\khong\co\that.bin', libraryPath: _libraryPath()),
      throwsA(isA<SeaG2pException>()),
    );
  });
}
