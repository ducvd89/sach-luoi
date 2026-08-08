/// Khung chữ của màn hình Nghe: bám theo đoạn đang đọc, nhưng nhường quyền cho
/// người đọc khi họ tự cuộn.
///
/// Ba việc mà bản trước làm chưa đúng:
///
/// * **Mở lại sách phải nhảy đúng đoạn đang dở.** Trước đây dùng
///   `Scrollable.ensureVisible` trên một `GlobalKey`, mà cách đó chỉ chạy khi
///   widget đích *đã được dựng*. Đoạn nằm giữa một chương 300 đoạn thì chưa dựng,
///   nên lệnh cuộn âm thầm không làm gì và người đọc thấy chương từ đầu. Giờ
///   cuộn theo **chỉ số** nên không phụ thuộc widget đã dựng hay chưa.
/// * **Tự cuộn về sau 30 giây.** Người đọc cuộn lên xem lại đoạn cũ thì không
///   nên bị giật về ngay; nhưng để mãi thì cũng mất dấu chỗ đang đọc.
/// * **Thanh cuộn trên điện thoại quá mảnh.** Thêm một thanh kéo được bằng ngón
///   tay, nhảy theo đoạn chứ theo pixel — chương dài vài trăm đoạn thì kéo một
///   nhịp là tới.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models/book.dart';
import '../services/tay_cam.dart';
import 'dieu_khien_tay_cam.dart';
import 'fast_scrollbar.dart';

/// Đoạn đang đọc được đặt ở khoảng một phần ba từ trên xuống — mắt hay dừng ở
/// đó, và còn chỗ để thấy phần sắp đọc.
const _alignment = 0.32;

/// Không cuộn tay trong bao lâu thì tự bám lại đoạn đang đọc.
const _idleBeforeFollow = Duration(seconds: 30);

/// Thiết bị cảm ứng mới cần thanh kéo to; chuột thì đã có bánh xe và thanh mảnh.
bool get _touchDevice => Platform.isAndroid || Platform.isIOS;

class ReadingPane extends StatefulWidget {
  const ReadingPane({
    super.key,
    required this.chapter,
    required this.currentIndex,
    required this.chunks,
    required this.onTapChunk,
  });

  final Chapter? chapter;
  final int currentIndex;
  final List<Chunk> chunks;
  final void Function(int index) onTapChunk;

  @override
  State<ReadingPane> createState() => _ReadingPaneState();
}

class _ReadingPaneState extends State<ReadingPane> {
  final _scrollController = ItemScrollController();
  final _positions = ItemPositionsListener.create();

  /// Đang bám theo đoạn đọc hay đang để người đọc tự do cuộn.
  bool _following = true;
  Timer? _idleTimer;

  /// Chỉ số đoạn đầu tiên đang nhìn thấy — dùng vẽ vị trí thanh kéo.
  int _firstVisible = 0;

  int? _lastFollowed;
  int? _lastChapter;

  /// Đang nghe lệnh cuộn từ cần phải của tay cầm.
  StreamSubscription<LenhTayCam>? _tayCam;

  @override
  void initState() {
    super.initState();
    _positions.itemPositions.addListener(_onPositions);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Khung chữ không phải một điểm chọn nên không nằm trong đường tiêu điểm
    // nào — nghe thẳng dòng lệnh thay vì chờ tiêu điểm rơi vào đây.
    _tayCam?.cancel();
    _tayCam = LenhTayCamScope.cua(context)?.listen(_nhanLenh);
  }

  @override
  void dispose() {
    _tayCam?.cancel();
    _positions.itemPositions.removeListener(_onPositions);
    _idleTimer?.cancel();
    super.dispose();
  }

  void _nhanLenh(LenhTayCam lenh) {
    if (!mounted) return;
    switch (lenh) {
      case LenhTayCam.cuonLen:
        _cuonTayCam(-1);
      case LenhTayCam.cuonXuong:
        _cuonTayCam(1);
      default:
        break;
    }
  }

  /// Đích của lượt cuộn tay cầm gần nhất, và lúc nó được ra lệnh.
  ///
  /// Phải tự nhớ đích chứ không thể cứ lấy [_firstVisible] làm mốc: giữ cần
  /// phải thì lệnh kế tới sau 90 ms mà cú cuộn mất 140 ms mới xong, nên vị trí
  /// đang nhìn còn là vị trí cũ — tính từ đó ra lại đúng cái đích vừa đặt, và
  /// khung chữ đứng im như bị kẹt.
  int? _dichCuon;
  DateTime? _lucCuon;

  /// Cuộn một đoạn theo lệnh cần phải.
  ///
  /// Nhảy theo CHỈ SỐ đoạn chứ không theo pixel: danh sách này cuộn theo chỉ số
  /// (xem chú thích đầu file), mà một đoạn cũng vừa đúng một nhịp mắt đọc. Đây
  /// là cuộn để đọc chứ không phải để nhảy tới chỗ khác nên KHÔNG đổi đoạn đang
  /// phát, và cũng tính là người đọc tự cuộn nên nhả quyền bám như khi vuốt tay.
  void _cuonTayCam(int buoc) {
    if (!_scrollController.isAttached || _count == 0) return;
    _handedOver();

    final gio = DateTime.now();
    final luc = _lucCuon;
    final noiTiep = luc != null && gio.difference(luc) < const Duration(milliseconds: 500);
    final tu = noiTiep ? (_dichCuon ?? _firstVisible) : _firstVisible;
    _lucCuon = gio;

    final dich = (tu + buoc).clamp(0, _count - 1);
    if (dich == tu) return; // đã ở đầu hoặc cuối chương
    _dichCuon = dich;
    _scrollController.scrollTo(
      index: dich,
      alignment: 0,
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
    );
  }

  int get _from => widget.chapter?.firstChunk ?? 0;
  int get _count {
    final chapter = widget.chapter;
    if (chapter == null) return 0;
    final to = chapter.lastChunk.clamp(0, widget.chunks.length - 1);
    return to - _from + 1;
  }

  /// Vị trí của đoạn đang đọc trong danh sách của chương này.
  int get _currentRow => (widget.currentIndex - _from).clamp(0, _count == 0 ? 0 : _count - 1);

  void _onPositions() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty) return;
    final first = positions
        .where((p) => p.itemTrailingEdge > 0)
        .fold<int>(_count, (min, p) => p.index < min ? p.index : min);
    if (first != _firstVisible && first < _count) {
      setState(() => _firstVisible = first);
    }
  }

  /// Người đọc vừa tự cuộn: thả quyền bám, và hẹn 30 giây sau lấy lại.
  void _handedOver() {
    _idleTimer?.cancel();
    if (_following) setState(() => _following = false);
    _idleTimer = Timer(_idleBeforeFollow, () {
      if (!mounted) return;
      setState(() => _following = true);
      _scrollTo(_currentRow, jump: false);
    });
  }

  void _scrollTo(int row, {required bool jump}) {
    if (!_scrollController.isAttached || _count == 0) return;
    final target = row.clamp(0, _count - 1);
    if (jump) {
      _scrollController.jumpTo(index: target, alignment: _alignment);
    } else {
      _scrollController.scrollTo(
        index: target,
        alignment: _alignment,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Bám theo đoạn đang đọc khi nó đổi, và nhảy thẳng khi vừa sang chương khác.
  void _followIfNeeded() {
    final chapterIndex = widget.chapter?.index;
    final changedChapter = chapterIndex != _lastChapter;
    _lastChapter = chapterIndex;

    if (changedChapter) {
      // Sang chương mới thì luôn bám lại, kể cả đang để người đọc tự do.
      _lastFollowed = widget.currentIndex;
      _idleTimer?.cancel();
      _following = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(_currentRow, jump: true));
      return;
    }

    if (!_following || _lastFollowed == widget.currentIndex) return;
    _lastFollowed = widget.currentIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollTo(_currentRow, jump: false));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.chapter == null || widget.chunks.isEmpty || _count == 0) {
      return const Center(child: CircularProgressIndicator());
    }
    _followIfNeeded();

    // Nhận biết người đọc qua SỰ KIỆN CON TRỎ chứ không qua thông báo cuộn:
    // lệnh cuộn của chính mình cũng sinh ra thông báo cuộn, nghe theo đó thì
    // vừa cuộn tới đoạn đọc đã tự cho là bị can thiệp rồi nhả ra — thành vòng
    // lặp. Con trỏ thì chỉ động khi có người thật.
    //
    // Chỉ tính khi ngón tay DI CHUYỂN hoặc lăn bánh xe; chạm một cái để chọn
    // đoạn không phải là cuộn nên không nhả quyền bám.
    final list = Listener(
      onPointerMove: (_) => _handedOver(),
      onPointerSignal: (_) => _handedOver(),
      // Từng đoạn văn là một InkWell (chạm để nhảy tới đoạn ấy) nên mặc định nó
      // cũng là một điểm nhận tiêu điểm. Với chuột thì vô hại, nhưng với tay cầm
      // thì cả chương vài trăm đoạn biến thành vài trăm điểm chọn: gạt cần xuống
      // một cái là trôi vào giữa bài đọc rồi cuộn mãi không ra được. Bỏ hẳn khỏi
      // đường tiêu điểm — chạm và bấm chuột vẫn nguyên, vì hai việc đó đi bằng
      // sự kiện con trỏ chứ không qua tiêu điểm. Muốn đọc lướt bằng tay cầm thì
      // đã có cần phải để cuộn (xem [_cuonTayCam]).
      child: ExcludeFocus(
        child: ScrollablePositionedList.builder(
          itemScrollController: _scrollController,
          itemPositionsListener: _positions,
          // Mở lại sách là thấy ngay đoạn đang dở, không cần chờ lệnh cuộn nào.
          initialScrollIndex: _currentRow,
          initialAlignment: _alignment,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 26),
          itemCount: _count,
          itemBuilder: (context, row) => _Paragraph(
            chunk: widget.chunks[_from + row],
            isCurrent: _from + row == widget.currentIndex,
            isDone: _from + row < widget.currentIndex,
            onTap: () => widget.onTapChunk(_from + row),
          ),
        ),
      ),
    );

    return Stack(
      children: [
        Positioned.fill(child: list),
        if (_touchDevice)
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            child: FastScrollBar(
              count: _count,
              firstVisible: _firstVisible,
              onJump: (row) {
                _handedOver();
                _scrollTo(row, jump: true);
              },
            ),
          ),
        // Đang để người đọc tự do thì cho một nút quay lại ngay, khỏi phải đợi
        // hết 30 giây.
        if (!_following)
          Positioned(
            right: _touchDevice ? 44 : 12,
            bottom: 12,
            child: _BackToReading(
              onTap: () {
                _idleTimer?.cancel();
                setState(() => _following = true);
                _scrollTo(_currentRow, jump: false);
              },
            ),
          ),
      ],
    );
  }
}

class _Paragraph extends StatelessWidget {
  const _Paragraph({
    required this.chunk,
    required this.isCurrent,
    required this.isDone,
    required this.onTap,
  });

  final Chunk chunk;
  final bool isCurrent;
  final bool isDone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final baseColor = Theme.of(context).textTheme.bodyLarge?.color;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: InkWell(
            borderRadius: BorderRadius.circular(9),
            onTap: onTap,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: isCurrent ? scheme.primaryContainer.withValues(alpha: 0.45) : null,
                borderRadius: BorderRadius.circular(9),
                border:
                    isCurrent ? Border(left: BorderSide(color: scheme.primary, width: 3)) : null,
              ),
              child: Text(
                chunk.display,
                style: TextStyle(
                  fontSize: chunk.heading ? 19 : 17,
                  height: 1.8,
                  fontWeight: chunk.heading ? FontWeight.w700 : null,
                  color: isCurrent ? baseColor : baseColor?.withValues(alpha: isDone ? 0.55 : 0.78),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thanh kéo nhanh cho điện thoại.
///
/// Kéo theo chỉ số đoạn chứ không theo pixel: một chương có thể dài vài trăm
/// đoạn với chiều cao rất khác nhau, tính theo pixel thì thanh nhảy giật cục và
/// không đoán được mình đang ở đâu.
/// Nút nhỏ để quay lại đoạn đang đọc ngay, không cần đợi hết 30 giây.
class _BackToReading extends StatelessWidget {
  const _BackToReading({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      borderRadius: BorderRadius.circular(99),
      elevation: 2,
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.my_location, size: 16, color: scheme.onSecondaryContainer),
              const SizedBox(width: 7),
              Text(
                'Về chỗ đang đọc',
                style: TextStyle(fontSize: 12.5, color: scheme.onSecondaryContainer),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
