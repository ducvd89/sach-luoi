/// Kiểm lại đoạn âm vừa tổng hợp: nghe ra bao nhiêu âm, có khớp với số từ không.
///
/// Vì sao đếm được: mỗi âm tiết phát ra thành một hạt âm có nhân là nguyên âm.
/// Đếm số nhân âm nghe thấy trong sóng rồi so với số âm tiết mà văn bản đáng lẽ
/// đọc ra là bắt được đúng những bệnh mà mô hình tự hồi quy hay mắc: lặp lại
/// vài từ cuối, nuốt mất nửa câu, hoặc lảm nhảm không dừng.
///
/// Phía văn bản nằm ở `am_tiet_chu.dart` — không phải cứ đếm từ là xong, vì một
/// từ tiếng Anh lẫn vào ("Windows", "Harry Potter") đọc ra nhiều âm tiết.
///
/// Cách đếm là đếm nhân âm theo đường cường độ (giống script "syllable nuclei"
/// quen dùng trong Praat): dựng đường năng lượng theo dB, tìm các đỉnh nổi hẳn
/// lên khỏi hõm hai bên, rồi bỏ những đỉnh không có thanh — tiếng xát như "s",
/// "x", "ph" cũng dội lên trong đường năng lượng nhưng không có nhân nguyên âm
/// nên không được tính là một âm.
///
/// Đây là phép đo gần đúng, sai số cỡ một âm cho mỗi câu, nên dải chấp nhận
/// phải rộng tay — xem [KetQuaKiemAm.dat].
library;

import 'dart:math';
import 'dart:typed_data';

import 'am_tiet_chu.dart';
import 'wav.dart';

/// Dải tỉ lệ chấp nhận được giữa số âm nghe thấy và số từ của đoạn.
const double tiLeAmToiThieu = 0.85;
const double tiLeAmToiDa = 1.15;

/// Từ ngần này từ trở lên mới so bằng tỉ lệ phần trăm.
///
/// Đoạn ngắn hơn thì phần trăm quá chặt — đoạn 3 từ chỉ được lệch 0,45 âm,
/// nghĩa là phải đếm trúng tuyệt đối, trong khi chính phép đếm đã sai số cỡ một
/// âm. Với chúng nó, sai số cho phép là ±1 âm.
const int soTuDungTiLe = 7;

/// Kết quả một lượt kiểm.
class KetQuaKiemAm {
  const KetQuaKiemAm({required this.soTu, required this.soAm});

  /// Số âm tiết mà văn bản của đoạn sẽ đọc ra — xem [demAmChu].
  ///
  /// Tên `soTu` là dấu vết của bản đầu (mỗi từ một âm) và được giữ nguyên vì nó
  /// đã nằm trong `job.json` của những lượt xuất còn dở.
  final int soTu;

  /// Số âm nghe thấy. null khi không đo được (âm thanh không phải WAV 16-bit).
  final int? soAm;

  /// Số âm trên số từ. 1.0 là khớp hoàn toàn.
  double get tiLe {
    final am = soAm;
    if (am == null || soTu == 0) return 1;
    return am / soTu;
  }

  /// Lệch bao xa khỏi mức khớp hoàn toàn — dùng để chọn bản đọc gần đúng nhất
  /// trong các lần đọc lại.
  double get lech => soAm == null ? double.infinity : (tiLe - 1).abs();

  /// Đoạn âm này dùng được không.
  ///
  /// Không đo được thì coi như đạt: thà lấy bản đọc còn hơn kẹt cả lượt xuất vì
  /// một phép kiểm không chạy nổi.
  bool get dat {
    final am = soAm;
    if (am == null || soTu == 0) return true;
    if (soTu < soTuDungTiLe) return (am - soTu).abs() <= 1;
    return am >= soTu * tiLeAmToiThieu && am <= soTu * tiLeAmToiDa;
  }

  @override
  String toString() => '$soAm/$soTu âm (${(tiLe * 100).round()}%)';
}

/// Đối chiếu âm thanh [wav] với văn bản [speech] của cùng một đoạn.
///
/// [nhip] là hệ số tốc độ đã áp vào âm thanh (1.0 là giọng gốc) — xem [demAmTiet].
KetQuaKiemAm kiemAm({required String speech, required Uint8List wav, double nhip = 1.0}) =>
    KetQuaKiemAm(soTu: demAmChu(speech), soAm: demAmTiet(wav, nhip: nhip));

// -- đếm âm trong sóng -------------------------------------------------------

/// Dải tần dựng bao hình — vùng của nguyên âm.
///
/// Cắt hai đầu giúp tách âm rõ hơn hẳn so với lấy toàn dải: dưới 200 Hz chủ yếu
/// là tiếng ù nền và bản thân tần số giọng, còn trên 1200 Hz là vùng của tiếng
/// xát ("s", "x", "ph") — chúng đủ mạnh để dựng thành đỉnh giả ngay giữa hai âm
/// thật. Bốn dải khác đã thử đều đếm tệ hơn.
const double _dayThapHz = 200;
const double _dayCaoHz = 1200;

/// Bước, cửa sổ và độ dài trung bình trượt của đường cường độ.
///
/// Bộ số dò ra từ 120 câu đọc thật bằng ba giọng: hẹp hơn thì rung giọng trong
/// cùng một nguyên âm tách thành hai đỉnh, rộng hơn thì hai âm liền nhau dính
/// làm một. Cửa sổ 60 ms cộng trung bình trượt 7 điểm nghe thì rất mượt, nhưng
/// đúng là mức để ranh giới âm nổi lên rõ nhất.
const double _buocGiay = 0.010;
const double _cuaSoGiay = 0.060;
const int _soDiemLamMuot = 7;

/// Đỉnh thấp hơn đỉnh cao nhất của đoạn ngần này dB thì coi là im lặng.
const double _nguongImDb = 25;

/// Hai đỉnh chỉ tính là hai âm khi giữa chúng có hõm sâu ít nhất ngần này dB.
///
/// Nghe thì tưởng phải sâu, nhưng trên đường đã làm mượt thì ranh giới giữa hai
/// âm đọc liền mạch chỉ hõm xuống nửa dB — đòi sâu hơn là nuốt mất một phần tư
/// số âm. Cái giữ cho nhiễu không thành âm là khoảng cách tối thiểu và phép xét
/// thanh bên dưới, không phải con số này.
const double _homToiThieuDb = 0.5;

/// Hai nhân âm gần nhau hơn ngần này giây thì là một — người đọc nhanh nhất
/// cũng chỉ tới khoảng 12 âm mỗi giây.
const double _cachNhauToiThieuGiay = 0.08;

/// Tần số dùng cho phép xét thanh. Đủ cho dải giọng người, mà rẻ hơn hẳn so với
/// tự tương quan trên sóng 48 kHz.
const int _tanSoXetThanh = 8000;
const double _f0Thap = 60;
const double _f0Cao = 400;

/// Tự tương quan chuẩn hoá từ mức này trở lên thì coi là có thanh.
///
/// Để rộng tay: việc của phép xét này chỉ là gạt những đỉnh hoàn toàn không có
/// chu kỳ (tiếng gió, tiếng lách cách, nhiễu), chứ không phải chấm điểm giọng.
const double _nguongCoThanh = 0.2;

/// Số âm nghe thấy trong một file WAV 16-bit. null nếu không đọc nổi file.
///
/// [nhip] là hệ số tốc độ đã áp vào âm thanh. Lúc xuất file, tốc độ được làm
/// bằng cách lấy mẫu lại (xem `vieneu_engine.dart`) nên đọc nhanh 1,5× thì vừa
/// có 1,5 lần số âm trong mỗi giây, vừa đẩy cả giọng lên cao 1,5 lần — cửa sổ
/// và dải tần phải co theo đúng chừng ấy, không thì đếm sót hàng loạt. Coi như
/// đang nghe cùng một sóng ấy ở tần số lấy mẫu chậm hơn là ra đủ cả hai.
int? demAmTiet(Uint8List wav, {double nhip = 1.0}) {
  final info = readWavInfo(wav);
  if (info == null || info.bitsPerSample != 16 || info.sampleRate < 4000) return null;

  final mau = _mono(wav, info);
  // Dưới 50 ms thì không đủ cho một âm nào.
  if (mau.length < info.sampleRate ~/ 20) return 0;
  final rate = nhip > 0.01 ? (info.sampleRate / nhip).round() : info.sampleRate;
  return demAmTietTuMau(mau, rate);
}

/// Như [demAmTiet] nhưng nhận thẳng mẫu âm [-1, 1] — dùng cho kiểm thử và cho
/// nơi đã có sẵn mẫu, khỏi đóng gói WAV rồi mở lại.
int demAmTietTuMau(Float32List mau, int rate) {
  final buoc = max(1, (rate * _buocGiay).round());
  final cua = max(buoc, (rate * _cuaSoGiay).round());
  final db = _duongCuongDo(_locDai(mau, rate), buoc, cua);
  if (db.length < 3) return 0;

  final dinhCao = db.reduce(max);
  final nguong = dinhCao - _nguongImDb;
  final cachToiThieu = max(1, (_cachNhauToiThieuGiay * rate / buoc).round());

  // Đỉnh cục bộ nổi hẳn khỏi hõm hai bên. Đi từ trái sang phải, mỗi đỉnh mới
  // phải chứng minh nó tách khỏi đỉnh đang giữ; không tách nổi thì hai đỉnh là
  // một âm, giữ lại cái to hơn.
  final nhan = <int>[];
  for (var i = 1; i < db.length - 1; i++) {
    if (db[i] < nguong) continue;
    if (db[i] < db[i - 1] || db[i] <= db[i + 1]) continue;

    if (nhan.isEmpty) {
      nhan.add(i);
      continue;
    }
    final truoc = nhan.last;
    var hom = double.infinity;
    for (var k = truoc + 1; k < i; k++) {
      if (db[k] < hom) hom = db[k];
    }
    final tach = hom <= min(db[truoc], db[i]) - _homToiThieuDb && i - truoc >= cachToiThieu;
    if (tach) {
      nhan.add(i);
    } else if (db[i] > db[truoc]) {
      nhan[nhan.length - 1] = i;
    }
  }
  if (nhan.isEmpty) return 0;

  // Bỏ những đỉnh không có thanh: tiếng xát, tiếng gió, tiếng lách cách.
  final (mauXet, rateXet) = _haTanSo(mau, rate);
  var so = 0;
  for (final i in nhan) {
    final giua = ((i * buoc + cua / 2) / rate * rateXet).round();
    if (_coThanh(mauXet, rateXet, giua)) so++;
  }
  return so;
}

/// Mẫu âm một kênh, [-1, 1].
Float32List _mono(Uint8List wav, WavInfo info) {
  final view = ByteData.sublistView(wav);
  final khung = info.channels * (info.bitsPerSample ~/ 8);
  final so = info.dataLength ~/ khung;
  final out = Float32List(so);
  for (var i = 0; i < so; i++) {
    var tong = 0.0;
    for (var c = 0; c < info.channels; c++) {
      tong += view.getInt16(info.dataOffset + i * khung + c * 2, Endian.little) / 32768;
    }
    out[i] = tong / info.channels;
  }
  return out;
}

/// Giữ lại dải [_dayThapHz]–[_dayCaoHz] bằng hiệu của hai bộ lọc thông thấp một
/// cực. Sườn thoải, nhưng dựng bao hình thì chỉ cần chừng ấy.
Float32List _locDai(Float32List x, int rate) {
  final aCao = exp(-2 * pi * _dayCaoHz / rate);
  final aThap = exp(-2 * pi * _dayThapHz / rate);
  final out = Float32List(x.length);
  var lpCao = 0.0;
  var lpThap = 0.0;
  for (var i = 0; i < x.length; i++) {
    lpCao = aCao * lpCao + (1 - aCao) * x[i];
    lpThap = aThap * lpThap + (1 - aThap) * x[i];
    out[i] = lpCao - lpThap;
  }
  return out;
}

/// Đường cường độ theo dB, mỗi [buoc] mẫu một điểm, làm mượt để bớt răng cưa.
List<double> _duongCuongDo(Float32List x, int buoc, int cua) {
  if (x.length < cua) return const [];
  final n = ((x.length - cua) ~/ buoc) + 1;
  final db = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final dau = i * buoc;
    var tong = 0.0;
    for (var k = dau; k < dau + cua; k++) {
      tong += x[k] * x[k];
    }
    db[i] = 10 * (log(tong / cua + 1e-12) / ln10);
  }

  // Trung bình trượt: đủ để rung giọng trong cùng một nguyên âm không tách
  // thành hai đỉnh, mà chưa xoá mất ranh giới giữa hai âm.
  final ban = _soDiemLamMuot ~/ 2;
  final muot = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final tu = max(0, i - ban);
    final den = min(n - 1, i + ban);
    var tong = 0.0;
    for (var k = tu; k <= den; k++) {
      tong += db[k];
    }
    muot[i] = tong / (den - tu + 1);
  }
  return muot;
}

/// Hạ tần số lấy mẫu xuống [_tanSoXetThanh] bằng cách lấy trung bình từng cụm.
(Float32List, int) _haTanSo(Float32List x, int rate) {
  if (rate <= _tanSoXetThanh * 1.5) return (x, rate);
  final ti = rate / _tanSoXetThanh;
  final n = (x.length / ti).floor();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final tu = (i * ti).floor();
    final den = min(x.length, ((i + 1) * ti).floor());
    if (den <= tu) continue;
    var tong = 0.0;
    for (var k = tu; k < den; k++) {
      tong += x[k];
    }
    out[i] = tong / (den - tu);
  }
  return (out, _tanSoXetThanh);
}

/// Quanh mẫu [giua] có thanh (dây thanh rung) hay không.
bool _coThanh(Float32List x, int rate, int giua) {
  final n = (rate * 0.04).round(); // cửa sổ 40 ms, đủ chứa hai chu kỳ giọng trầm
  if (x.length < n + 2) return true; // quá ngắn để xét — đừng loại oan

  var dau = giua - n ~/ 2;
  if (dau < 0) dau = 0;
  if (dau + n > x.length) dau = x.length - n;

  var tb = 0.0;
  for (var i = 0; i < n; i++) {
    tb += x[dau + i];
  }
  tb /= n;

  final lagMin = (rate / _f0Cao).floor();
  final lagMax = min(n - 16, (rate / _f0Thap).ceil());
  for (var lag = lagMin; lag <= lagMax; lag++) {
    var r = 0.0;
    var e1 = 0.0;
    var e2 = 0.0;
    for (var i = 0; i + lag < n; i++) {
      final a = x[dau + i] - tb;
      final b = x[dau + i + lag] - tb;
      r += a * b;
      e1 += a * a;
      e2 += b * b;
    }
    if (e1 <= 0 || e2 <= 0) continue;
    if (r / sqrt(e1 * e2) >= _nguongCoThanh) return true;
  }
  return false;
}
