/// Đo mức RAM khi bật chế độ xuất file song song.
///
/// Không phải bài test đúng/sai thông thường — nó in ra mức RAM để tìm chỗ rò.
/// Chạy riêng:
///   flutter test test/ram_pool_test.dart --reporter expanded
// ignore_for_file: avoid_print — bài này in số đo ra để đọc bằng mắt
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/services/tts/model_store.dart';
import 'package:sach_noi/services/tts/vieneu_engine.dart';

import 'duong_dan_repo.dart';

final _lib = vieneuLibPath;

String _rss() {
  final mb = ProcessInfo.currentRss / 1024 / 1024;
  return '${mb.round()} MB';
}

/// Thư mục mô hình thật trên máy này.
Directory? _modelRoot() {
  final appdata = Platform.environment['APPDATA'];
  if (appdata == null) return null;
  for (final ten in ['Sach luoi', 'Sach noi tieng Viet']) {
    final d = Directory(p.join(appdata, 'com.sachnoi', ten, 'vieneu'));
    if (d.existsSync()) return d;
  }
  return null;
}

void main() {
  test('RAM khi bật rồi tắt chế độ xuất song song nhiều lần', () async {
    final root = _modelRoot();
    if (root == null || !File(_lib).existsSync() ||
        (Platform.environment['ORT_DYLIB_PATH'] ?? '').isEmpty) {
      markTestSkipped('Chưa có mô hình hoặc ORT_DYLIB_PATH — bỏ qua');
      return;
    }

    final store = ModelStore(root: root);
    final engine = OnDeviceVieNeuEngine(store);
    addTearDown(engine.dispose);

    // Câu ngắn cho nhanh; mục đích là đếm RAM chứ không nghe.
    const cau = 'Buổi sáng hôm ấy trời trong xanh và gió nhẹ.';
    final voices = await engine.voices();
    final giong = voices.first.id;
    print('sau khi nạp danh sách giọng: ${_rss()}');

    await engine.synthesize(text: cau, voiceId: giong);
    print('sau đoạn đầu (1 mô hình):   ${_rss()}');

    // Bật/tắt ba lượt: nếu worker không được đóng thật thì RAM sẽ leo thang.
    for (var lan = 1; lan <= 3; lan++) {
      await engine.setBulkMode(true);
      // Chạy song song để mọi worker đều phải nạp mô hình.
      await Future.wait([
        for (var i = 0; i < 8; i++)
          engine.synthesize(text: '$cau Lượt $lan số $i.', voiceId: giong),
      ]);
      print('lượt $lan, đang bật song song:  ${_rss()}');

      await engine.setBulkMode(false);
      // Đóng isolate là việc bất đồng bộ; chờ một nhịp cho hệ điều hành thu hồi.
      await Future<void>.delayed(const Duration(seconds: 3));
      print('lượt $lan, đã tắt song song:    ${_rss()}');
    }

    // Không đặt ngưỡng cứng vì RAM phụ thuộc máy; chỉ cần thấy nó không leo
    // thang qua từng lượt. Ngưỡng rộng để bắt trường hợp rò thật sự.
    final cuoi = ProcessInfo.currentRss / 1024 / 1024;
    print('RAM cuối cùng: ${cuoi.round()} MB');
    expect(cuoi, lessThan(12000),
        reason: 'ba lượt bật/tắt không được để lại hàng chục GB');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
