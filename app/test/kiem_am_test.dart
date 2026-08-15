/// Kiểm thử phép đếm âm dùng để soi lại đoạn vừa tổng hợp lúc xuất file.
///
/// Hai tầng: tầng đầu chạy trên sóng dựng sẵn nên máy nào cũng chạy được; tầng
/// sau đọc thật bằng mô hình VieNeu để biết sai số trên giọng thật là bao
/// nhiêu, và tự bỏ qua khi máy chưa có mô hình.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sach_noi/core/kiem_am.dart';
import 'package:sach_noi/core/wav.dart';
import 'package:sach_noi/services/tts/vieneu_native.dart';

import 'duong_dan_repo.dart';

final _lib = vieneuLibPath;

/// Dựng một chuỗi "âm" giả: mỗi âm là một đoạn sóng có thanh (hài của f0) dài
/// [amMs] mili giây, cách nhau bằng một khoảng lặng ngắn.
Float32List _chuoiAm(int soAm, {int amMs = 180, int nghiMs = 70, double f0 = 130}) {
  const rate = 16000;
  final mauAm = rate * amMs ~/ 1000;
  final mauNghi = rate * nghiMs ~/ 1000;
  final out = Float32List(soAm * (mauAm + mauNghi));
  var at = 0;
  for (var n = 0; n < soAm; n++) {
    for (var i = 0; i < mauAm; i++) {
      final t = i / rate;
      // Nhiều hài để giống nguyên âm thật, kèm bao hình lên xuống.
      final bao = math.sin(math.pi * i / mauAm);
      out[at + i] = 0.5 *
          bao *
          (math.sin(2 * math.pi * f0 * t) +
              0.5 * math.sin(4 * math.pi * f0 * t) +
              0.25 * math.sin(6 * math.pi * f0 * t));
    }
    at += mauAm + mauNghi;
  }
  return out;
}

/// Lấy mẫu lại để đổi tốc độ — đúng cách engine làm khi xuất file nhanh hơn
/// bình thường (xem `vieneu_engine.dart`).
Float32List _doiToc(Float32List input, double speed) {
  final target = (input.length / speed).round();
  final out = Float32List(target);
  final scale = (input.length - 1) / (target - 1);
  for (var i = 0; i < target; i++) {
    final at = i * scale;
    final low = at.floor();
    final high = math.min(low + 1, input.length - 1);
    final frac = at - low;
    out[i] = input[low] * (1 - frac) + input[high] * frac;
  }
  return out;
}

void main() {
  // Phần đếm âm từ VĂN BẢN đã dọn sang `am_tiet_chu_test.dart` — nó không chỉ
  // đếm từ nữa mà phải đoán được cả từ tiếng Anh lẫn vào.

  group('Ngưỡng đạt', () {
    test('đoạn dưới 7 từ dùng sai số ±1 âm', () {
      expect(const KetQuaKiemAm(soTu: 3, soAm: 4).dat, isTrue);
      expect(const KetQuaKiemAm(soTu: 3, soAm: 2).dat, isTrue);
      expect(const KetQuaKiemAm(soTu: 3, soAm: 5).dat, isFalse);
      expect(const KetQuaKiemAm(soTu: 6, soAm: 7).dat, isTrue);
      expect(const KetQuaKiemAm(soTu: 6, soAm: 8).dat, isFalse);
    });

    test('từ 7 từ trở lên dùng dải 85-115%', () {
      expect(const KetQuaKiemAm(soTu: 20, soAm: 17).dat, isTrue); // 85%
      expect(const KetQuaKiemAm(soTu: 20, soAm: 16).dat, isFalse);
      expect(const KetQuaKiemAm(soTu: 20, soAm: 23).dat, isTrue); // 115%
      expect(const KetQuaKiemAm(soTu: 20, soAm: 24).dat, isFalse);
      expect(const KetQuaKiemAm(soTu: 40, soAm: 20).dat, isFalse, reason: 'nuốt mất nửa đoạn');
      expect(const KetQuaKiemAm(soTu: 40, soAm: 60).dat, isFalse, reason: 'lặp lại không dừng');
    });

    test('không đo được thì không kết tội', () {
      expect(const KetQuaKiemAm(soTu: 20, soAm: null).dat, isTrue);
      expect(const KetQuaKiemAm(soTu: 20, soAm: null).lech, double.infinity,
          reason: 'nhưng cũng không được chọn làm bản tốt nhất');
    });

    test('chọn bản gần 100% nhất', () {
      const a = KetQuaKiemAm(soTu: 20, soAm: 14);
      const b = KetQuaKiemAm(soTu: 20, soAm: 18);
      const c = KetQuaKiemAm(soTu: 20, soAm: 25);
      expect(b.lech, lessThan(a.lech));
      expect(b.lech, lessThan(c.lech));
    });
  });

  group('Đếm âm trong sóng', () {
    test('đếm đúng chuỗi âm dựng sẵn', () {
      for (final so in [1, 3, 8, 17]) {
        expect(demAmTietTuMau(_chuoiAm(so), 16000), so, reason: 'chuỗi $so âm');
      }
    });

    test('im lặng thì không có âm nào', () {
      expect(demAmTietTuMau(Float32List(16000), 16000), 0);
    });

    test('tiếng xát không có thanh thì không tính là âm', () {
      // Nhiễu trắng: có năng lượng, có đỉnh, nhưng không có nhân nguyên âm.
      final rnd = math.Random(7);
      final nhieu = Float32List(16000 * 2);
      for (var i = 0; i < nhieu.length; i++) {
        nhieu[i] = (rnd.nextDouble() - 0.5) * 0.6;
      }
      expect(demAmTietTuMau(nhieu, 16000), 0);
    });

    test('đọc được qua đường WAV', () {
      final wav = buildWav(_chuoiAm(6), 16000);
      expect(demAmTiet(wav), 6);
      expect(kiemAm(speech: 'Một hai ba bốn năm sáu.', wav: wav).dat, isTrue);
      expect(kiemAm(speech: 'Một hai ba bốn năm sáu bảy tám chín mười.', wav: wav).dat, isFalse);
    });

    test('đọc nhanh thì báo nhịp vào là vẫn đếm đúng', () {
      // Xuất file ở tốc độ 1,5× hay 2× thì âm thanh bị lấy mẫu lại: âm dồn lại
      // và giọng cao lên. Không bù theo nhịp thì cửa sổ phân tích quá rộng và
      // dải tần lệch hẳn, đếm sót hàng loạt rồi đọc lại vô ích.
      final goc = _chuoiAm(12);
      for (final nhip in [1.5, 2.0]) {
        final nhanh = _doiToc(goc, nhip);
        expect(demAmTiet(buildWav(nhanh, 16000), nhip: nhip), 12, reason: 'tốc độ $nhip');
      }
    });

    test('file không phải WAV thì trả về null chứ không sập', () {
      expect(demAmTiet(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });
  });

  _voiGiongThat();
}

/// Mô hình đã tải sẵn trong cache HuggingFace — giống vieneu_ondevice_test.dart.
VieNeuPaths? _paths() {
  final home = Platform.environment['USERPROFILE'];
  if (home == null || !File(_lib).existsSync()) return null;
  if ((Platform.environment['ORT_DYLIB_PATH'] ?? '').isEmpty) return null;

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

/// Các câu để đo sai số — dài ngắn khác nhau, có cả câu thoại và câu kể.
const _cau = [
  'Xin chào, đây là bản đọc thử của ứng dụng sách nói.',
  'Họ sống chen chúc với chuột, gián, rết, bọ.',
  'Buổi sáng hôm ấy trời trong xanh và gió nhẹ thổi qua khu vườn nhỏ sau nhà.',
  'Người thợ già dậy từ rất sớm, pha một ấm trà nóng rồi ngồi lặng lẽ bên hiên.',
  'Ngày ấy cả xóm còn nghèo, nhưng ai cũng thương nhau như người một nhà.',
  'Mùa gặt đến thì sân nhà nào cũng vàng rực, tiếng máy tuốt lúa chạy suốt đêm.',
  'Không được!',
  'Anh đi đâu đấy?',
  'Hàn Lập nhíu mày, trong lòng thầm nghĩ chuyện này e rằng không đơn giản như vẻ ngoài.',
  'Chương một.',
];

void _voiGiongThat() {
  test('đếm sát số từ trên giọng đọc thật', () async {
    final paths = _paths();
    if (paths == null) {
      markTestSkipped('Chưa có mô hình hoặc chưa đặt ORT_DYLIB_PATH — bỏ qua');
      return;
    }

    final engine = await VieNeuNative.start(paths);
    addTearDown(engine.close);
    // Ba giọng: hằng số không được bám riêng vào một chất giọng.
    final giong = engine.voices.take(3).toList();

    var lechTong = 0.0;
    var soDat = 0;
    var soLuot = 0;
    for (final g in giong) {
      for (var i = 0; i < _cau.length; i++) {
        final ra = await engine.synthesize(_cau[i], g, seed: 100 + i);
        final ket = kiemAm(speech: _cau[i], wav: buildWav(ra.samples, engine.sampleRate));
        lechTong += ket.lech;
        soLuot++;
        if (ket.dat) soDat++;
        // ignore: avoid_print
        print('${ket.dat ? 'ĐẠT   ' : 'LỆCH  '} $ket  $g — ${_cau[i]}');
      }
    }

    // ignore: avoid_print
    print('Đạt $soDat/$soLuot, lệch trung bình '
        '${(lechTong / soLuot * 100).toStringAsFixed(1)}%');

    // Ngưỡng chống hồi quy, không phải mục tiêu. Đo được 28/30 khi dò hằng số
    // (hai câu trượt đều là câu bốn năm chữ, chỗ phép đếm khó nhất). Tụt hẳn
    // xuống nghĩa là lượt xuất nào cũng phải đọc lại rất nhiều đoạn vô ích.
    expect(soDat, greaterThanOrEqualTo((soLuot * 0.85).round()),
        reason: 'đếm sai quá nhiều câu — xem lại hằng số trong kiem_am.dart');
    expect(lechTong / soLuot, lessThan(0.2), reason: 'lệch trung bình quá lớn');
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('bắt được đoạn bị cụt và đoạn bị lặp', () async {
    final paths = _paths();
    if (paths == null) {
      markTestSkipped('Chưa có mô hình — bỏ qua');
      return;
    }

    final engine = await VieNeuNative.start(paths);
    addTearDown(engine.close);

    const cau = 'Buổi sáng hôm ấy trời trong xanh và gió nhẹ thổi qua khu vườn nhỏ sau nhà.';
    final ra = await engine.synthesize(cau, engine.voices.first, seed: 4242);

    // Cụt nửa chừng — đúng cảnh mô hình dừng sớm.
    final nua = Float32List.sublistView(ra.samples, 0, ra.samples.length ~/ 2);
    expect(kiemAm(speech: cau, wav: buildWav(nua, engine.sampleRate)).dat, isFalse,
        reason: 'đoạn cụt một nửa phải bị loại');

    // Lặp lại toàn bộ — đúng cảnh mô hình không dừng được.
    final gap = Float32List(ra.samples.length * 2);
    gap.setRange(0, ra.samples.length, ra.samples);
    gap.setRange(ra.samples.length, gap.length, ra.samples);
    expect(kiemAm(speech: cau, wav: buildWav(gap, engine.sampleRate)).dat, isFalse,
        reason: 'đoạn đọc lặp hai lần phải bị loại');

    // Còn đọc nhanh thì vẫn phải đạt — người dùng xuất file ở 1,5× rất nhiều.
    for (final nhip in [1.25, 1.5, 2.0]) {
      final nhanh = _doiToc(ra.samples, nhip);
      final ket = kiemAm(speech: cau, wav: buildWav(nhanh, engine.sampleRate), nhip: nhip);
      // ignore: avoid_print
      print('tốc độ $nhip: $ket');
      expect(ket.dat, isTrue, reason: 'đọc nhanh $nhip lần mà bị coi là hỏng');
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
