/// Chạy engine VieNeu trong ứng dụng, không qua Python.
///
/// Đây là đúng đường mà điện thoại sẽ đi: Dart -> isolate nền -> thư viện Rust
/// -> ONNX Runtime. Chạy được trên Windows nghĩa là logic đã đúng; phần còn lại
/// trên Android chỉ là khác kiến trúc máy.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/core/wav.dart';
import 'package:sach_noi/services/tts/vieneu_engine.dart';
import 'package:sach_noi/services/tts/model_store.dart';
import 'package:sach_noi/services/tts/vieneu_native.dart';

import 'duong_dan_repo.dart';

final _lib = vieneuLibPath;

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
  final dict = p.join(assetsDir, 'sea_g2p.bin');
  final voices = p.join(assetsDir, 'giong.json');

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
    final samples = (await engine.synthesize(
      'Xin chào, đây là bản đọc thử của ứng dụng sách nói.',
      engine.voices.first,
      seed: 12345,
    )).samples;
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
    final first = (await engine.synthesize(text, engine.voices.first, seed: 999)).samples;
    final second = (await engine.synthesize(text, engine.voices.first, seed: 999)).samples;

    // Bộ nhớ đệm của ứng dụng dựa vào điều này: cùng đoạn, cùng giọng, cùng hạt
    // giống thì phải ra đúng cùng một âm thanh.
    expect(second.length, first.length);
    for (var i = 0; i < first.length; i += 977) {
      expect(second[i], first[i], reason: 'lệch tại mẫu $i');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('đuôi đoạn trước đi tới được mô hình và đổi âm thanh đoạn sau', () async {
    final paths = _paths();
    if (paths == null || (Platform.environment['ORT_DYLIB_PATH'] ?? '').isEmpty) {
      markTestSkipped('Chưa có mô hình — bỏ qua');
      return;
    }
    final engine = await VieNeuNative.start(paths);
    addTearDown(engine.close);
    final giong = engine.voices.first;

    const truoc = 'Buổi sáng hôm ấy trời trong xanh và gió nhẹ thổi qua khu vườn.';
    const sau = 'Người thợ già dậy từ rất sớm, pha một ấm trà nóng rồi ngồi lặng lẽ.';

    final a = await engine.synthesize(truoc, giong, seed: 21);
    expect(a.duoi, isNotEmpty, reason: 'phải lấy được mã đuôi để nối ngữ cảnh');
    // 100 khung x 16 tầng lượng tử là trần; đoạn ngắn hơn thì ít khung hơn.
    expect(a.duoi.length % 16, 0);
    expect(a.duoi.length, lessThanOrEqualTo(100 * 16));

    final khong = await engine.synthesize(sau, giong, seed: 22);
    final co = await engine.synthesize(sau, giong, seed: 22, nguCanh: a.duoi);

    // Cùng chữ, cùng hạt giống — khác nhau thì chỉ có thể do ngữ cảnh đã tới
    // được mô hình. Không so "hay hơn" ở đây, việc đó đo bằng tai và bằng
    // script riêng; test này chỉ giữ cho đường truyền khỏi đứt.
    final n = khong.samples.length < co.samples.length ? khong.samples.length : co.samples.length;
    var lech = 0;
    for (var i = 0; i < n; i += 97) {
      if ((khong.samples[i] - co.samples[i]).abs() > 1e-4) lech++;
    }
    expect(lech, greaterThan(0), reason: 'có ngữ cảnh mà âm thanh y hệt — ngữ cảnh bị bỏ qua');
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

  test('nhiều bản mô hình chạy song song thì xong nhanh hơn hẳn', () async {
    final paths = _paths();
    if (paths == null || (Platform.environment['ORT_DYLIB_PATH'] ?? '').isEmpty) {
      markTestSkipped('Chưa có mô hình — bỏ qua');
      return;
    }
    // Máy ít nhân thì chạy song song không nhanh hơn được, đo cũng vô nghĩa.
    if (Platform.numberOfProcessors < 8) {
      markTestSkipped('Máy dưới 8 luồng — bỏ qua phép đo song song');
      return;
    }

    const doan = [
      'Buổi sáng hôm ấy trời trong xanh và gió nhẹ, người thợ già dậy từ rất sớm.',
      'Ông pha một ấm trà nóng rồi ngồi lặng lẽ bên hiên nhà, nhìn ra con đường đất.',
      'Ngày ấy cả xóm còn nghèo, nhưng ai cũng thương nhau như người một nhà.',
      'Mùa gặt đến thì sân nhà nào cũng vàng rực, tiếng máy tuốt lúa chạy suốt đêm.',
    ];

    // Một worker, làm lần lượt — đây là cách bản cũ xuất file.
    final mot = await VieNeuNative.start(paths);
    addTearDown(mot.close);
    final giong = mot.voices.first;
    await mot.synthesize(doan.first, giong, seed: 1); // làm nóng, không tính

    final t1 = Stopwatch()..start();
    var mauLanLuot = 0;
    for (final d in doan) {
      mauLanLuot += (await mot.synthesize(d, giong, seed: 1)).samples.length;
    }
    t1.stop();

    // Bốn worker, chạy cùng lúc — đây là cách bản mới xuất file.
    final nhieu = <VieNeuNative>[];
    for (var i = 0; i < doan.length; i++) {
      nhieu.add(await VieNeuNative.start(VieNeuPaths(
        modelDir: paths.modelDir,
        codecDir: paths.codecDir,
        dictPath: paths.dictPath,
        voicesPath: paths.voicesPath,
        libraryPath: paths.libraryPath,
        threads: 2,
      )));
    }
    addTearDown(() {
      for (final w in nhieu) {
        w.close();
      }
    });
    await Future.wait([for (var i = 0; i < doan.length; i++) nhieu[i].synthesize(doan[i], giong, seed: 1)]);

    final t2 = Stopwatch()..start();
    final ket = await Future.wait(
        [for (var i = 0; i < doan.length; i++) nhieu[i].synthesize(doan[i], giong, seed: 1)]);
    t2.stop();

    final mauSongSong = ket.fold<int>(0, (t, m) => t + m.samples.length);
    expect(mauSongSong, mauLanLuot, reason: 'phải ra cùng lượng âm thanh');

    final nhanhHon = t1.elapsedMicroseconds / t2.elapsedMicroseconds;
    // Đo được 3,1x trên máy 12 nhân. Đòi 1,5x thôi cho máy yếu và máy đang bận.
    expect(nhanhHon, greaterThan(1.5),
        reason: 'song song ${t2.elapsed.inMilliseconds}ms so với lần lượt '
            '${t1.elapsed.inMilliseconds}ms — chỉ nhanh hơn ${nhanhHon.toStringAsFixed(2)}x');
  }, timeout: const Timeout(Duration(minutes: 10)));

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
    File tepCua(String ten) => File(p.join(store.root.path, ten));

    void writeAll({int smallBytes = 2000}) {
      for (final ten in goiV3.canCo) {
        final f = tepCua(ten);
        f.parent.createSync(recursive: true);
        // File nhỏ (config.json, tokenizer.json) viết đúng kích thước thật của
        // chúng — phép kiểm chỉ được xét "có và khác rỗng", không so kích thước.
        f.writeAsBytesSync(List.filled(ten.endsWith('.json') ? smallBytes : 4096, 1));
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
      tepCua(goiV3.canCo.first).deleteSync();
      expect(await store.isInstalled(), isFalse);
    });

    test('file rỗng thì báo chưa tải', () async {
      writeAll();
      tepCua(goiV3.canCo.last).writeAsBytesSync(<int>[]);
      expect(await store.isInstalled(), isFalse);
    });

    test('giọng tự thêm thì xoá được, giọng dựng sẵn thì không', () async {
      // Lỗi cũ: giao diện chỉ coi là "tự thêm" khi source có đuôi .wav, mà thư
      // viện Rust lại ghi "nguoi-dung" khi thêm giọng trong ứng dụng — nên giọng
      // thêm từ điện thoại không bao giờ hiện nút xoá, dù bên dưới xoá được.
      // Hai chỗ này phải khớp nhau: model_store.dart và ffi.rs.
      root.createSync(recursive: true);
      // Có sẵn hai file đi kèm ứng dụng thì voiceMeta khỏi phải chép chúng ra
      // từ gói asset — việc đó cần binding của Flutter, không có trong test này.
      store.dictFile.writeAsBytesSync(List.filled(8, 1));
      store.voicesFile.writeAsStringSync('''
{"presets":{
  "Dựng sẵn":  {"source":"dựng sẵn trong mô hình","gender":"male","description":""},
  "Tự thêm":   {"source":"nguoi-dung","gender":"","description":"Giọng bạn tự thêm"},
  "Từ máy tính":{"source":"Latradio.wav","gender":"","description":""},
  "Chữ hoa":   {"source":"Ghi-Am.WAV","gender":"","description":""}
}}''');

      final meta = await store.voiceMeta();
      expect(meta['Dựng sẵn']!.builtIn, isTrue);
      expect(meta['Tự thêm']!.builtIn, isFalse, reason: 'thêm trong ứng dụng thì xoá được');
      // Giọng đi kèm bản cài cũng mang tên file mẫu, nhưng xoá không được: thư
      // viện Rust từ chối, mà lần mở sau phần hợp nhất cũng đưa chúng trở lại.
      expect(meta['Từ máy tính']!.builtIn, isTrue, reason: 'đi kèm bản cài');
      expect(meta['Chữ hoa']!.builtIn, isTrue, reason: 'đi kèm bản cài');
    });

    // testWidgets chứ không phải test: cần binding của Flutter mới đọc được asset
    // đi kèm. Và phải bọc trong runAsync vì thân bài chạy I/O thật, còn vùng thời
    // gian giả của testWidgets thì không bao giờ hoàn tất những Future ấy.
    testWidgets('cài đè bản mới: giọng mới hiện ra, giọng tự thêm còn nguyên',
        (tester) async => tester.runAsync(() async {
      // Lỗi cũ: giong.json chỉ được chép ra khi trên đĩa chưa có. Cài đè bản mới
      // thì file cũ vẫn nằm đó nên giọng mới thêm vào bản cài không bao giờ hiện,
      // phải xoá sạch dữ liệu mới thấy. Mà chép đè cũng không được vì giọng người
      // dùng tự nhân bản nằm chung file này.
      root.createSync(recursive: true);
      store.voicesFile.writeAsStringSync(jsonEncode({
        'presets': {
          'Giọng bản cũ': {'source': 'cu.wav', 'gender': '', 'description': ''},
          'Của tôi': {'source': nhanTuThem, 'gender': '', 'description': 'tự thêm'},
        }
      }));

      await store.paths();

      final sau = (jsonDecode(store.voicesFile.readAsStringSync())
          as Map<String, dynamic>)['presets'] as Map<String, dynamic>;
      final trongBanCai = (jsonDecode(await rootBundle.loadString('assets/giong.json'))
          as Map<String, dynamic>)['presets'] as Map<String, dynamic>;

      for (final ten in trongBanCai.keys) {
        expect(sau.containsKey(ten), isTrue, reason: 'giọng "$ten" của bản cài phải có');
      }
      expect(sau['Của tôi'], isNotNull, reason: 'giọng tự thêm không được mất');
      expect(sau.containsKey('Giọng bản cũ'), isFalse,
          reason: 'giọng đi kèm bản cũ thì theo bản cài mới');
        }));

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
    final sample = File(p.join(ttsServiceDir, 'voices', 'Latradio.wav'));
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
    final samples = (await engine.synthesize('Xin chào.', 'Giọng thử', seed: 7)).samples;
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
