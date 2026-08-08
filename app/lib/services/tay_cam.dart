/// Điều khiển ứng dụng bằng tay cầm chơi game.
///
/// Hai hệ máy, hai đường vào khác hẳn nhau:
///
/// - **Windows** dùng XInput (`xinput1_4.dll`), hỏi trạng thái tay cầm 60 lần
///   mỗi giây. Đây là đường duy nhất trên Windows vì tay cầm không gửi phím.
/// - **Android** KHÔNG có XInput — đó là API riêng của Windows. Cùng cái tay
///   cầm Xbox ấy nhưng hệ điều hành đưa vào bằng `KeyEvent` (nút và phím mũi
///   tên) và `MotionEvent` (cần gạt), bắt ở `MainActivity.kt` rồi đẩy sang Dart.
///
/// Phần trên — chỗ đổi trạng thái thô thành lệnh, chống rung, giữ để lặp — dùng
/// chung cho cả hai. Xem [BoDichTayCam].
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'tay_cam_windows.dart';

/// Lệnh mà giao diện hiểu được. Ánh xạ nút nằm ở từng nguồn.
enum LenhTayCam {
  len,
  xuong,
  trai,
  phai,

  /// Nút A — chọn thứ đang trỏ tới.
  chon,

  /// Nút B — quay lại.
  quayLai,

  /// Nút Y — phát/tạm dừng.
  phatDung,

  /// L1 hoặc L2 — sang tab bên trái.
  tabTruoc,

  /// R1 hoặc R2 — sang tab bên phải.
  tabSau,

  /// Cần phải đẩy lên — cuộn phần chữ đang đọc.
  cuonLen,

  /// Cần phải đẩy xuống.
  cuonXuong,
}

/// Ảnh chụp trạng thái tay cầm tại một thời điểm.
class TrangThaiTayCam {
  const TrangThaiTayCam({
    this.x = 0,
    this.y = 0,
    this.xPhai = 0,
    this.yPhai = 0,
    this.chon = false,
    this.quayLai = false,
    this.phatDung = false,
    this.vaiTrai = false,
    this.vaiPhai = false,
  });

  /// -1 đến 1, dương là sang phải. Cần trái và phím mũi tên dùng chung cặp này.
  final double x;

  /// -1 đến 1, **dương là lên**.
  ///
  /// XInput để dương là lên, Android để dương là xuống (theo trục màn hình) —
  /// mỗi nguồn tự lật cho đúng quy ước này trước khi đưa vào đây.
  final double y;

  /// Cần phải, cùng quy ước dấu với cần trái.
  final double xPhai;
  final double yPhai;

  final bool chon;
  final bool quayLai;
  final bool phatDung;

  /// L1 hoặc L2 đang bấm. Hai cái gộp làm một: cả hai đều nghĩa là "sang trái".
  final bool vaiTrai;

  /// R1 hoặc R2 đang bấm.
  final bool vaiPhai;

  static const khong = TrangThaiTayCam();

  TrangThaiTayCam copyWith({
    double? x,
    double? y,
    double? xPhai,
    double? yPhai,
    bool? chon,
    bool? quayLai,
    bool? phatDung,
    bool? vaiTrai,
    bool? vaiPhai,
  }) =>
      TrangThaiTayCam(
        x: x ?? this.x,
        y: y ?? this.y,
        xPhai: xPhai ?? this.xPhai,
        yPhai: yPhai ?? this.yPhai,
        chon: chon ?? this.chon,
        quayLai: quayLai ?? this.quayLai,
        phatDung: phatDung ?? this.phatDung,
        vaiTrai: vaiTrai ?? this.vaiTrai,
        vaiPhai: vaiPhai ?? this.vaiPhai,
      );
}

/// Đổi trạng thái thô thành lệnh rời rạc.
///
/// Ba việc, đều là thứ mà thiếu nó thì tay cầm dùng không nổi:
///
/// 1. **Vùng chết.** Cần gạt không bao giờ về đúng số 0; đẩy nhẹ vô tình cũng
///    không nên nhảy ô. Ngưỡng vào (0,55) cao hơn ngưỡng ra (0,35) nên giữ
///    nghiêng nghiêng không làm hướng nhấp nháy.
/// 2. **Giữ để lặp.** Bấm một cái đi một ô; giữ thì chờ một nhịp rồi chạy đều
///    — giống hệt cách phím mũi tên trên bàn phím cư xử.
/// 3. **Chỉ tính lúc bấm xuống.** Nút giữ lâu không được bắn ra hàng trăm lệnh.
class BoDichTayCam {
  BoDichTayCam({
    this.nguongVao = 0.55,
    this.nguongRa = 0.35,
    this.choLanDau = const Duration(milliseconds: 420),
    this.nhipLap = const Duration(milliseconds: 130),
  });

  final double nguongVao;
  final double nguongRa;

  /// Giữ bao lâu thì bắt đầu lặp.
  final Duration choLanDau;

  /// Lặp mỗi bao lâu sau đó.
  final Duration nhipLap;

  /// Nhịp cuộn của cần phải, từ lúc đẩy nhẹ tới lúc đẩy hết cỡ.
  ///
  /// Cuộn thì không có quãng chờ đầu như đi giữa các điểm chọn: đẩy là chạy
  /// ngay, và đẩy mạnh thì chạy nhanh hơn — giống hệt kéo thanh cuộn bằng tay.
  static const _cuonCham = Duration(milliseconds: 260);
  static const _cuonNhanh = Duration(milliseconds: 90);

  LenhTayCam? _huong;
  Duration _lanKe = Duration.zero;

  LenhTayCam? _cuon;
  Duration _cuonKe = Duration.zero;

  var _truoc = TrangThaiTayCam.khong;

  /// Đưa vào trạng thái đọc được lúc [bayGio], nhận về các lệnh cần làm.
  ///
  /// [bayGio] phải là đồng hồ chạy tới (Stopwatch), không phải giờ trong ngày —
  /// bài kiểm thử tua thời gian bằng tay, mà giờ hệ thống thì có thể nhảy lùi.
  List<LenhTayCam> capNhat(TrangThaiTayCam nay, Duration bayGio) {
    final ra = <LenhTayCam>[];

    // -- cần gạt và phím mũi tên --------------------------------------------
    final huong = _huongCua(nay);
    if (huong != _huong) {
      _huong = huong;
      if (huong != null) {
        ra.add(huong);
        _lanKe = bayGio + choLanDau;
      }
    } else if (huong != null && bayGio >= _lanKe) {
      ra.add(huong);
      _lanKe = bayGio + nhipLap;
    }

    // -- cần phải: cuộn phần chữ --------------------------------------------
    final cuon = nay.yPhai.abs() < (_cuon == null ? nguongVao : nguongRa)
        ? null
        : (nay.yPhai > 0 ? LenhTayCam.cuonLen : LenhTayCam.cuonXuong);
    if (cuon != _cuon) {
      _cuon = cuon;
      if (cuon != null) {
        ra.add(cuon);
        _cuonKe = bayGio + _nhipCuon(nay.yPhai.abs());
      }
    } else if (cuon != null && bayGio >= _cuonKe) {
      ra.add(cuon);
      _cuonKe = bayGio + _nhipCuon(nay.yPhai.abs());
    }

    // -- nút: chỉ tính lúc bấm xuống ----------------------------------------
    if (nay.chon && !_truoc.chon) ra.add(LenhTayCam.chon);
    if (nay.quayLai && !_truoc.quayLai) ra.add(LenhTayCam.quayLai);
    if (nay.phatDung && !_truoc.phatDung) ra.add(LenhTayCam.phatDung);
    if (nay.vaiTrai && !_truoc.vaiTrai) ra.add(LenhTayCam.tabTruoc);
    if (nay.vaiPhai && !_truoc.vaiPhai) ra.add(LenhTayCam.tabSau);
    _truoc = nay;

    return ra;
  }

  /// Đẩy càng mạnh, cuộn càng nhanh.
  Duration _nhipCuon(double manh) {
    final phan = ((manh - nguongVao) / (1 - nguongVao)).clamp(0.0, 1.0);
    final ms = _cuonCham.inMilliseconds +
        (_cuonNhanh.inMilliseconds - _cuonCham.inMilliseconds) * phan;
    return Duration(milliseconds: ms.round());
  }

  /// Hướng đang nghiêng, null nếu cần gạt đang ở giữa.
  ///
  /// Trục nào lấn hơn thì trục ấy thắng — đẩy chéo không được tính là hai
  /// hướng cùng lúc, không thì đi một bước là nhảy hai ô.
  LenhTayCam? _huongCua(TrangThaiTayCam t) {
    final nguong = _huong == null ? nguongVao : nguongRa;
    final ngang = t.x.abs();
    final doc = t.y.abs();
    if (ngang < nguong && doc < nguong) return null;
    if (ngang >= doc) return t.x > 0 ? LenhTayCam.phai : LenhTayCam.trai;
    return t.y > 0 ? LenhTayCam.len : LenhTayCam.xuong;
  }
}

/// Nguồn trạng thái tay cầm của một hệ máy.
abstract class NguonTayCam {
  /// Trạng thái đọc được lúc này.
  TrangThaiTayCam doc();

  /// Có tay cầm nào đang cắm không — dùng để giảm nhịp hỏi khi không có.
  bool get coTayCam;

  /// [danhThuc] để nguồn nào có tin đẩy (Android) gọi ngay khi trạng thái đổi.
  ///
  /// Thiếu nó thì cú bấm nhanh bị nuốt mất: lúc chưa thấy tay cầm, vòng lặp chỉ
  /// ngó mỗi giây một lần, mà bấm rồi nhả trong vòng một giây thì tới lượt ngó
  /// nút đã về chỗ cũ — không còn sườn lên nào để mà thấy. Nguồn hỏi-vòng
  /// (Windows) thì bỏ qua tham số này.
  Future<void> mo(void Function() danhThuc) async {}
  Future<void> dong() async {}
}

/// Nhịp hỏi khi đang có tay cầm. 60 lần mỗi giây, bằng nhịp vẽ của giao diện.
const _nhipCo = Duration(milliseconds: 16);

/// Nhịp hỏi khi chưa thấy tay cầm nào.
///
/// XInput hỏi vào khe trống là tốn thật (Microsoft ghi rõ trong tài liệu:
/// đừng hỏi khe chưa cắm mỗi khung hình), nên lúc chưa có gì thì mỗi giây ngó
/// một lần là đủ nhanh với người vừa cắm tay cầm vào.
const _nhipKhong = Duration(seconds: 1);

/// Tay cầm của máy này, đã gộp cả hai hệ.
class TayCam {
  TayCam({required this.onLenh, NguonTayCam? nguon, BoDichTayCam? boDich})
      : _boDich = boDich ?? BoDichTayCam(),
        _nguon = nguon ?? _nguonCuaMay();

  final void Function(LenhTayCam) onLenh;
  final BoDichTayCam _boDich;
  final NguonTayCam? _nguon;

  final _dongHo = Stopwatch();
  Timer? _hen;

  /// Máy này có đường nào nhận tay cầm không.
  bool get hoTro => _nguon != null;

  static NguonTayCam? _nguonCuaMay() {
    if (Platform.isWindows) return NguonXInput();
    if (Platform.isAndroid) return NguonTayCamAndroid();
    return null;
  }

  Future<void> batDau() async {
    final nguon = _nguon;
    if (nguon == null || _hen != null) return;
    await nguon.mo(_danhThuc);
    _dongHo.start();
    _hen = Timer(Duration.zero, _motNhip);
  }

  /// Có tin mới từ nguồn đẩy: ngó ngay chứ không đợi hết nhịp.
  void _danhThuc() {
    if (_hen == null) return; // chưa bắt đầu hoặc đã dừng
    _hen!.cancel();
    _motNhip();
  }

  Future<void> dungLai() async {
    _hen?.cancel();
    _hen = null;
    _dongHo.stop();
    await _nguon?.dong();
  }

  void _motNhip() {
    final nguon = _nguon;
    if (nguon == null) return;
    for (final lenh in _boDich.capNhat(nguon.doc(), _dongHo.elapsed)) {
      onLenh(lenh);
    }
    _hen = Timer(nguon.coTayCam ? _nhipCo : _nhipKhong, _motNhip);
  }
}

/// Android: `MainActivity.kt` bắt nút và cần gạt rồi đẩy qua kênh này.
///
/// Bên Kotlin nuốt luôn sự kiện của tay cầm (trả về true) nên Flutter không
/// thấy chúng dưới dạng phím mũi tên nữa — nếu không thì phím mũi tên của tay
/// cầm sẽ rơi vào chỗ xử lý bàn phím của màn hình nghe và thành lệnh tua.
class NguonTayCamAndroid implements NguonTayCam {
  static const _kenh = EventChannel('sachnoi/tay_cam');

  StreamSubscription<dynamic>? _dang;
  var _co = false;
  void Function()? _danhThuc;

  // Giữ từng thành phần rời rồi mới gộp lúc đọc, chứ không sửa dần vào một ảnh
  // chụp: cùng một hướng có thể tới từ hai đường (phím mũi tên và cần gạt), cùng
  // một nút vai cũng vậy (phím L2 và trục cò). Sửa dần thì đường nọ xoá đường
  // kia — thả cần gạt là mất luôn phím mũi tên đang giữ.
  double _x = 0;
  double _y = 0;
  double _xPhai = 0;
  double _yPhai = 0;
  var _phimLen = false;
  var _phimXuong = false;
  var _phimTrai = false;
  var _phimPhai = false;
  var _chon = false;
  var _quayLai = false;
  var _phatDung = false;
  var _vaiTraiPhim = false;
  var _vaiPhaiPhim = false;
  var _coTrai = false;
  var _coPhai = false;

  @override
  bool get coTayCam => _co;

  @override
  TrangThaiTayCam doc() => TrangThaiTayCam(
        // Phím mũi tên đang giữ thì lấn cần gạt: nó rõ ý hơn.
        x: _phimTrai
            ? -1
            : _phimPhai
                ? 1
                : _x,
        y: _phimLen
            ? 1
            : _phimXuong
                ? -1
                : _y,
        xPhai: _xPhai,
        yPhai: _yPhai,
        chon: _chon,
        quayLai: _quayLai,
        phatDung: _phatDung,
        vaiTrai: _vaiTraiPhim || _coTrai,
        vaiPhai: _vaiPhaiPhim || _coPhai,
      );

  @override
  Future<void> mo(void Function() danhThuc) async {
    _danhThuc = danhThuc;
    _dang ??= _kenh.receiveBroadcastStream().listen(_nhan, onError: (Object _) {});
  }

  @override
  Future<void> dong() async {
    await _dang?.cancel();
    _dang = null;
  }

  void _nhan(dynamic tin) {
    if (tin is! Map) return;
    _co = true;
    double so(String ten) => (tin[ten] as num?)?.toDouble() ?? 0;

    switch (tin['loai']) {
      case 'can':
        _x = so('x');
        // Android để trục dọc dương là XUỐNG, quy ước ở đây ngược lại.
        _y = -so('y');
        _xPhai = so('xPhai');
        _yPhai = -so('yPhai');
        _coTrai = tin['coTrai'] == true;
        _coPhai = tin['coPhai'] == true;
      case 'nut':
        final xuong = tin['xuong'] == true;
        switch (tin['ma']) {
          case 'chon':
            _chon = xuong;
          case 'quayLai':
            _quayLai = xuong;
          case 'phatDung':
            _phatDung = xuong;
          case 'vaiTrai':
            _vaiTraiPhim = xuong;
          case 'vaiPhai':
            _vaiPhaiPhim = xuong;
          case 'len':
            _phimLen = xuong;
          case 'xuong':
            _phimXuong = xuong;
          case 'trai':
            _phimTrai = xuong;
          case 'phai':
            _phimPhai = xuong;
        }
    }
    // Xử lý ngay tại đây, đừng để cú bấm kịp nhả ra trước lượt ngó kế tiếp.
    _danhThuc?.call();
  }
}
