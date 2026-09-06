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

import 'duong_dan_repo.dart';

final _lib = vieneuLibPath;

/// Một giây sóng sin — đủ để bộ mã hoá có việc thật.
Uint8List _wavMotGiay([int rate = 48000]) {
  final samples = Float32List(rate);
  for (var i = 0; i < samples.length; i++) {
    samples[i] = 0.3 * math.sin(i / rate * 330 * 2 * math.pi);
  }
  return buildWav(samples, rate);
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

  test('nén được WAV 24 kHz của engine VieNeu v2', () async {
    if (!_coThuVien()) {
      markTestSkipped('Chưa dựng thư viện native — bỏ qua');
      return;
    }
    // NeuCodec của v2 dựng ra 24 kHz chứ không phải 48 kHz như v3. Bộ nén từng
    // đòi đúng 48 kHz nên mọi file cuối của v2 đều rơi về WAV kèm dòng "Opus
    // cần 48 kHz, nhận 24000 Hz" — libopus vốn nhận thẳng 24 kHz.
    final wav = File(p.join(dir.path, 'v2.wav'))..writeAsBytesSync(_wavMotGiay(24000));

    for (final (format, bitrate, ten) in [
      (EncodeFormat.opus, 32000, 'v2.opus'),
      (EncodeFormat.mp3, 128, 'v2.mp3'),
      (EncodeFormat.aac, 64000, 'v2.aac'),
    ]) {
      final ra = File(p.join(dir.path, ten));
      await encodeAudioFile(
          wavPath: wav.path, outBase: p.withoutExtension(ra.path), format: format, bitrate: bitrate);
      expect(ra.existsSync(), isTrue, reason: '$ten phải được tạo');
      expect(ra.lengthSync(), greaterThan(1000), reason: '$ten quá ngắn');
      if (format == EncodeFormat.opus) {
        expect(String.fromCharCodes(ra.readAsBytesSync().take(4)), 'OggS');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('nén được WAV 22,05 kHz của Matcha và Giọng nhẹ', () async {
    if (!_coThuVien()) {
      markTestSkipped('Chưa dựng thư viện native — bỏ qua');
      return;
    }
    // 22 050 Hz không nằm trong năm mức libopus nhận, nên bộ nén phải tự nâng
    // lên 48 kHz. Trước đây nó trả lỗi, mà Opus 32 kbps là định dạng xuất mặc
    // định — nên ai chọn Matcha hoặc Giọng nhẹ rồi xuất file đều nhận lại WAV
    // kèm dòng "giữ nguyên WAV", nặng gấp khoảng 30 lần.
    final wav = File(p.join(dir.path, '22k.wav'))..writeAsBytesSync(_wavMotGiay(22050));
    final wavBytes = wav.lengthSync();

    for (final (format, bitrate, ten) in [
      (EncodeFormat.opus, 32000, '22k.opus'),
      (EncodeFormat.mp3, 128, '22k.mp3'),
      (EncodeFormat.aac, 64000, '22k.aac'),
    ]) {
      final ra = File(p.join(dir.path, ten));
      await encodeAudioFile(
          wavPath: wav.path, outBase: p.withoutExtension(ra.path), format: format, bitrate: bitrate);
      expect(ra.existsSync(), isTrue, reason: '$ten phải được tạo');

      // Điều thật sự cần canh: đây là file NÉN chứ không phải WAV giữ nguyên —
      // đúng cái mà `export_service` trả về khi bộ nén báo lỗi. Nhìn vào đầu
      // file là biết chắc, không cần đoán qua kích thước.
      expect(String.fromCharCodes(ra.readAsBytesSync().take(4)), isNot('RIFF'),
          reason: '$ten vẫn là WAV — bộ nén đã bỏ cuộc');

      // Trần suy từ chính bitrate, KHÔNG suy từ kích thước WAV. Một giây ở
      // bitrate B tốn khoảng B/8 byte dù tần số vào là bao nhiêu, trong khi WAV
      // 22,05 kHz chỉ nặng 44.144 byte — nên mốc "nhỏ hơn một phần ba WAV" mà
      // bản trước dùng đòi MP3 128 kbps xuống dưới 14.714 byte, chuyện không
      // thể xảy ra (nó luôn tốn 16.000). Mốc ấy chỉ đúng với WAV 48 kHz.
      final bitPerGiay = format == EncodeFormat.mp3 ? bitrate * 1000 : bitrate;
      final tran = (bitPerGiay / 8 * 1.6).round() + 2048; // chừa chỗ cho phần đầu file
      expect(ra.lengthSync(), lessThan(tran), reason: '$ten to hơn mức bitrate cho phép');
      expect(ra.lengthSync(), lessThan(wavBytes), reason: '$ten phải nhỏ hơn WAV');
      if (format == EncodeFormat.opus) {
        expect(String.fromCharCodes(ra.readAsBytesSync().take(4)), 'OggS');
      }
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
