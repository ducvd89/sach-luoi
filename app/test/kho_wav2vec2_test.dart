/// Tải hỏng phải có thể thử lại; file thiếu và .part không được coi là đã cài.
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sach_noi/services/kiem_am/kho_wav2vec2.dart';

void main() {
  late Directory thu;
  late KhoWav2vec2 kho;
  setUp(() async {
    thu = await Directory.systemTemp.createTemp('kho-wav2vec2-');
    kho = KhoWav2vec2(thuMuc: thu);
  });
  tearDown(() async {
    await thu.delete(recursive: true);
  });

  test(
    'HTTP lỗi, tải thiếu và gọi đồng thời không tạo trạng thái đã cài',
    () async {
      var soYeuCau = 0;
      final khach = MockClient((yeuCau) async {
        soYeuCau++;
        expect(
          yeuCau.url.toString(),
          'https://github.com/ducvd89/sach-luoi-models/releases/download/v1/'
          'wav2vec2-vi-phone-model_quantized.onnx',
        );
        return http.Response('không có mô hình', 503);
      });
      final lanMot = kho.tai(tienDo: (_) {}, mayKhach: khach);
      final lanHai = kho.tai(tienDo: (_) {}, mayKhach: khach);
      expect(identical(lanMot, lanHai), isTrue);
      await expectLater(lanMot, throwsA(isA<HttpException>()));
      expect(soYeuCau, 1);
      expect(await kho.sanSang(), isFalse);
      expect(await thu.list().toList(), isEmpty);

      final thieu = MockClient(
        (_) async => http.Response.bytes([0, 1, 2], 200),
      );
      await expectLater(
        kho.tai(tienDo: (_) {}, mayKhach: thieu),
        throwsA(isA<FormatException>()),
      );
      expect(await kho.sanSang(), isFalse);
      expect(await thu.list().toList(), isEmpty);
      khach.close();
      thieu.close();
    },
  );

  test('dấu hoàn tất giả hoặc JSON hỏng không đủ để bật mô hình', () async {
    final dau = File('${thu.path}/da-xac-minh.json');
    await dau.writeAsString('{"phienBan":"$phienBanWav2vec2"}');
    expect(await kho.sanSang(), isFalse);
    await dau.writeAsString('{');
    expect(await kho.sanSang(), isFalse);
  });
}
