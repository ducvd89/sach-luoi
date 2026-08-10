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
      // Cuộn khung chữ và mở bảng chương do chính màn hình Nghe nghe lấy qua
      // [LenhTayCamScope] — ở đây không có việc gì phải làm.
      case LenhTayCam.cuonLen:
      case LenhTayCam.cuonXuong:
      case LenhTayCam.moChuong:
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

    // Đang đứng ở một KHUNG CHỨA chứ không phải điểm chọn: khung bọc cả trang
    // của màn hình Nghe, hay khung cuộn mà tiêu điểm rơi về sau khi danh sách
    // huỷ mất ô cũ lúc cuộn xa. Tính hướng từ những khung ấy ra kết quả lung
    // tung, vì tâm của chúng luôn nằm giữa màn hình.
    //
    // Danh sách chương KHÔNG rơi vào đây: nó cỡ cả trang nhưng bỏ hết các dòng
    // khỏi đường tiêu điểm nên không có điểm chọn nào bên trong, và nó tự lo
    // việc lên/xuống của mình.
    final laKhungChua =
        !_laDiemChon(dang) && dang.traversalDescendants.any((n) => n.canRequestFocus);

    // Khung chứa, hoặc ô đang trỏ đã trôi khỏi màn hình sau một lượt cuộn bằng
    // cần phải: bắt đầu lại từ mục đầu tiên còn nhìn thấy.
    if (laKhungChua || !_thayDuoc(dang)) {
      final dau = _mucDauTienThayDuoc(dang);
      if (dau != null) {
        _chuyenToi(dau);
        return;
      }
    }

    final dich = _theoHuong(dang, huong);
    if (dich != null) {
      _chuyenToi(dich);
      return;
    }
    // Hết đường theo hướng ấy thì đứng yên. Nhảy đi đâu đó là người dùng mất dấu.
  }

  /// Vùng thật sự còn nhìn thấy được của một ô: màn hình, cắt tiếp bởi mọi
  /// khung cuộn bọc quanh nó.
  ///
  /// Chỉ đo theo màn hình là chưa đủ. Trang nội dung chừa sẵn chỗ cho thanh
  /// điều hướng và thanh phát thu nhỏ ở đáy, nên một mục cuộn quá đáy khung
  /// cuộn vẫn nằm trong màn hình — nhưng nó đã bị cắt mất và khuất sau hai
  /// thanh ấy. Trỏ vào đó thì người dùng thấy vòng sáng nhảy xuống một chỗ
  /// trống.
  ///
  /// Đi ngược lên nhiều tầng vì Thư viện là lưới lồng trong danh sách.
  Rect _khungThay(BuildContext o) {
    var khung = Offset.zero & MediaQuery.sizeOf(context);
    var cuon = Scrollable.maybeOf(o);
    for (var tang = 0; cuon != null && tang < 5; tang++) {
      final hop = cuon.context.findRenderObject();
      if (hop is RenderBox && hop.hasSize) {
        khung = khung.intersect(hop.localToGlobal(Offset.zero) & hop.size);
      }
      cuon = Scrollable.maybeOf(cuon.context);
    }
    return khung;
  }

  /// Ô này có nằm trong tầm nhìn không (xét theo tâm).
  bool _thayDuoc(FocusNode node) {
    final o = node.context;
    if (o == null || !o.mounted) return false;
    return _khungThay(o).contains(node.rect.center);
  }

  /// Chuyển tiêu điểm, và cuộn tới nếu ô ấy đang nằm ngoài màn hình.
  ///
  /// Đi tới một chỗ không nhìn thấy mà trang đứng im thì người dùng tưởng nút
  /// bấm hỏng. [Scrollable.ensureVisible] lo phần cuộn, kể cả khi ô nằm trong
  /// danh sách lồng danh sách.
  void _chuyenToi(FocusNode node) {
    node.requestFocus();
    final o = node.context;
    if (o == null || !o.mounted) return;
    final khung = _khungThay(o);
    final r = node.rect;
    // Đã thấy trọn vẹn thì đừng cuộn: cuộn thừa một cái là cả trang giật.
    if (khung.contains(r.topLeft) && khung.contains(r.bottomRight)) return;
    Scrollable.ensureVisible(
      o,
      alignment: 0.5,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  /// Mục đầu tiên còn nhìn thấy trên màn hình, tính từ trên xuống rồi trái sang.
  FocusNode? _mucDauTienThayDuoc(FocusNode tu) {
    final pham = tu.nearestScope ?? FocusManager.instance.rootScope;
    FocusNode? tot;
    for (final node in pham.traversalDescendants) {
      if (!node.canRequestFocus || node.skipTraversal || !_laLa(node)) continue;
      if (node.context == null) continue; // chưa gắn vào cây thì chưa có toạ độ
      final o = node.rect;
      if (o.isEmpty || !_vuaTam(o) || !_thayDuoc(node)) continue;
      final cu = tot?.rect;
      if (cu == null || o.top < cu.top || (o.top == cu.top && o.left < cu.left)) {
        tot = node;
      }
    }
    return tot;
  }

  /// Điểm chọn kế tiếp theo [huong], hoặc null nếu hướng ấy không còn gì.
  ///
  /// Tự tính chứ KHÔNG dùng `FocusNode.focusInDirection` của Flutter: phép ấy
  /// chọn ra những ô không hề nằm về phía được bấm. Đo được trên chính bố cục
  /// của ứng dụng — đang ở mục "Nghe" của thanh tab (205→400, 509→589), bấm
  /// phải thì nó trả về một thẻ sách ở giữa trang (22→778, 228→462), trong khi
  /// mục "Xuất file" nằm ngay bên phải ở (400→594, 509→589). Người dùng thấy
  /// tiêu điểm "biến mất" vì thẻ ấy nằm tít trên kia, mà vòng sáng cũng không
  /// vẽ cho những khung to gần bằng cả trang.
  ///
  /// Luật ở đây là luật mà mắt người đoán được: trong số các ô nằm HẲN về phía
  /// ấy, ưu tiên ô CÙNG HÀNG (với trái/phải) hay CÙNG CỘT (với lên/xuống), rồi
  /// mới tới ô gần nhất. Nhờ vậy đi dọc thanh tab là đi hết thanh tab, không
  /// bao giờ văng ngang vào giữa trang.
  FocusNode? _theoHuong(FocusNode tu, TraversalDirection huong) {
    final goc = tu.rect;
    final ngang = huong == TraversalDirection.left || huong == TraversalDirection.right;

    FocusNode? tot;
    var hangTot = 99;
    var diemTot = double.infinity;

    // Chỉ tìm trong phạm vi đang mở: hộp thoại và bảng mở từ dưới lên có scope
    // riêng, không được nhảy xuống lớp bị chúng che.
    final pham = tu.nearestScope ?? FocusManager.instance.rootScope;

    for (final node in pham.traversalDescendants) {
      if (node == tu || !node.canRequestFocus || node.skipTraversal) continue;
      if (!_laLa(node)) continue; // khung chứa thì bỏ, chỉ nhắm vào đích thật
      if (node.context == null) continue; // chưa gắn vào cây thì chưa có toạ độ
      final o = node.rect;
      if (o.isEmpty || !_vuaTam(o)) continue;

      // Phải nằm hẳn về phía được bấm, xét theo tâm.
      final di = switch (huong) {
        TraversalDirection.left => goc.center.dx - o.center.dx,
        TraversalDirection.right => o.center.dx - goc.center.dx,
        TraversalDirection.up => goc.center.dy - o.center.dy,
        TraversalDirection.down => o.center.dy - goc.center.dy,
      };
      if (di <= 0) continue;

      // Chồng lấn theo trục vuông góc: cùng hàng (trái/phải) hay cùng cột
      // (lên/xuống) thì đó mới là "ô kế bên" theo nghĩa mắt nhìn thấy được.
      final chong = ngang
          ? _chongLan(goc.top, goc.bottom, o.top, o.bottom)
          : _chongLan(goc.left, goc.right, o.left, o.right);

      // Ô mà tâm nằm ngoài màn hình thì không nhìn thấy được — chỉ nhận làm
      // đường lui cuối cùng, và khi nhận thì [_chuyenToi] cuộn tới nó. Không có
      // mục này thì đi dọc thanh tab lại vớ phải một thẻ sách nằm sau thanh tab
      // và tràn xuống dưới mép màn hình: nó vẫn chồng hàng và còn gần hơn cả
      // mục kế bên.
      final trongTam = _thayDuoc(node);

      final int hang;
      if (chong > 0) {
        hang = 0;
      } else {
        // Lệch hàng thì chỉ nhận khi hướng được bấm là hướng TRỘI — đi xa theo
        // hướng ấy hơn là lệch sang bên. Nhờ vậy nút "THÊM SÁCH" ở góc phải
        // trên vẫn với tới được từ nút "Nghe tiếp" bên trái (lệch ngang ít hơn
        // khoảng cách dọc), còn ở mục cuối thanh tab thì bấm phải vẫn đứng yên
        // chứ không văng chếch lên nút của thanh phát thu nhỏ (lệch dọc nhiều
        // hơn khoảng cách ngang).
        //
        // Bắt buộc phải chồng hàng thì chặt quá: nửa trên màn hình thành ngõ
        // cụt, không cách nào trỏ tới.
        //
        // Hệ số 2 chứ không phải 1: đo trên màn hình thật, từ "Nghe tiếp" lên
        // "THÊM SÁCH" lệch ngang 443 px so với khoảng cách dọc 543 px — lấy
        // đúng 1 thì chỉ vừa lọt, đổi cỡ chữ hay xoay máy một cái là hụt.
        if (-chong >= di * 2) continue;
        hang = 1;
      }

      // Thứ tự ưu tiên: thấy được & cùng hàng, thấy được & lệch hàng, rồi mới
      // tới những ô nằm ngoài tầm nhìn (để còn cuộn tới được nếu chẳng còn gì).
      final uuTien = hang + (trongTam ? 0 : 2);

      // Cùng hàng thì xếp theo khoảng cách; lệch hàng thì cộng cả phần lệch.
      final diem = chong > 0 ? di : di - chong;
      if (uuTien < hangTot || (uuTien == hangTot && diem < diemTot)) {
        hangTot = uuTien;
        diemTot = diem;
        tot = node;
      }
    }
    return tot;
  }

  /// Độ chồng lấn của hai đoạn [a1,a2] và [b1,b2]; <= 0 là không chồng.
  static double _chongLan(double a1, double a2, double b1, double b2) =>
      (a2 < b2 ? a2 : b2) - (a1 > b1 ? a1 : b1);

  /// Node này có phải một điểm chọn thật không, hay chỉ là khung chứa.
  bool _laDiemChon(FocusNode node) {
    if (node.context == null || !node.context!.mounted) return false;
    return _vuaTam(node.rect) && _laLa(node);
  }

  /// Có nên khoanh vòng sáng quanh ô này không.
  ///
  /// Trỏ tới được không có nghĩa là đáng khoanh. Ô chiếm phần lớn màn hình thì
  /// vòng sáng chẳng chỉ ra được gì, mà còn phủ một lớp sáng lên đúng chỗ đang
  /// cần đọc. Bảng chọn chương là ví dụ: nó tự vẽ viền cho chương đang trỏ rồi,
  /// khoanh thêm cả bảng chỉ làm chữ khó đọc.
  bool _dangKhoanhVong(Rect r) {
    if (!_vuaTam(r)) return false;
    final man = MediaQuery.sizeOf(context);
    final caManHinh = man.width * man.height;
    return caManHinh <= 0 || r.width * r.height < caManHinh * 0.4;
  }

  /// Không còn điểm chọn nào bên trong — tức đây là đích thật sự, không phải
  /// lớp bọc.
  ///
  /// Đây mới là cách phân biệt đúng, chứ không phải xét cỡ. Khung cuộn của
  /// Thư viện chỉ cao bằng hai phần ba màn hình nhưng vẫn là khung chứa; còn
  /// thanh chọn chương thì rộng hết bề ngang mà vẫn là đích. Xét cỡ thì hoặc
  /// bỏ sót cái này, hoặc loại oan cái kia.
  static bool _laLa(FocusNode node) =>
      !node.traversalDescendants.any((n) => n.canRequestFocus);

  /// Ô này có đáng coi là một điểm chọn không, xét theo cỡ.
  ///
  /// Khung to gần bằng cả trang thì không phải chỗ để trỏ tới: đó là khung cuộn
  /// hay lớp bọc bắt phím tắt. Vòng sáng cũng không vẽ cho chúng (xem [_doO]),
  /// nên nhảy vào là người dùng thấy tiêu điểm biến mất.
  ///
  /// Phải to ở CẢ HAI chiều mới tính là khung bọc. Bản trước đòi ô phải nhỏ ở
  /// cả hai chiều, nên mọi thanh trải hết bề ngang đều bị loại oan — thanh chọn
  /// chương ở đầu màn hình Nghe rộng bằng cả màn hình mà chỉ cao hơn trăm pixel,
  /// thế là tay cầm không bao giờ trỏ tới nó được.
  bool _vuaTam(Rect r) {
    if (r.width <= 0 || r.height <= 0) return false;
    final man = MediaQuery.sizeOf(context);
    return !(r.width >= man.width * 0.9 && r.height >= man.height * 0.9);
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
    // trang — khoanh vòng quanh nó chẳng chỉ ra được điểm chọn nào. Dùng chung
    // đúng phép đo với [_theoHuong]: chỗ nào trỏ tới được thì chỗ ấy phải vẽ
    // được vòng sáng, không thì tiêu điểm lại "biến mất" theo kiểu khác.
    if (node != null && node.context != null && node.context!.mounted && _dangKhoanhVong(node.rect)) {
      o = node.rect;
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
