/// Giữ hợp đồng giữa Dart và cổng C của engine Matcha, cộng phần dọn văn bản.
///
/// Phần tra tên hàm KHÔNG cần mô hình: nó chỉ mở thư viện đã dựng. Đó là đúng
/// chỗ hay vỡ lặng lẽ nhất — đổi chữ ký bên Rust thì Dart vẫn biên dịch được,
/// chỉ sập lúc chạy khi người dùng bấm vào giọng Matcha.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/text_normalizer.dart';
import 'package:sach_noi/services/tts/matcha_native.dart';

import 'duong_dan_repo.dart';

/// Mọi hàm mà `matcha_native.dart` tra tới, kèm hai hàm giải phóng dùng chung
/// với hai engine VieNeu — bản Rust nào bỏ chúng đi thì Matcha rò bộ nhớ chứ
/// không báo lỗi.
const _hamCanCo = [
  'matcha_open',
  'matcha_close',
  'matcha_sample_rate',
  'matcha_synthesize',
  'matcha_huy',
  'matcha_last_error',
  'vieneu_samples_free',
  'vieneu_string_free',
];

void main() {
  test('thư viện native có đủ hàm của cổng Matcha', () {
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

  test('tần số lấy mẫu của Matcha là 22 050 Hz', () {
    if (!File(vieneuLibPath).existsSync()) {
      markTestSkipped('Chưa build thư viện native — bỏ qua');
      return;
    }

    final lib = DynamicLibrary.open(vieneuLibPath);
    final rate =
        lib.lookupFunction<Int32 Function(), int Function()>('matcha_sample_rate')();

    // Vocos của bộ mô hình này dựng 22 050 Hz. Khác cả 48 kHz của v3 lẫn 24 kHz
    // của v2, nên mọi phép tính thời lượng phải hỏi engine chứ đừng gán cứng.
    expect(rate, 22050);
  });

  test('mở mô hình Matcha khi chưa có file thì báo lỗi rõ ràng chứ không sập', () async {
    if (!File(vieneuLibPath).existsSync()) {
      markTestSkipped('Chưa build thư viện native — bỏ qua');
      return;
    }

    await expectLater(
      MatchaNative.start(MatchaPaths(
        encoderPath: r'C:\khong\co\that_enc.onnx',
        decoderPath: r'C:\khong\co\that_dec.onnx',
        vocoderPath: r'C:\khong\co\that_voc.onnx',
        symbolsPath: r'C:\khong\co\that.json',
        libraryPath: vieneuLibPath,
      )),
      throwsA(isA<MatchaException>()),
    );
  });

  group('bỏ thẻ tiếng Anh trước khi đưa vào Matcha', () {
    // Thẻ `<en>` là quy ước của sea-g2p. Matcha đọc thẳng mặt chữ nên không có
    // ai bóc nó ra: để nguyên là mô hình đọc thành tiếng "en" trước mỗi từ.
    test('gỡ cả thẻ mở lẫn thẻ đóng', () {
      expect(boTheEn('mua <en>iPhone</en> mới'), 'mua iPhone mới');
    });

    test('không dính hai mảnh vào nhau', () {
      // Thay bằng dấu cách chứ không xoá trắng — xoá trắng thì `a<en>B</en>c`
      // thành `aBc`, một từ khác hẳn.
      expect(boTheEn('a<en>B</en>c'), 'a B c');
    });

    test('văn bản không có thẻ thì giữ nguyên', () {
      expect(boTheEn('Hôm nay trời đẹp.'), 'Hôm nay trời đẹp.');
    });
  });
}
