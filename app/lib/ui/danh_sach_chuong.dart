/// Danh sách chương của màn hình Nghe: cột dọc trên máy tính, bảng mở từ dưới
/// lên trên điện thoại.
///
/// Tách khỏi `player_page.dart` vì phần lái bằng tay cầm ở đây có luật riêng đủ
/// rắc rối để đáng được soi bằng kiểm thử — mà muốn soi được thì nó không được
/// đụng tới AppScope, nên chọn chương báo ra ngoài bằng [DanhSachChuong.onChon].
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/book.dart';
import 'dieu_khien_tay_cam.dart';
import 'fast_scrollbar.dart';
import 'theme.dart';

class DanhSachChuong extends StatefulWidget {
  const DanhSachChuong({
    super.key,
    required this.book,
    required this.currentChapter,
    required this.onChon,
    this.onPicked,
    this.tuNhanTieuDiem = false,
  });
  final Book book;
  final Chapter? currentChapter;

  /// Người dùng đã chọn một chương — bằng cách chạm, hay bằng nút A của tay cầm.
  final void Function(Chapter chuong) onChon;

  /// Gọi sau khi chọn chương — bản mở từ dưới lên dùng để tự đóng lại.
  final VoidCallback? onPicked;

  /// Vừa hiện ra là nhận luôn tiêu điểm.
  ///
  /// Chỉ bật cho bảng mở từ dưới lên: mở bảng chọn chương ra thì việc duy nhất
  /// người dùng định làm là chọn chương. Bản cột dọc trên máy tính thì không —
  /// nó nằm đó suốt, cướp tiêu điểm lúc mở sách là sai.
  final bool tuNhanTieuDiem;

  @override
  State<DanhSachChuong> createState() => _DanhSachChuongState();
}

class _DanhSachChuongState extends State<DanhSachChuong> {
  final _controller = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  int _firstVisible = 0;

  /// Thanh cuộn kéo tay chỉ có ích khi vuốt là cách duy nhất để đi — trên máy
  /// tính đã có chuột và bánh xe.
  bool get _dungThanhKeo => Platform.isAndroid || Platform.isIOS;

  /// Chương mà tay cầm đang trỏ tới.
  ///
  /// Phải tự giữ lấy chứ không thể để tiêu điểm của Flutter tự mò theo hình
  /// học: danh sách này chỉ dựng những dòng đang nhìn thấy, nên đi tới mép là
  /// dòng kế CHƯA TỒN TẠI, phép tìm "ô gần nhất theo hướng ấy" không thấy gì
  /// bèn nhảy sang một ô lạc lõng đâu đó — đúng cảnh tiêu điểm chạy loạn.
  late int _chonTayCam;

  /// Danh sách đang giữ tiêu điểm — lúc ấy mới vẽ viền ô đang trỏ.
  var _dungTayCam = false;

  @override
  void initState() {
    super.initState();
    // Mở ra là thấy ngay chương đang nghe. Sách 2.467 chương mà bắt đầu từ
    // chương 1 thì người dùng phải tự cuộn tìm chỗ mình đang đọc.
    _firstVisible = _viTriHienTai();
    _chonTayCam = _viTriHienTai();
    _positions.itemPositions.addListener(_theoDoi);
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_theoDoi);
    super.dispose();
  }

  int _viTriHienTai() {
    final at = widget.book.chapters.indexWhere((c) => c.index == widget.currentChapter?.index);
    return at < 0 ? 0 : at;
  }

  void _theoDoi() {
    final hien = _positions.itemPositions.value;
    if (hien.isEmpty) return;
    final dau = hien.where((p) => p.itemTrailingEdge > 0).fold<int>(
        hien.first.index, (nho, p) => p.index < nho ? p.index : nho);
    if (dau != _firstVisible && mounted) setState(() => _firstVisible = dau);
  }

  /// Vừa nhận tiêu điểm thì trỏ về đúng chương đang nghe.
  ///
  /// Mở bảng chọn chương ra là để tìm quanh chỗ mình đang nghe, không phải để
  /// bắt đầu từ chương 1 của cuốn sách 2.467 chương.
  void _doiTieuDiem(bool co) {
    if (!mounted) return;
    setState(() {
      _dungTayCam = co;
      if (co) _chonTayCam = _viTriHienTai();
    });
    if (co && _controller.isAttached) {
      _controller.scrollTo(
        index: _chonTayCam,
        alignment: 0.35,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    }
  }

  /// Tay cầm đẩy lên/xuống: dời ô đang trỏ trong danh sách.
  ///
  /// Trả về true khi đã dùng, để lệnh ấy KHÔNG rơi ra ngoài thành lệnh đổi tiêu
  /// điểm. Chỉ nhả ra khi đã ở đúng đầu hoặc cuối danh sách — nếu nuốt cả ở hai
  /// đầu thì bản cột dọc trên máy tính thành cái bẫy, vào rồi không ra được.
  bool _diTayCam(TraversalDirection huong) {
    final so = widget.book.chapters.length;
    if (so == 0) return false;
    final buoc = switch (huong) {
      TraversalDirection.up => -1,
      TraversalDirection.down => 1,
      // Trái/phải để nguyên nghĩa cũ: rời khỏi danh sách sang cột bên cạnh.
      _ => 0,
    };
    if (buoc == 0) return false;

    final dich = _chonTayCam + buoc;
    if (dich < 0 || dich >= so) return false; // tới mép, nhường lại cho bên ngoài
    setState(() => _chonTayCam = dich);
    if (_controller.isAttached) {
      _controller.scrollTo(
        index: dich,
        alignment: 0.35,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
      );
    }
    return true;
  }

  /// Nút A: nghe chương đang trỏ tới.
  bool _chonChuong() {
    final chapters = widget.book.chapters;
    if (_chonTayCam < 0 || _chonTayCam >= chapters.length) return false;
    widget.onChon(chapters[_chonTayCam]);
    widget.onPicked?.call();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // Cả danh sách là MỘT điểm nhận tiêu điểm, không phải mỗi chương một điểm:
    // xem chú thích ở [_chonTayCam]. Lên/xuống được nhận ở đây rồi tự dời ô
    // đang trỏ, nên không còn chuyện tiêu điểm nhảy ra ngoài giữa chừng.
    // Actions phải nằm TRÊN Focus, không phải dưới: lớp lái tay cầm gọi
    // Actions.maybeInvoke với context của chính node đang giữ tiêu điểm, mà
    // phép tra ấy chỉ đi ngược LÊN cây. Đặt dưới thì không ai tìm thấy, nút A
    // bấm vào chẳng có gì xảy ra.
    return Actions(
      actions: {
        HuongTayCamIntent: CallbackAction<HuongTayCamIntent>(
          onInvoke: (y) => _diTayCam(y.huong) ? true : null,
        ),
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _chonChuong()),
      },
      child: Focus(
        autofocus: widget.tuNhanTieuDiem,
        onFocusChange: _doiTieuDiem,
        child: _than(context),
      ),
    );
  }

  Widget _than(BuildContext context) {
    final book = widget.book;
    final currentChapter = widget.currentChapter;
    final onPicked = widget.onPicked;
    final hint = Theme.of(context).hintColor;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(book.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(
                '${book.author.isEmpty ? '' : '${book.author} · '}${book.chapters.length} chương',
                style: TextStyle(fontSize: 12.5, color: hint),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            children: [
              // Từng dòng chương bỏ khỏi đường tiêu điểm — cả danh sách chỉ có
              // một điểm nhận tiêu điểm là cái Focus bọc ngoài. Chạm và bấm
              // chuột vẫn nguyên vì chúng đi bằng sự kiện con trỏ.
              ExcludeFocus(
                child: ScrollablePositionedList.builder(
            itemScrollController: _controller,
            itemPositionsListener: _positions,
            initialScrollIndex: _viTriHienTai(),
            initialAlignment: 0.25,
            padding: EdgeInsets.only(
                top: 6, bottom: 6, left: 8, right: _dungThanhKeo ? 42 : 8),
            itemCount: book.chapters.length,
            itemBuilder: (context, i) {
              final chapter = book.chapters[i];
              final selected = chapter.index == currentChapter?.index;
              // Hai thứ khác nhau, phải nhìn ra được: chương ĐANG NGHE (nền
              // đậm) và chương TAY CẦM ĐANG TRỎ (viền). Thường thì hai cái
              // trùng nhau lúc vừa mở bảng, rồi tách ra khi người dùng đi tìm.
              final dangTro = _dungTayCam && i == _chonTayCam;
              return InkWell(
                borderRadius: BorderRadius.circular(9),
                // Chạm vẫn chọn được như cũ, và kéo luôn ô đang trỏ về đây để
                // hai lối điều khiển không nói hai chuyện khác nhau.
                onTap: () {
                  setState(() => _chonTayCam = i);
                  widget.onChon(chapter);
                  onPicked?.call();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  decoration: BoxDecoration(
                    color: selected ? scheme.primaryContainer.withValues(alpha: 0.55) : null,
                    borderRadius: BorderRadius.circular(9),
                    border: dangTro ? Border.all(color: scheme.primary, width: 2) : null,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          chapter.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: selected ? scheme.primary : null,
                            fontWeight: selected ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(formatTime(chapter.charCount / 14.5), style: TextStyle(fontSize: 11.5, color: hint)),
                    ],
                  ),
                ),
              );
                  },
                ),
              ),
              if (_dungThanhKeo && book.chapters.length > 12)
                Positioned(
                  top: 4,
                  bottom: 4,
                  right: 0,
                  child: FastScrollBar(
                    count: book.chapters.length,
                    firstVisible: _firstVisible,
                    labelBuilder: (i) => book.chapters[i].title,
                    onJump: (i) => _controller.jumpTo(index: i),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
