/// Màn hình nghe: danh sách chương, nội dung đang đọc và thanh điều khiển.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/services.dart';

import '../models/book.dart';
import 'app_scope.dart';
import 'fast_scrollbar.dart';
import 'reading_pane.dart';
import 'theme.dart';

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key});

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  double? _dragFraction;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final player = state.player;
    final book = state.currentBook;
    if (book == null) return const SizedBox.shrink();

    return AnimatedBuilder(
      animation: player,
      builder: (context, _) {
        final chapter = player.currentChapter;
        final wide = MediaQuery.sizeOf(context).width >= 1000;

        final reading = ReadingPane(
          // Đổi chương thì dựng lại khung để nó nhảy đúng đoạn đầu chương mới.
          key: ValueKey(chapter?.index),
          chapter: chapter,
          currentIndex: player.index,
          chunks: player.chunks,
          onTapChunk: (i) => player.playChunk(i, autoplay: player.isPlaying),
        );

        return Focus(
          autofocus: true,
          onKeyEvent: (node, event) => _handleKey(event, player),
          child: Column(
            children: [
              // Màn hình hẹp không đủ chỗ cho danh sách chương cố định, nên nó
              // nằm sau một nút mở lên từ dưới — không có thì trên điện thoại
              // chẳng có cách nào nhảy tới chương mình muốn.
              if (!wide) _ChapterBar(book: book, chapter: chapter),
              Expanded(
                child: wide
                    ? Row(
                        children: [
                          SizedBox(width: 280, child: _ChapterList(book: book, currentChapter: chapter)),
                          const VerticalDivider(width: 1),
                          Expanded(child: reading),
                        ],
                      )
                    : reading,
              ),
              const Divider(height: 1),
              _PlayerBar(
                dragFraction: _dragFraction,
                onDragStart: (v) => setState(() => _dragFraction = v),
                onDragEnd: (v) {
                  setState(() => _dragFraction = null);
                  player.seekFraction(v);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  KeyEventResult _handleKey(KeyEvent event, dynamic player) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.space:
        player.togglePlay();
      case LogicalKeyboardKey.arrowRight:
        player.seekRelative(const Duration(seconds: 15));
      case LogicalKeyboardKey.arrowLeft:
        player.seekRelative(const Duration(seconds: -15));
      case LogicalKeyboardKey.arrowDown:
        player.next();
      case LogicalKeyboardKey.arrowUp:
        player.previous();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }
}

class _ChapterList extends StatefulWidget {
  const _ChapterList({required this.book, required this.currentChapter, this.onPicked});
  final Book book;
  final Chapter? currentChapter;

  /// Gọi sau khi chọn chương — bản mở từ dưới lên dùng để tự đóng lại.
  final VoidCallback? onPicked;

  @override
  State<_ChapterList> createState() => _ChapterListState();
}

class _ChapterListState extends State<_ChapterList> {
  final _controller = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  int _firstVisible = 0;

  /// Thanh cuộn kéo tay chỉ có ích khi vuốt là cách duy nhất để đi — trên máy
  /// tính đã có chuột và bánh xe.
  bool get _dungThanhKeo => Platform.isAndroid || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    // Mở ra là thấy ngay chương đang nghe. Sách 2.467 chương mà bắt đầu từ
    // chương 1 thì người dùng phải tự cuộn tìm chỗ mình đang đọc.
    _firstVisible = _viTriHienTai();
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

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final currentChapter = widget.currentChapter;
    final onPicked = widget.onPicked;
    final state = AppScope.of(context);
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
              ScrollablePositionedList.builder(
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
              return InkWell(
                borderRadius: BorderRadius.circular(9),
                onTap: () {
                  state.player.playChunk(chapter.firstChunk, autoplay: state.player.isPlaying);
                  onPicked?.call();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
                  decoration: BoxDecoration(
                    color: selected ? scheme.primaryContainer.withValues(alpha: 0.55) : null,
                    borderRadius: BorderRadius.circular(9),
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

class _PlayerBar extends StatelessWidget {
  const _PlayerBar({required this.dragFraction, required this.onDragStart, required this.onDragEnd});

  final double? dragFraction;
  final ValueChanged<double> onDragStart;
  final ValueChanged<double> onDragEnd;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final player = state.player;
    final hint = Theme.of(context).hintColor;

    final total = player.totalSeconds;
    final elapsed = player.elapsedSeconds;
    final fraction = dragFraction ?? (total > 0 ? (elapsed / total).clamp(0.0, 1.0) : 0.0);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 14),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: fraction,
              onChanged: onDragStart,
              onChangeEnd: onDragEnd,
            ),
          ),
          Row(
            children: [
              Text(formatTime(dragFraction != null ? total * dragFraction! : elapsed),
                  style: TextStyle(fontSize: 12.5, color: hint)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  player.error ??
                      'Đoạn ${player.index + 1}/${player.chunks.length}'
                          '${player.currentChapter == null ? '' : ' · ${player.currentChapter!.title}'}',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: player.error != null ? Theme.of(context).colorScheme.error : hint,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(formatTime(total), style: TextStyle(fontSize: 12.5, color: hint)),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: [
              IconButton(
                tooltip: 'Đoạn trước (↑)',
                onPressed: player.previous,
                icon: const Icon(Icons.skip_previous),
              ),
              IconButton(
                tooltip: 'Lùi 15 giây (←)',
                onPressed: () => player.seekRelative(const Duration(seconds: -15)),
                icon: const Icon(Icons.replay_10),
              ),
              SizedBox(
                width: 56,
                height: 56,
                child: player.isLoading
                    ? const Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 3))
                    : FilledButton(
                        style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                        onPressed: player.togglePlay,
                        child: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow, size: 27),
                      ),
              ),
              IconButton(
                tooltip: 'Tiến 15 giây (→)',
                onPressed: () => player.seekRelative(const Duration(seconds: 15)),
                icon: const Icon(Icons.forward_10),
              ),
              IconButton(
                tooltip: 'Đoạn sau (↓)',
                onPressed: player.next,
                icon: const Icon(Icons.skip_next),
              ),
              const SizedBox(width: 10),
              _SpeedSelector(),
              _SleepButton(),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpeedSelector extends StatelessWidget {
  static const _speeds = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return DropdownButton<double>(
      value: _speeds.contains(state.settings.speed) ? state.settings.speed : 1.0,
      underline: const SizedBox.shrink(),
      borderRadius: BorderRadius.circular(10),
      items: [
        for (final s in _speeds)
          DropdownMenuItem(value: s, child: Text('${s.toStringAsFixed(s == s.roundToDouble() ? 1 : 2)}×')),
      ],
      onChanged: (value) {
        if (value != null) AppScope.read(context).setSpeed(value);
      },
    );
  }
}

class _SleepButton extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final player = AppScope.of(context).player;
    final active = player.sleepAt != null;

    return TextButton.icon(
      icon: Icon(active ? Icons.bedtime : Icons.bedtime_outlined, size: 18),
      label: Text(active ? 'Còn ${formatTime(player.sleepAt!.difference(DateTime.now()).inSeconds.toDouble())}' : 'Hẹn giờ'),
      onPressed: () async {
        final minutes = await showDialog<int>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Hẹn giờ tắt'),
            children: [
              for (final m in [10, 20, 30, 45, 60])
                SimpleDialogOption(onPressed: () => Navigator.pop(context, m), child: Text('$m phút')),
              SimpleDialogOption(onPressed: () => Navigator.pop(context, 0), child: const Text('Tắt hẹn giờ')),
            ],
          ),
        );
        if (minutes != null) {
          player.setSleepTimer(minutes == 0 ? null : Duration(minutes: minutes));
        }
      },
    );
  }
}

/// Thanh chương cho màn hình hẹp: tên chương đang nghe và nút mở danh sách.
class _ChapterBar extends StatelessWidget {
  const _ChapterBar({required this.book, required this.chapter});
  final Book book;
  final Chapter? chapter;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hint = Theme.of(context).hintColor;
    final position = chapter == null
        ? ''
        : '${book.chapters.indexWhere((c) => c.index == chapter!.index) + 1}/${book.chapters.length}';

    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: () => _openChapters(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
          child: Row(
            children: [
              Icon(Icons.list_alt_outlined, size: 18, color: scheme.onSurfaceVariant),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      chapter?.title ?? book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
                    ),
                    if (position.isNotEmpty)
                      Text('Chương $position', style: TextStyle(fontSize: 11.5, color: hint)),
                  ],
                ),
              ),
              Icon(Icons.expand_more, size: 20, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }

  void _openChapters(BuildContext context) {
    final state = AppScope.read(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => AppScope(
        state: state,
        child: FractionallySizedBox(
          heightFactor: 0.85,
          // Chọn chương xong thì đóng luôn, khỏi phải bấm thêm lần nữa.
          child: _ChapterList(
            book: book,
            currentChapter: chapter,
            onPicked: () => Navigator.of(sheetContext).pop(),
          ),
        ),
      ),
    );
  }
}
