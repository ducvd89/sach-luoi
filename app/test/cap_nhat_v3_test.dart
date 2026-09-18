/// Model cũ phải được giữ nguyên khi tải bản mới lỗi; không được nhận nhầm
/// đủ file cũ là đã cập nhật tokenizer/trọng số mới.
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/core/wav.dart';
import 'package:sach_noi/services/tts/model_store.dart';
import 'package:sach_noi/services/tts/vieneu_native.dart';
import 'duong_dan_repo.dart';

void main() {
  final thuThuThat = Platform.environment['THU_V3_THAT'];
  if (thuThuThat != null) TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bản cũ không được nhận là bản mới, tải sai hash giữ nguyên dữ liệu',
    () async {
      final thu = await Directory.systemTemp.createTemp('cap-nhat-v3-');
      addTearDown(() => thu.delete(recursive: true));
      final kho = ModelStore(root: thu);
      for (final ten in goiV3.canCo) {
        final cu = File(
          p.join(thu.path, ten.replaceFirst(thuMucMoHinhV3, 'model')),
        );
        await cu.parent.create(recursive: true);
        await cu.writeAsString('trong so cu');
      }
      await kho.dictFile.writeAsString('tu dien');
      await kho.voicesFile.writeAsString(
        '{"presets":{"Của tôi":{"source":"nguoi-dung"}}}',
      );
      final giongCu = await kho.voicesFile.readAsString();
      expect(await kho.isInstalled(), isFalse);
      expect(kho.modelDir.path, endsWith(thuMucMoHinhV3));
      final khach = MockClient((yeuCau) async {
        expect(yeuCau.url.toString(), goiV3.url);
        return http.Response.bytes([1, 2, 3], 200);
      });
      addTearDown(khach.close);
      await expectLater(
        kho.download(onProgress: (_) {}, client: khach),
        throwsA(predicate((loi) => '$loi'.contains('SHA-256'))),
      );
      expect(await kho.isInstalled(), isFalse);
      expect(await kho.voicesFile.readAsString(), giongCu);
      expect(
        await File(p.join(thu.path, 'model', 'config.json')).readAsString(),
        'trong so cu',
      );
      expect(await kho.modelDir.exists(), isFalse);
      expect(
        await File(p.join(thu.path, '${goiV3.tep}.part')).exists(),
        isFalse,
      );
    },
  );

  test(
    'tải gói GitHub thật rồi đọc qua Dart và Rust',
    () async {
      final kho = ModelStore(root: Directory(thuThuThat!));
      // Chỉ bài chủ động bật bằng biến môi trường mới được dùng mạng thật.
      final chanMang = HttpOverrides.current;
      HttpOverrides.global = null;
      try {
        await kho.download(onProgress: (_) {});
      } finally {
        HttpOverrides.global = chanMang;
      }
      expect(await kho.isInstalled(), isTrue);
      final duong = await kho.paths();
      final bo = await VieNeuNative.start(
        VieNeuPaths(
          modelDir: duong.modelDir,
          codecDir: duong.codecDir,
          dictPath: duong.dictPath,
          voicesPath: duong.voicesPath,
          libraryPath: vieneuLibPath,
          threads: 4,
        ),
      );
      addTearDown(bo.close);
      expect(bo.voices, containsAll(['Minh Quân Pro', 'Kim Thanh', 'Việt Sử']));
      const loi =
          'Chào mừng bạn đến với Sách lười. Kiếm quang rực rỡ chiếu sáng '
          'bầu trời đêm, gió lạnh thổi qua đỉnh núi.';
      for (final ten in ['Minh Quân Pro', 'Kim Thanh', 'Việt Sử']) {
        final am = await bo.synthesize(loi, ten, seed: 12345);
        expect(am.samples.every((s) => s.isFinite), isTrue);
        expect(am.samples.any((s) => s.abs() > 0.05), isTrue);
        final wav = buildWav(am.samples, bo.sampleRate);
        expect(wavDuration(wav), inInclusiveRange(2, 20));
        await File(p.join(thuThuThat, '$ten.wav')).writeAsBytes(wav);
      }
    },
    skip: thuThuThat == null
        ? 'Đặt THU_V3_THAT và ORT_DYLIB_PATH để chạy'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
