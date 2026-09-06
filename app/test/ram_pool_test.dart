/// Đo mức RAM khi bật chế độ xuất file song song.
///
/// Không phải bài test đúng/sai thông thường — nó in ra mức RAM để tìm chỗ rò.
/// Chạy riêng:
///   flutter test test/ram_pool_test.dart --reporter expanded
// ignore_for_file: avoid_print — bài này in số đo ra để đọc bằng mắt
library;

import 'dart:ffi';
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
  // `_ensure` của engine gọi `ModelStore.paths()`, mà hàm ấy chép từ điển âm vị
  // từ assets ra đĩa qua `rootBundle` — cần binding sẵn sàng trước. Thiếu dòng
  // này thì bài chết ở "Binding has not yet been initialized" ngay khi máy có
  // mô hình thật, tức là đúng lúc nó bắt đầu kiểm được thứ gì đó.
  TestWidgetsFlutterBinding.ensureInitialized();

  test('RAM khi bật rồi tắt chế độ xuất song song nhiều lần', () async {
    final root = _modelRoot();
    if (root == null || !File(_lib).existsSync() ||
        (Platform.environment['ORT_DYLIB_PATH'] ?? '').isEmpty) {
      markTestSkipped('Chưa có mô hình hoặc ORT_DYLIB_PATH — bỏ qua');
      return;
    }

    final store = ModelStore(root: root);
    // Thư mục có sẵn KHÔNG đồng nghĩa với mô hình đã tải: ứng dụng dựng nó ngay
    // lần chạy đầu để chép từ điển âm vị ra đĩa. Máy nào đã mở ứng dụng nhưng
    // chưa bấm tải mô hình thì lưới chặn ở trên lọt, rồi bài này chết ở
    // "Chưa tải mô hình giọng đọc" thay vì được bỏ qua.
    if (!await store.isInstalled()) {
      markTestSkipped('Chưa tải mô hình giọng đọc — bỏ qua');
      return;
    }
    // [OnDeviceVieNeuEngine] nạp thư viện theo TÊN TRẦN chứ không nhận đường dẫn
    // truyền vào, mà tên trần thì `flutter test` không tìm ra — thư viện nằm
    // trong native/vieneu/target/release, không phải cạnh file chạy. Bài chỉ
    // chạy được khi thư mục ấy đã nằm trong PATH; không thì bỏ qua chứ đừng đỏ.
    try {
      DynamicLibrary.open(p.basename(_lib));
    } catch (_) {
      markTestSkipped('Thư viện native không nằm trong PATH — bỏ qua '
          '(thêm ${p.dirname(_lib)} vào PATH rồi chạy lại)');
      return;
    }
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
