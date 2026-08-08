/// Lái giao diện bằng tay cầm chơi game.
///
/// Bọc quanh toàn bộ ứng dụng (xem `main.dart`) nên tay cầm chạy được ở mọi màn
/// hình, kể cả hộp thoại và bảng mở lên từ dưới.
///
/// Việc di chuyển dựa hẳn vào hệ tiêu điểm sẵn có của Flutter chứ không tự dựng
/// danh sách "các điểm chọn": mọi nút trong ứng dụng đều là InkWell/IconButton
/// nên đã nhận tiêu điểm và đã hiểu [ActivateIntent] từ trước. Nhờ vậy màn hình
/// mới thêm sau này tự dùng được tay cầm, không phải khai báo gì thêm.
///
/// Riêng chỗ nhìn thấy được thì phải tự vẽ: vệt sáng mặc định của Material quá
/// mờ để nhìn từ xa, mà dùng tay cầm thì thường là đang ngồi xa màn hình.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/tay_cam.dart';
import 'app_scope.dart';
import 'home_shell.dart';

/// Tay cầm đẩy một hướng vào widget đang được trỏ tới.
///
/// Widget nào muốn tự xử lý hướng — thanh kéo lúc đang chỉnh, xem
/// `thanh_keo_tay_cam.dart` — thì khai một action cho ý định này và trả về true.
/// Trả về null hay không khai gì thì hướng ấy quay về nghĩa mặc định: đi sang
/// điểm chọn kế bên.
class HuongTayCamIntent extends Intent {
  const HuongTayCamIntent(this.huong);
  final TraversalDirection huong;
}

/// Nút B. Trả về true nghĩa là widget đã tự lo (ví dụ bỏ chế độ chỉnh); không
/// thì nút B mang nghĩa quay lại màn hình trước.
class ThoatTayCamIntent extends Intent {
  const ThoatTayCamIntent();
}

/// Dòng lệnh tay cầm cho những chỗ cần nghe trực tiếp thay vì qua tiêu điểm.
///
/// Chỗ duy nhất đang dùng là khung chữ trong màn hình Nghe: cần phải cuộn nó
/// mà nó thì không phải một điểm chọn, không nằm trong đường tiêu điểm nào.
class LenhTayCamScope extends InheritedWidget {
  const LenhTayCamScope({super.key, required this.lenh, required super.child});

  final Stream<LenhTayCam> lenh;

  static Stream<LenhTayCam>? cua(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LenhTayCamScope>()?.lenh;

  @override
  bool updateShouldNotify(LenhTayCamScope cu) => cu.lenh != lenh;
}

class DieuKhienTayCam extends StatefulWidget {
  const DieuKhienTayCam({
    super.key,
    required this.child,
    required this.khoaDieuHuong,
    this.nguonLenh,
  });

  final Widget child;

  /// Chìa khoá của Navigator gốc, để nút B quay lại được.
  ///
  /// Không lấy Navigator từ context: widget này nằm ở `MaterialApp.builder`,
  /// tức là ở TRÊN Navigator chứ không ở dưới, tra ngược lên không thấy.
  final GlobalKey<NavigatorState> khoaDieuHuong;

  /// Nguồn lệnh thay thế, chỉ dùng trong kiểm thử. Null thì mở tay cầm thật.
  final Stream<LenhTayCam>? nguonLenh;

  @override
  State<DieuKhienTayCam> createState() => _DieuKhienTayCamState();
}

class _DieuKhienTayCamState extends State<DieuKhienTayCam> {
  TayCam? _tayCam;
  var _hienVong = false;
  Rect? _o;

  /// Phát lại lệnh cho những chỗ nghe trực tiếp — xem [LenhTayCamScope].
  final _phat = StreamController<LenhTayCam>.broadcast();
  StreamSubscription<LenhTayCam>? _dangNghe;

  @override
  void initState() {
    super.initState();
    if (widget.nguonLenh != null) {
      _dangNghe = widget.nguonLenh!.listen(_lam);
    } else {
      _tayCam = TayCam(onLenh: _lam)..batDau();
    }
    FocusManager.instance.addListener(_doiTieuDiem);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_doiTieuDiem);
    _dangNghe?.cancel();
    _tayCam?.dungLai();
    _phat.close();
    super.dispose();
  }

  // -- nhận lệnh -------------------------------------------------------------

  void _lam(LenhTayCam lenh) {
    if (!mounted) return;
    if (!_phat.isClosed) _phat.add(lenh);
    switch (lenh) {
      case LenhTayCam.len:
        _di(TraversalDirection.up);
      case LenhTayCam.xuong:
        _di(TraversalDirection.down);
      case LenhTayCam.trai:
        _di(TraversalDirection.left);
      case LenhTayCam.phai:
        _di(TraversalDirection.right);
      case LenhTayCam.chon:
        _bam();
      case LenhTayCam.quayLai:
        _quayLai();
      case LenhTayCam.phatDung:
        _phatDung();
      case LenhTayCam.tabTruoc:
        HomeShellState.hienTai?.tabKe(-1);
      case LenhTayCam.tabSau:
        HomeShellState.hienTai?.tabKe(1);
      // Cuộn khung chữ do chính khung ấy nghe qua [LenhTayCamScope], ở đây
      // không có việc gì phải làm.
      case LenhTayCam.cuonLen:
      case LenhTayCam.cuonXuong:
        break;
    }
    _bat();
  }

  /// Chuyển tiêu điểm theo một hướng.
  ///
  /// Widget đang được trỏ tới được ngỏ ý trước: thanh kéo lúc đang chỉnh sẽ nhận
  /// lấy trái/phải để đổi giá trị thay vì để tiêu điểm bỏ đi.
  void _di(TraversalDirection huong) {
    final dang = FocusManager.instance.primaryFocus;
    if (dang == null) return;
    final o = dang.context;
    if (o != null && Actions.maybeInvoke(o, HuongTayCamIntent(huong)) == true) return;
    // Đang đứng ở một điểm chọn thật thì đi theo hướng. Còn nếu đang đứng ở
    // node cỡ cả trang — màn hình Nghe bọc cả trang trong một Focus để bắt phím
    // tắt — thì tính hướng từ cái khung to đùng ấy ra kết quả lung tung, nên
    // nhảy thẳng vào điểm chọn đầu tiên bên trong.
    if (_laDiemChon(dang) && dang.focusInDirection(huong)) return;
    // Chưa trỏ vào đâu, hoặc đã đi tới mép: vào điểm chọn kế trong thứ tự đọc,
    // vẫn hơn là đứng im không phản ứng gì.
    dang.nextFocus();
  }

  /// Node này có phải một điểm chọn thật không, hay chỉ là khung bọc cả trang.
  bool _laDiemChon(FocusNode node) {
    if (node.context == null || !node.context!.mounted) return false;
    final r = node.rect;
    if (r.width <= 0 || r.height <= 0) return false;
    final man = MediaQuery.sizeOf(context);
    return r.width < man.width * 0.9 && r.height < man.height * 0.9;
  }

  /// Nút A: bấm đúng cái đang trỏ tới.
  ///
  /// [ActivateIntent] là đường mà chính bàn phím dùng khi bấm Enter/Space, nên
  /// nút nào bấm được bằng bàn phím thì bấm được bằng tay cầm.
  void _bam() {
    final o = FocusManager.instance.primaryFocus?.context;
    if (o == null) return;
    Actions.maybeInvoke(o, const ActivateIntent());
  }

  /// Nút B: widget đang trỏ tới được ngỏ ý trước (thanh kéo đang chỉnh thì bỏ
  /// chế độ chỉnh), không ai nhận thì mới quay lại màn hình trước.
  void _quayLai() {
    final o = FocusManager.instance.primaryFocus?.context;
    if (o != null && Actions.maybeInvoke(o, const ThoatTayCamIntent()) == true) return;
    widget.khoaDieuHuong.currentState?.maybePop();
  }

  void _phatDung() {
    // Tra thẳng chứ không dùng AppScope.of: widget này cũng chạy trong bài
    // kiểm thử, nơi không có AppScope nào phía trên.
    final scope = context.getInheritedWidgetOfExactType<AppScope>();
    scope?.notifier?.player.togglePlay();
  }

  // -- vòng chọn -------------------------------------------------------------

  /// Bắt đầu dùng tay cầm: hiện vòng chọn và bật vệt sáng tiêu điểm.
  void _bat() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    if (!_hienVong) setState(() => _hienVong = true);
    _doiTieuDiem();
  }

  /// Chạm chuột hay chạm màn hình thì cất vòng chọn đi — lúc ấy con trỏ mới là
  /// thứ người dùng đang nhìn, để lại cái vòng chỉ tổ rối mắt.
  void _tat() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    if (_hienVong) setState(() => _hienVong = false);
  }

  void _doiTieuDiem() {
    if (!mounted) return;
    _doO();
    // Đo lại sau khi khung hình kế vẽ xong, rồi lần nữa lúc cuộn đã dừng: đổi
    // tiêu điểm thường kéo theo một cú cuộn để đưa ô ấy vào tầm nhìn, đo ngay
    // là ra vị trí cũ.
    WidgetsBinding.instance.addPostFrameCallback((_) => _doO());
    Future.delayed(const Duration(milliseconds: 260), _doO);
  }

  void _doO() {
    if (!mounted) return;
    final node = FocusManager.instance.primaryFocus;
    Rect? o;
    // Node của cả một màn hình (ví dụ khung nghe bắt phím tắt) thì to bằng cả
    // trang — khoanh vòng quanh nó chẳng chỉ ra được điểm chọn nào.
    if (node != null && node.context != null && node.context!.mounted) {
      final r = node.rect;
      final man = MediaQuery.sizeOf(context);
      if (r.width > 0 && r.height > 0 && r.width < man.width * 0.9 && r.height < man.height * 0.9) {
        o = r;
      }
    }
    if (o != _o) setState(() => _o = o);
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    return Listener(
      onPointerDown: (_) => _tat(),
      child: Stack(
        children: [
          LenhTayCamScope(lenh: _phat.stream, child: widget.child),
          if (_hienVong && o != null)
            AnimatedPositioned(
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOut,
              left: o.left - 4,
              top: o.top - 4,
              width: o.width + 8,
              height: o.height + 8,
              child: const IgnorePointer(child: _VongChon()),
            ),
        ],
      ),
    );
  }
}

/// Vòng sáng quanh điểm đang chọn.
class _VongChon extends StatelessWidget {
  const _VongChon();

  @override
  Widget build(BuildContext context) {
    final mau = Theme.of(context).colorScheme.primary;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: mau, width: 2.5),
        boxShadow: [BoxShadow(color: mau.withValues(alpha: 0.45), blurRadius: 10, spreadRadius: 1)],
      ),
    );
  }
}
