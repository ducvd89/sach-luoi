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

  @override
  void initState() {
    super.initState();
    _positions.itemPositions.addListener(_onPositions);
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_onPositions);
    _idleTimer?.cancel();
    super.dispose();
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
    );

    return Stack(
      children: [
        Positioned.fill(child: list),
        if (_touchDevice)
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            child: _FastScrollBar(
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
class _FastScrollBar extends StatefulWidget {
  const _FastScrollBar({
    required this.count,
    required this.firstVisible,
    required this.onJump,
  });

  final int count;
  final int firstVisible;
  final void Function(int row) onJump;

  @override
  State<_FastScrollBar> createState() => _FastScrollBarState();
}

class _FastScrollBarState extends State<_FastScrollBar> {
  static const _width = 38.0;
  static const _thumbHeight = 56.0;

  bool _dragging = false;

  void _jumpFromOffset(double dy, double height) {
    final usable = (height - _thumbHeight).clamp(1.0, double.infinity);
    final fraction = ((dy - _thumbHeight / 2) / usable).clamp(0.0, 1.0);
    widget.onJump((fraction * (widget.count - 1)).round());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final fraction = widget.count <= 1 ? 0.0 : widget.firstVisible / (widget.count - 1);
        final top = fraction.clamp(0.0, 1.0) * (height - _thumbHeight);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) {
            setState(() => _dragging = true);
            _jumpFromOffset(d.localPosition.dy, height);
          },
          onVerticalDragUpdate: (d) => _jumpFromOffset(d.localPosition.dy, height),
          onVerticalDragEnd: (_) => setState(() => _dragging = false),
          onVerticalDragCancel: () => setState(() => _dragging = false),
          // Chạm một chỗ bất kỳ trên thanh cũng nhảy tới đó.
          onTapDown: (d) => _jumpFromOffset(d.localPosition.dy, height),
          child: SizedBox(
            width: _width,
            height: height,
            child: Stack(
              children: [
                Positioned(
                  top: top,
                  left: _dragging ? 4 : 12,
                  right: 6,
                  height: _thumbHeight,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    decoration: BoxDecoration(
                      color: _dragging
                          ? scheme.primary
                          : scheme.primary.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: _dragging
                        ? Center(
                            child: Text(
                              '${widget.firstVisible + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: scheme.onPrimary,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

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
