/// Kiểm thử đường Dart -> thư viện Rust -> file nén.
///
/// Cần bản dựng release của thư viện native; không có thì tự bỏ qua để
/// `flutter test` vẫn xanh trên máy chưa dựng Rust.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/core/wav.dart';
import 'package:sach_noi/services/audio_encoder.dart';

const _lib = r'C:\Software\Ebookreader\native\vieneu\target\release\sachnoi_vieneu.dll';

/// Một giây sóng sin — đủ để bộ mã hoá có việc thật.
Uint8List _wavMotGiay() {
  final samples = Float32List(48000);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = 0.3 * math.sin(i / 48000 * 330 * 2 * math.pi);
  }
  return buildWav(samples, 48000);
}

/// Có thư viện native đã dựng để mà gọi không.
bool _coThuVien() => File(_lib).existsSync() && encoderAvailable;

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('sachnoi_nen_');
    encoderLibraryOverride = _lib;
  });

  tearDown(() {
    encoderLibraryOverride = null;
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('nén được sang Opus, MP3 và AAC, file nhỏ hơn WAV rất nhiều', () async {
    if (!_coThuVien()) {
      markTestSkipped('Chưa dựng thư viện native — bỏ qua');
      return;
    }
    final wav = File(p.join(dir.path, 'vao.wav'))..writeAsBytesSync(_wavMotGiay());
    final wavBytes = wav.lengthSync();

    for (final (format, bitrate, ten) in [
      (EncodeFormat.opus, 32000, 'ra32.opus'),
      (EncodeFormat.opus, 64000, 'ra64.opus'),
      (EncodeFormat.mp3, 128, 'ra.mp3'),
      (EncodeFormat.aac, 64000, 'ra.aac'),
    ]) {
      final ra = File(p.join(dir.path, ten));
      await encodeAudioFile(
          wavPath: wav.path, outBase: p.withoutExtension(ra.path), format: format, bitrate: bitrate);

      expect(ra.existsSync(), isTrue, reason: '$ten phải được tạo');
      final bytes = ra.readAsBytesSync();
      expect(bytes.length, lessThan(wavBytes ~/ 3), reason: '$ten phải nhỏ hơn WAV nhiều');
      if (format == EncodeFormat.opus) {
        expect(String.fromCharCodes(bytes.take(4)), 'OggS', reason: 'Opus nằm trong Ogg');
      } else {
        // Khung MP3 và khung ADTS (AAC) đều mở đầu bằng 0xFF.
        expect(bytes.first, 0xFF, reason: '$ten mở đầu bằng 0xFF');
      }
      // Không được để lại file tạm.
      expect(File('${ra.path}.tmp').existsSync(), isFalse);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('bitrate cao hơn thì file to hơn', () async {
    if (!_coThuVien()) {
      markTestSkipped('Chưa dựng thư viện native — bỏ qua');
      return;
    }
    final wav = File(p.join(dir.path, 'vao.wav'))..writeAsBytesSync(_wavMotGiay());
    final nho = File(p.join(dir.path, 'nho.opus'));
    final to = File(p.join(dir.path, 'to.opus'));
    await encodeAudioFile(
        wavPath: wav.path, outBase: p.withoutExtension(nho.path), format: EncodeFormat.opus, bitrate: 32000);
    await encodeAudioFile(
        wavPath: wav.path, outBase: p.withoutExtension(to.path), format: EncodeFormat.opus, bitrate: 64000);
    expect(to.lengthSync(), greaterThan(nho.lengthSync()));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('lỗi thì ném ra kèm lý do đọc được, không sập', () async {
    if (!_coThuVien()) {
      markTestSkipped('Chưa dựng thư viện native — bỏ qua');
      return;
    }
    // File nguồn không tồn tại.
    await expectLater(
      encodeAudioFile(
          wavPath: p.join(dir.path, 'khong-co.wav'),
          outBase: p.join(dir.path, 'ra'),
          format: EncodeFormat.opus,
          bitrate: 32000),
      throwsA(isA<EncodeException>()),
    );

    // File không phải WAV.
    final xau = File(p.join(dir.path, 'xau.wav'))..writeAsStringSync('không phải wav');
    await expectLater(
      encodeAudioFile(
          wavPath: xau.path,
          outBase: p.join(dir.path, 'ra2'),
          format: EncodeFormat.opus,
          bitrate: 32000),
      throwsA(isA<EncodeException>()),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('mã định dạng khớp với bên Rust', () {
    // Đổi mấy con số này là đổi luôn giao kèo với thư viện native.
    expect(EncodeFormat.opus.code, 0);
    expect(EncodeFormat.mp3.code, 1);
    expect(EncodeFormat.aac.code, 2);
    expect(EncodeFormat.opus.extension, 'opus');
    expect(EncodeFormat.mp3.extension, 'mp3');
    expect(EncodeFormat.aac.extension, 'aac');
  });
}
