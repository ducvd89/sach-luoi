/// Giữ hợp đồng giữa Dart và cổng C của engine v2.
///
/// Bài này KHÔNG cần mô hình: nó chỉ tra tên hàm trong thư viện đã dựng. Đó là
/// đúng chỗ hay vỡ lặng lẽ nhất — đổi chữ ký bên Rust thì Dart vẫn biên dịch
/// được, chỉ sập lúc chạy khi người dùng bấm vào giọng v2.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/services/tts/vieneu_v2_native.dart';

import 'duong_dan_repo.dart';

/// Mọi hàm mà `vieneu_v2_native.dart` tra tới, kèm hai hàm giải phóng dùng
/// chung với v3 — nếu bản Rust nào bỏ chúng đi thì v2 rò bộ nhớ chứ không báo lỗi.
const _hamCanCo = [
  'vieneu_v2_open',
  'vieneu_v2_close',
  'vieneu_v2_sample_rate',
  'vieneu_v2_voice_count',
  'vieneu_v2_voice_name',
  'vieneu_v2_voice_description',
  'vieneu_v2_voice_tu_them',
  'vieneu_v2_synthesize',
  'vieneu_v2_add_voice',
  'vieneu_v2_remove_voice',
  'vieneu_v2_last_error',
  'vieneu_samples_free',
  'vieneu_string_free',
];

void main() {
  test('thư viện native có đủ hàm của cổng v2', () {
    if (!File(vieneuLibPath).existsSync()) {
      markTestSkipped('Chưa build thư viện native — bỏ qua');
      return;
    }

    final lib = DynamicLibrary.open(vieneuLibPath);
    for (final ten in _hamCanCo) {
      expect(
        () => lib.lookup<NativeFunction<Void Function()>>(ten),
        returnsNormally,
        reason: 'thiếu hàm $ten trong thư viện native',
      );
    }
  });

  test('tần số lấy mẫu của v2 là 24 kHz', () {
    if (!File(vieneuLibPath).existsSync()) {
      markTestSkipped('Chưa build thư viện native — bỏ qua');
      return;
    }

    final lib = DynamicLibrary.open(vieneuLibPath);
    final rate = lib
        .lookupFunction<Int32 Function(), int Function()>('vieneu_v2_sample_rate')();

    // Không phải con số tuỳ ý: NeuCodec dựng 480 mẫu cho mỗi code, và ở 24 kHz
    // thì thành đúng 50 code cho mỗi giây tiếng. Đổi số này là mọi tính toán
    // thời lượng bên Dart lệch theo.
    expect(rate, 24000);
  });

  test('mở mô hình v2 khi chưa có file thì báo lỗi rõ ràng chứ không sập', () async {
    if (!File(vieneuLibPath).existsSync()) {
      markTestSkipped('Chưa build thư viện native — bỏ qua');
      return;
    }

    await expectLater(
      VieNeuV2Native.start(VieNeuV2Paths(
        ggufPath: r'C:\khong\co\that.gguf',
        codecPath: r'C:\khong\co\that.onnx',
        voicesPath: r'C:\khong\co\that.json',
        extraVoicesPath: r'C:\khong\co\that_extra.json',
        userVoicesPath: r'C:\khong\co\that_user.json',
        dictPath: r'C:\khong\co\that.bin',
        libraryPath: vieneuLibPath,
      )),
      throwsA(isA<VieNeuV2Exception>()),
    );
  });
}
