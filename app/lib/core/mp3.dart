/// Thao tác MP3 thuần Dart: đo thời lượng, cắt bỏ thẻ ID3, ghép file.
///
/// Không cần ffmpeg vì âm thanh sinh ra luôn là MP3 CBR cùng một định dạng,
/// nên nối các khung dữ liệu lại là đủ để tạo file hoàn chỉnh mà mọi trình
/// phát đều đọc được.
library;

import 'dart:convert';
import 'dart:typed_data';

const _bitratesV1L3 = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0];
const _bitratesV2L3 = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0];
const _sampleRates = {
  3: [44100, 48000, 32000], // MPEG 1
  2: [22050, 24000, 16000], // MPEG 2
  0: [11025, 12000, 8000], // MPEG 2.5
};

/// Bỏ thẻ ID3v2 ở đầu và ID3v1 ở cuối, chỉ giữ lại luồng khung âm thanh.
Uint8List stripTags(Uint8List buf) {
  var start = 0;
  var end = buf.length;

  while (end - start > 10 && buf[start] == 0x49 && buf[start + 1] == 0x44 && buf[start + 2] == 0x33) {
    final size = ((buf[start + 6] & 0x7F) << 21) |
        ((buf[start + 7] & 0x7F) << 14) |
        ((buf[start + 8] & 0x7F) << 7) |
        (buf[start + 9] & 0x7F);
    final footer = (buf[start + 5] & 0x10) != 0 ? 10 : 0;
    start += 10 + size + footer;
  }

  if (end - start >= 128 &&
      buf[end - 128] == 0x54 && buf[end - 127] == 0x41 && buf[end - 126] == 0x47) {
    end -= 128;
  }
  if (start >= end) return Uint8List(0);
  return Uint8List.sublistView(buf, start, end);
}

class _Frame {
  const _Frame(this.length, this.samples, this.sampleRate);
  final int length;
  final int samples;
  final int sampleRate;
}

_Frame? _parseFrameHeader(Uint8List buf, int i) {
  final versionBits = (buf[i + 1] >> 3) & 0x03; // 3=MPEG1, 2=MPEG2, 0=MPEG2.5
  final layerBits = (buf[i + 1] >> 1) & 0x03; // 1 = Layer III
  if (versionBits == 1 || layerBits != 1) return null;

  final bitrateIndex = (buf[i + 2] >> 4) & 0x0F;
  final sampleRateIndex = (buf[i + 2] >> 2) & 0x03;
  if (bitrateIndex == 0 || bitrateIndex == 15 || sampleRateIndex == 3) return null;

  final bitrate = (versionBits == 3 ? _bitratesV1L3 : _bitratesV2L3)[bitrateIndex] * 1000;
  final sampleRate = _sampleRates[versionBits]![sampleRateIndex];
  final padding = (buf[i + 2] >> 1) & 0x01;
  final samples = versionBits == 3 ? 1152 : 576;
  final length = (samples ~/ 8) * bitrate ~/ sampleRate + padding;

  if (length < 8) return null;
  return _Frame(length, samples, sampleRate);
}

/// Đo thời lượng (giây) bằng cách duyệt từng khung MP3.
double mp3Duration(Uint8List input) {
  final buf = stripTags(input);
  var seconds = 0.0;
  var i = 0;

  while (i + 4 <= buf.length) {
    if (buf[i] != 0xFF || (buf[i + 1] & 0xE0) != 0xE0) {
      i++;
      continue;
    }
    final frame = _parseFrameHeader(buf, i);
    if (frame == null) {
      i++;
      continue;
    }
    seconds += frame.samples / frame.sampleRate;
    i += frame.length;
  }
  return seconds;
}

/// Dựng một chuỗi khung MP3 im lặng cùng định dạng với [reference].
///
/// Dùng để chèn khoảng nghỉ giữa các đoạn khi xuất file. Khung Layer III mà
/// phần thân toàn byte 0 sẽ giải mã ra im lặng: mọi trường trong side info đều
/// bằng 0, nghĩa là không có dữ liệu tần số nào để dựng lại. Header thì chép
/// nguyên từ luồng đang ghép nên tần số lấy mẫu, bitrate và số kênh khớp tuyệt
/// đối — nối vào không bị rè hay sai tốc độ.
Uint8List silentFramesLike(Uint8List reference, double seconds) {
  if (seconds <= 0) return Uint8List(0);

  for (var i = 0; i + 4 <= reference.length; i++) {
    if (reference[i] != 0xFF || (reference[i + 1] & 0xE0) != 0xE0) continue;
    final frame = _parseFrameHeader(reference, i);
    if (frame == null) continue;

    final count = (seconds * frame.sampleRate / frame.samples).round();
    if (count <= 0) return Uint8List(0);

    final out = Uint8List(count * frame.length);
    for (var f = 0; f < count; f++) {
      final at = f * frame.length;
      out[at] = reference[i];
      // Bật bit "không có CRC": khung của ta toàn số 0 nên không kèm được mã
      // kiểm tra, khai báo có CRC sẽ khiến máy phát khó tính báo hỏng.
      out[at + 1] = reference[i + 1] | 0x01;
      out[at + 2] = reference[i + 2];
      out[at + 3] = reference[i + 3];
      // Phần còn lại của khung đã là 0 sẵn — đó chính là chỗ tạo ra im lặng.
    }
    return out;
  }
  return Uint8List(0);
}

/// Tạo thẻ ID3v2.3 (UTF-16LE có BOM để giữ dấu tiếng Việt).
Uint8List buildId3({String? title, String? artist, String? album, String? track, String genre = 'Audiobook'}) {
  final frames = BytesBuilder();

  void textFrame(String id, String? value) {
    if (value == null || value.isEmpty) return;
    final content = BytesBuilder()
      ..addByte(0x01) // encoding: UTF-16 có BOM
      ..add([0xFF, 0xFE]);
    for (final unit in value.codeUnits) {
      content.addByte(unit & 0xFF);
      content.addByte((unit >> 8) & 0xFF);
    }
    content.add([0x00, 0x00]);
    final body = content.toBytes();

    final header = Uint8List(10);
    header.setRange(0, 4, ascii.encode(id));
    header[4] = (body.length >> 24) & 0xFF;
    header[5] = (body.length >> 16) & 0xFF;
    header[6] = (body.length >> 8) & 0xFF;
    header[7] = body.length & 0xFF;
    frames..add(header)..add(body);
  }

  textFrame('TIT2', title);
  textFrame('TPE1', artist);
  textFrame('TALB', album);
  textFrame('TRCK', track);
  textFrame('TCON', genre);

  final body = frames.toBytes();
  final header = Uint8List(10);
  header.setRange(0, 3, ascii.encode('ID3'));
  header[3] = 3; // phiên bản 2.3.0
  header[6] = (body.length >> 21) & 0x7F;
  header[7] = (body.length >> 14) & 0x7F;
  header[8] = (body.length >> 7) & 0x7F;
  header[9] = body.length & 0x7F;

  return (BytesBuilder()..add(header)..add(body)).toBytes();
}

/// Định dạng thời lượng thành chuỗi kiểu 1:23:45 hoặc 4:05.
String formatDuration(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final pad = (int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${pad(m)}:${pad(s)}' : '$m:${pad(s)}';
}
