/// Chạy engine VieNeu trong ứng dụng, không qua Python.
///
/// Đây là đúng đường mà điện thoại sẽ đi: Dart -> isolate nền -> thư viện Rust
/// -> ONNX Runtime. Chạy được trên Windows nghĩa là logic đã đúng; phần còn lại
/// trên Android chỉ là khác kiến trúc máy.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/core/wav.dart';
import 'package:sach_noi/services/tts/vieneu_engine.dart';
import 'package:sach_noi/services/tts/model_store.dart';
import 'package:sach_noi/services/tts/vieneu_native.dart';

const _lib = r'C:\Software\Ebookreader\native\vieneu\target\release\sachnoi_vieneu.dll';

/// Mô hình đã tải sẵn trong cache của HuggingFace — khỏi tải lại 206 MB.
VieNeuPaths? _paths() {
  final home = Platform.environment['USERPROFILE'];
  if (home == null || !File(_lib).existsSync()) return null;

  final hub = p.join(home, '.cache', 'huggingface', 'hub');
  final modelRoot = Directory(p.join(hub, 'models--pnnbao-ump--VieNeu-TTS-v3-Turbo', 'snapshots'));
  final codecRoot =
      Directory(p.join(hub, 'models--OpenMOSS-Team--MOSS-Audio-Tokenizer-Nano-ONNX', 'snapshots'));
  if (!modelRoot.existsSync() || !codecRoot.existsSync()) return null;

  final model = p.join(modelRoot.listSync().whereType<Directory>().first.path, 'onnx_int8');
  final codec = codecRoot.listSync().whereType<Directory>().first.path;
  final dict = p.join(r'C:\Software\Ebookreader\app\assets', 'sea_g2p.bin');
  final voices = p.join(r'C:\Software\Ebookreader\app\assets', 'giong.json');

  if (!Directory(model).existsSync() || !File(dict).existsSync()) return null;
  return VieNeuPaths(
    modelDir: model,
    codecDir: codec,
    dictPath: dict,
    voicesPath: voices,
    libraryPath: _lib,
    threads: 4,
  );
}

void main() {
  test('đọc được một câu, ra WAV nghe được', () async {
    final paths = _paths();
    if (paths == null || (Platform.environment['ORT_DYLIB_PATH'] ?? '').isEmpty) {
      markTestSkipped('Chưa có mô hình hoặc chưa đặt ORT_DYLIB_PATH — bỏ qua');
      return;
    }

    final started = DateTime.now();
    final engine = await VieNeuNative.start(paths);
    addTearDown(engine.close);
    // ignore: avoid_print
    print('Nạp mô hình: ${DateTime.now().difference(started).inMilliseconds} ms');

    expect(engine.sampleRate, 48000);
    expect(engine.voices, isNotEmpty);
    expect(engine.voices, contains('Việt Sử'));

    final at = DateTime.now();
    final samples = await engine.synthesize(
      'Xin chào, đây là bản đọc thử của ứng dụng sách nói.',
      engine.voices.first,
      seed: 12345,
    );
    final elapsed = DateTime.now().difference(at).inMilliseconds / 1000;
    final seconds = samples.length / engine.sampleRate;
    // ignore: avoid_print
    print('Đọc ${seconds.toStringAsFixed(2)}s trong ${elapsed.toStringAsFixed(2)}s '
        '(nhanh gấp ${(seconds / elapsed).toStringAsFixed(2)} lần)');

    expect(seconds, greaterThan(1.0), reason: 'câu này phải ra ít nhất một giây tiếng');
    expect(seconds, lessThan(30.0));

    // Phải là tiếng nói thật chứ không phải im lặng hay nhiễu.
    var peak = 0.0;
    var energy = 0.0;
    for (final s in samples) {
      final a = s.abs();
      if (a > peak) peak = a;
      energy += s * s;
    }
    final rms = (energy / samples.length);
    expect(peak, greaterThan(0.05), reason: 'âm thanh gần như im lặng');
    expect(peak, lessThanOrEqualTo(1.0));
    expect(rms, greaterThan(1e-5), reason: 'không có năng lượng — nhiễu trắng hay im lặng?');

    // Đóng gói WAV phải đọc lại được.
    final wav = buildWav(samples, engine.sampleRate);
    final info = readWavInfo(wav);
    expect(info, isNotNull);
    expect(info!.sampleRate, 48000);
    expect(wavDuration(wav), closeTo(seconds, 0.01));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('cùng một đoạn cho ra cùng kết quả', () async {
    final paths = _paths();
    if (paths == null || (Platform.environment['ORT_DYLIB_PATH'] ?? '').isEmpty) {
      markTestSkipped('Chưa có mô hình — bỏ qua');
      return;
    }

    final engine = await VieNeuNative.start(paths);
    addTearDown(engine.close);

    const text = 'Họ sống chen chúc với chuột, gián, rết, bọ.';
    final first = await engine.synthesize(text, engine.voices.first, seed: 999);
    final second = await engine.synthesize(text, engine.voices.first, seed: 999);

    // Bộ nhớ đệm của ứng dụng dựa vào điều này: cùng đoạn, cùng giọng, cùng hạt
    // giống thì phải ra đúng cùng một âm thanh.
    expect(second.length, first.length);
    for (var i = 0; i < first.length; i += 977) {
      expect(second[i], first[i], reason: 'lệch tại mẫu $i');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('mô hình chưa tải thì báo rõ chứ không sập', () async {
    final store = ModelStore(root: Directory.systemTemp.createTempSync('sachnoi_trong_'));
    addTearDown(() => store.root.deleteSync(recursive: true));

    final engine = OnDeviceVieNeuEngine(store);
    expect(await store.isInstalled(), isFalse);
    final status = await engine.status();
    expect(status.ready, isFalse);
    expect(status.message, contains('Chưa tải mô hình'));
  });

  _testModelStore();
  _testEnroll();
}

void _testModelStore() {
  group('Nhận biết mô hình đã tải', () {
    late Directory root;
    late ModelStore store;

    setUp(() {
      root = Directory.systemTemp.createTempSync('sachnoi_model_');
      store = ModelStore(root: root);
    });
    tearDown(() => root.deleteSync(recursive: true));

    /// Dựng đủ bộ file như sau một lần tải thành công.
    void writeAll({int smallBytes = 2000}) {
      store.modelDir.createSync(recursive: true);
      store.codecDir.createSync(recursive: true);
      for (final file in modelFiles) {
        // File nhỏ (config.json, tokenizer.json) viết đúng kích thước thật của
        // chúng, không theo con số ước lượng để vẽ thanh tiến trình.
        final size = file.megabytes >= 1.0 ? 4096 : smallBytes;
        store.fileFor(file).writeAsBytesSync(List.filled(size, 1));
      }
      store.dictFile.writeAsBytesSync(List.filled(64, 1));
      store.voicesFile.writeAsStringSync('{"presets":{}}');
    }

    test('file cấu hình nhỏ vài KB vẫn tính là đã tải', () async {
      writeAll();
      // Lỗi cũ: so kích thước thật với con số ước lượng làm tròn (0,01 MB), nên
      // config.json 2 KB luôn bị coi là tải dở và app đòi tải lại mỗi lần mở.
      expect(await store.isInstalled(), isTrue);
    });

    test('thiếu một file thì báo chưa tải', () async {
      writeAll();
      store.fileFor(modelFiles.first).deleteSync();
      expect(await store.isInstalled(), isFalse);
    });

    test('file rỗng thì báo chưa tải', () async {
      writeAll();
      store.fileFor(modelFiles.last).writeAsBytesSync(<int>[]);
      expect(await store.isInstalled(), isFalse);
    });

    test('thiếu từ điển âm vị thì báo chưa tải', () async {
      writeAll();
      store.dictFile.deleteSync();
      expect(await store.isInstalled(), isFalse);
    });
  });
}

void _testEnroll() {
  test('nhân bản giọng từ file wav rồi xoá đi', () async {
    final paths = _paths();
    final home = Platform.environment['USERPROFILE'];
    if (paths == null || home == null || (Platform.environment['ORT_DYLIB_PATH'] ?? '').isEmpty) {
      markTestSkipped('Chưa có mô hình — bỏ qua');
      return;
    }

    // Hai mô hình phụ nằm trong cache HuggingFace từ lần chạy trước.
    final hub = p.join(home, '.cache', 'huggingface', 'hub');
    final spk = Directory(p.join(hub, 'models--pnnbao-ump--VieNeu-TTS-v3-Turbo', 'snapshots'))
        .listSync()
        .whereType<Directory>()
        .map((d) => File(p.join(d.path, 'speaker_encoder.onnx')))
        .firstWhere((f) => f.existsSync(), orElse: () => File(''));
    final codec = Directory(
            p.join(hub, 'models--OpenMOSS-Team--MOSS-Audio-Tokenizer-Nano-ONNX', 'snapshots'))
        .listSync()
        .whereType<Directory>()
        .map((d) => File(p.join(d.path, 'moss_audio_tokenizer_encode.onnx')))
        .firstWhere((f) => f.existsSync(), orElse: () => File(''));
    final sample = File(r'C:\Software\Ebookreader\tts_service\voices\Latradio.wav');
    if (!spk.existsSync() || !codec.existsSync() || !sample.existsSync()) {
      markTestSkipped('Chưa có mô hình phụ để nhân bản giọng — bỏ qua');
      return;
    }

    // Làm việc trên bản sao hồ sơ để không đụng vào file thật.
    final temp = Directory.systemTemp.createTempSync('sachnoi_enroll_');
    addTearDown(() => temp.deleteSync(recursive: true));
    final voicesCopy = File(p.join(temp.path, 'giong.json'));
    voicesCopy.writeAsStringSync(File(paths.voicesPath).readAsStringSync());

    final engine = await VieNeuNative.start(VieNeuPaths(
      modelDir: paths.modelDir,
      codecDir: paths.codecDir,
      dictPath: paths.dictPath,
      voicesPath: voicesCopy.path,
      libraryPath: paths.libraryPath,
      threads: 4,
    ));
    addTearDown(engine.close);

    final before = engine.voices.length;
    expect(before, greaterThanOrEqualTo(16), reason: 'phải thấy đủ 14 giọng dựng sẵn + giọng thêm');

    await engine.addVoice(
      name: 'Giọng thử',
      wavPath: sample.path,
      speakerEncoder: spk.path,
      codecEncoder: codec.path,
      voicesPath: voicesCopy.path,
    );
    expect(engine.voices, contains('Giọng thử'));
    expect(engine.voices.length, before + 1);

    // Giọng vừa thêm phải đọc được ngay, không cần nạp lại mô hình.
    final samples = await engine.synthesize('Xin chào.', 'Giọng thử', seed: 7);
    expect(samples.length, greaterThan(engine.sampleRate ~/ 2));

    // Giọng dựng sẵn thì không cho xoá.
    await expectLater(
      engine.removeVoice('Thái Sơn', voicesCopy.path),
      throwsA(isA<VieNeuException>()),
    );

    await engine.removeVoice('Giọng thử', voicesCopy.path);
    expect(engine.voices, isNot(contains('Giọng thử')));
    expect(engine.voices.length, before);
  }, timeout: const Timeout(Duration(minutes: 6)));
}
