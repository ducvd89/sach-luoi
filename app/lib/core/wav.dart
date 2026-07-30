/// Thao tác WAV thuần Dart: dựng file, đo thời lượng, tách phần dữ liệu.
///
/// Engine chạy thẳng trong ứng dụng trả về mẫu âm dạng số thực chứ không phải
/// MP3 — nhúng bộ mã hoá MP3 vào Flutter thì nặng hơn cả mô hình giọng nói. WAV
/// đổi lại nặng gấp năm lần khi xuất file, nhưng nối và cắt thì chỉ là ghép
/// byte, và mọi trình phát đều đọc được.
library;

import 'dart:typed_data';

const _headerSize = 44;

/// Thông tin cần biết để ghép nhiều đoạn WAV lại với nhau.
class WavInfo {
  const WavInfo({
    required this.sampleRate,
    required this.channels,
    required this.bitsPerSample,
    required this.dataOffset,
    required this.dataLength,
  });

  final int sampleRate;
  final int channels;
  final int bitsPerSample;
  final int dataOffset;
  final int dataLength;

  int get bytesPerSecond => sampleRate * channels * (bitsPerSample ~/ 8);
  double get seconds => bytesPerSecond == 0 ? 0 : dataLength / bytesPerSecond;
}

/// Đọc phần đầu file WAV. Trả về null nếu không phải WAV hợp lệ.
WavInfo? readWavInfo(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final view = ByteData.sublistView(bytes);
  // "RIFF" .... "WAVE"
  if (view.getUint32(0, Endian.big) != 0x52494646 || view.getUint32(8, Endian.big) != 0x57415645) {
    return null;
  }

  var offset = 12;
  var sampleRate = 0;
  var channels = 1;
  var bits = 16;

  while (offset + 8 <= bytes.length) {
    final id = view.getUint32(offset, Endian.big);
    final size = view.getUint32(offset + 4, Endian.little);
    final body = offset + 8;

    if (id == 0x666D7420) {
      // "fmt "
      if (body + 16 > bytes.length) return null;
      channels = view.getUint16(body + 2, Endian.little);
      sampleRate = view.getUint32(body + 4, Endian.little);
      bits = view.getUint16(body + 14, Endian.little);
    } else if (id == 0x64617461) {
      // "data" — kích thước ghi trong file có thể sai nếu lần ghi trước bị cắt
      // ngang, nên lấy theo phần còn lại thực tế.
      final available = bytes.length - body;
      return WavInfo(
        sampleRate: sampleRate,
        channels: channels == 0 ? 1 : channels,
        bitsPerSample: bits == 0 ? 16 : bits,
        dataOffset: body,
        dataLength: size == 0 || size > available ? available : size,
      );
    }

    offset = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

/// Lấy riêng phần dữ liệu âm thanh, bỏ mọi phần đầu — để nối các đoạn lại.
Uint8List wavPcm(Uint8List bytes) {
  final info = readWavInfo(bytes);
  if (info == null) return bytes;
  return Uint8List.sublistView(bytes, info.dataOffset, info.dataOffset + info.dataLength);
}

double wavDuration(Uint8List bytes) => readWavInfo(bytes)?.seconds ?? 0;

/// Dựng phần đầu WAV 16-bit cho [pcmLength] byte dữ liệu.
Uint8List wavHeader(int pcmLength, int sampleRate, {int channels = 1}) {
  final header = Uint8List(_headerSize);
  final view = ByteData.sublistView(header);
  const bits = 16;
  final blockAlign = channels * bits ~/ 8;

  view.setUint32(0, 0x52494646, Endian.big); // RIFF
  view.setUint32(4, 36 + pcmLength, Endian.little);
  view.setUint32(8, 0x57415645, Endian.big); // WAVE
  view.setUint32(12, 0x666D7420, Endian.big); // "fmt "
  view.setUint32(16, 16, Endian.little); // độ dài khối fmt
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * blockAlign, Endian.little);
  view.setUint16(32, blockAlign, Endian.little);
  view.setUint16(34, bits, Endian.little);
  view.setUint32(36, 0x64617461, Endian.big); // data
  view.setUint32(40, pcmLength, Endian.little);
  return header;
}

/// Đóng gói mẫu âm số thực [-1, 1] thành file WAV 16-bit hoàn chỉnh.
Uint8List buildWav(Float32List samples, int sampleRate) {
  final pcm = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(pcm);
  for (var i = 0; i < samples.length; i++) {
    var value = (samples[i] * 32767).round();
    if (value > 32767) value = 32767;
    if (value < -32768) value = -32768;
    view.setInt16(i * 2, value, Endian.little);
  }

  final out = Uint8List(_headerSize + pcm.length);
  out.setRange(0, _headerSize, wavHeader(pcm.length, sampleRate));
  out.setRange(_headerSize, out.length, pcm);
  return out;
}

/// Cân bằng âm lượng về một mức đỉnh cố định để các đoạn nghe đều tai nhau.
///
/// Dịch vụ Python làm việc này bằng numpy; engine trong ứng dụng phải tự làm.
Float32List normalizePeak(Float32List samples, {double targetPeak = 0.84}) {
  var peak = 0.0;
  for (final value in samples) {
    final magnitude = value.abs();
    if (magnitude > peak) peak = magnitude;
  }
  if (peak < 1e-6 || peak <= targetPeak) return samples;

  final gain = targetPeak / peak;
  final out = Float32List(samples.length);
  for (var i = 0; i < samples.length; i++) {
    out[i] = samples[i] * gain;
  }
  return out;
}
