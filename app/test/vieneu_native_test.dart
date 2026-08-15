/// Kiểm tra thư viện native của engine VieNeu: nạp được và thấy ONNX Runtime.
///
/// Bài này chạy trước khi có mô hình — nó chỉ trả lời một câu hỏi, nhưng là câu
/// hay hỏng nhất trên Android: thư viện Rust có tìm thấy libonnxruntime không.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

import 'duong_dan_repo.dart';

final _libPath = vieneuLibPath;

void main() {
  test('thư viện native nạp được ONNX Runtime', () {
    if (!File(_libPath).existsSync()) {
      markTestSkipped('Chưa build thư viện native — bỏ qua');
      return;
    }
    // ort tìm libonnxruntime qua biến môi trường này.
    if ((Platform.environment['ORT_DYLIB_PATH'] ?? '').isEmpty) {
      markTestSkipped('Chưa đặt ORT_DYLIB_PATH — bỏ qua');
      return;
    }

    final lib = DynamicLibrary.open(_libPath);

    final abi = lib.lookupFunction<Int32 Function(), int Function()>('vieneu_abi_version')();
    expect(abi, 1);

    final ptr = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
      'vieneu_onnx_version',
    )();
    expect(ptr, isNot(nullptr), reason: 'không nạp được ONNX Runtime');

    final info = ptr.toDartString();
    lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
      'vieneu_string_free',
    )(ptr);

    // ignore: avoid_print
    print('ONNX Runtime: $info');
    expect(info, isNotEmpty);
  });
}
