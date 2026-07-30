/// Màn hình xuất sách nói ra file MP3.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'fast_scrollbar.dart';
import 'package:path/path.dart' as p;

import '../core/chunker.dart';
import '../models/book.dart';
import '../models/settings.dart';
import '../services/audio_encoder.dart';
import '../models/export_job.dart';
import '../services/storage.dart';
import 'app_scope.dart';
import 'theme.dart';

class ExportPage extends StatefulWidget {
  const ExportPage({super.key});

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> {
  int? _fromChapter;
  int? _toChapter;
  String? _outputDir;
  bool _starting = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final book = state.currentBook;
    if (book == null) return const SizedBox.shrink();

    final chapters = book.chapters;
    final from = chapters.firstWhere((c) => c.index == _fromChapter, orElse: () => chapters.first);
    final to = chapters.firstWhere(
      (c) => c.index == _toChapter,
      orElse: () => chapters.last,
    );
    final effectiveTo = to.index < from.index ? from : to;

    final selected = chapters.where((c) => c.index >= from.index && c.index <= effectiveTo.index).toList();
    final chars = selected.fold<int>(0, (sum, c) => sum + c.charCount);
    final seconds = estimateSeconds(chars, rate: state.settings.speed);
    final settings = state.settings;

    final partCount = switch (settings.splitMode) {
      SplitMode.chapter => selected.length,
      SplitMode.single => 1,
      SplitMode.duration => (seconds / (settings.partMinutes * 60)).ceil().clamp(1, 9999),
    };
    // MP3 64 kbps so với WAV 22 kHz 16-bit — chênh nhau gần năm lần, phải nói
    // trước để người dùng khỏi bất ngờ khi xuất cả cuốn sách.
    final isWav = state.tts.engine(settings.engineId).audioFormat == 'wav';
    // Máy nào không nén được thì mọi lựa chọn đều ra WAV, nói thật ngay ở đây.
    final dinhDang = (isWav && encoderAvailable) ? settings.exportFormat : ExportFormat.wav;
    // kbps thật của từng mức: WAV 48 kHz 16-bit mono là 768, Opus/MP3 theo bitrate.
    final kbps = switch (dinhDang) {
      ExportFormat.wav => 768.0,
      ExportFormat.mp3_128 => 128.0,
      _ => dinhDang.bitrate / 1000.0,
    };
    final megabytes = seconds * kbps / 8 / 1024;

    final jobs = state.jobs.where((j) => j.bookId == book.id).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 26),
      children: [
        Text('Xuất ra file âm thanh', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '${book.title} · ${chapters.length} chương · ~${formatTime(book.estimatedDuration.inSeconds.toDouble())}',
          style: TextStyle(color: Theme.of(context).hintColor, fontSize: 13),
        ),
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    _field(
                      'Cách chia file',
                      DropdownButton<SplitMode>(
                        value: settings.splitMode,
                        isExpanded: true,
                        underline: const SizedBox.shrink(),
                        items: [
                          for (final mode in SplitMode.values)
                            DropdownMenuItem(value: mode, child: Text(mode.label)),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          settings.splitMode = value;
                          AppScope.read(context).saveSettings();
                        },
                      ),
                    ),
                    if (settings.splitMode == SplitMode.duration)
                      _field(
                        'Độ dài mỗi file',
                        DropdownButton<int>(
                          value: const [5, 10, 15, 20, 30, 45, 60, 90, 120].contains(settings.partMinutes)
                              ? settings.partMinutes
                              : 30,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final m in [5, 10, 15, 20, 30, 45, 60, 90, 120])
                              DropdownMenuItem(value: m, child: Text('$m phút')),
                          ],
                          onChanged: (value) {
                            if (value == null) return;
                            settings.partMinutes = value;
                            AppScope.read(context).saveSettings();
                          },
                        ),
                      ),
                    if (isWav)
                      _field(
                        'Định dạng file',
                        DropdownButton<ExportFormat>(
                          value: dinhDang,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          onChanged: encoderAvailable
                              ? (value) async {
                                  if (value == null) return;
                                  settings.exportFormat = value;
                                  await AppScope.read(context).saveSettings();
                                }
                              : null,
                          items: [
                            for (final f in ExportFormat.values)
                              DropdownMenuItem(
                                value: f,
                                child: Text(f.label, overflow: TextOverflow.ellipsis),
                              ),
                          ],
                        ),
                      ),
                    _field(
                      'Từ chương',
                      _ChonChuong(
                        chapters: chapters,
                        selected: from.index,
                        onPicked: (value) => setState(() => _fromChapter = value),
                      ),
                    ),
                    _field(
                      'Đến hết chương',
                      _ChonChuong(
                        chapters: chapters,
                        selected: effectiveTo.index,
                        onPicked: (value) => setState(() => _toChapter = value),
                      ),
                    ),
                  ],
                ),
                if (settings.splitMode == SplitMode.duration)
                  CheckboxListTile(
                    value: settings.alignChapter,
                    onChanged: (value) {
                      settings.alignChapter = value ?? true;
                      AppScope.read(context).saveSettings();
                    },
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Ưu tiên kết thúc file ở cuối chương', style: TextStyle(fontSize: 14)),
                    subtitle: Text('Tránh cắt ngang giữa chương khi đã gần đủ độ dài',
                        style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
                  ),
                const SizedBox(height: 10),
                _FolderRow(
                  book: book,
                  path: _outputDir,
                  onChanged: (value) => setState(() => _outputDir = value),
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(13),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Sẽ xuất ${selected.length} chương — tổng khoảng ${formatTime(seconds)}, '
                    'chia thành $partCount file ${dinhDang.extension.toUpperCase()}, '
                    '~${megabytes < 10 ? megabytes.toStringAsFixed(1) : megabytes.round()} MB.\n'
                    'Giọng: ${state.voices.where((v) => v.id == settings.voiceId).map((v) => v.name).firstOrNull ?? settings.voiceId}'
                    ' · tốc độ ${settings.speed}× (được ghi thẳng vào file)'
                    '${isWav ? '\nWAV không nén nên nặng nhất — chọn Opus thì nhỏ hơn khoảng 30 lần mà nghe gần như không khác. Đổi ở mục '
                        'Định dạng file phía trên.' : ''}',
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _starting || !state.engineStatus.ready
                          ? null
                          : () => _start(book, from, effectiveTo),
                      icon: _starting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      label: Text(_starting ? 'Đang chuẩn bị…' : 'Bắt đầu xuất'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _starting
                            ? 'Đang nạp nội dung sách — sách dày mất vài giây.'
                            : 'Có thể tạm dừng và chạy tiếp sau, kể cả sau khi tắt ứng dụng.',
                        style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text('Các lần xuất', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 10),
        if (jobs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 26),
            child: Center(child: Text('Chưa có lần xuất nào', style: TextStyle(color: Theme.of(context).hintColor))),
          )
        else
          for (final job in jobs)
            Padding(padding: const EdgeInsets.only(bottom: 12), child: _JobCard(job: job)),
      ],
    );
  }

  Widget _field(String label, Widget child) {
    return SizedBox(
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 12.5, color: Theme.of(context).hintColor)),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );
  }

  Future<void> _start(Book book, Chapter from, Chapter to) async {
    final state = AppScope.read(context);
    setState(() => _starting = true);
    try {
      final dir = _outputDir ?? await state.defaultExportDir(book);
      await state.startExport(
        book: book,
        outputDir: dir,
        fromChunk: from.firstChunk,
        toChunk: to.lastChunk,
      );
      if (mounted) {
        setState(() => _outputDir = dir);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đã bắt đầu xuất file — có thể tiếp tục nghe trong lúc chờ')),
        );
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Lỗi: $err')));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }
}

class _FolderRow extends StatefulWidget {
  const _FolderRow({required this.book, required this.path, required this.onChanged});
  final Book book;
  final String? path;
  final ValueChanged<String> onChanged;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  String? _resolved;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    if (widget.path != null) return;
    final dir = await AppScope.read(context).defaultExportDir(widget.book);
    if (mounted) setState(() => _resolved = dir);
  }

  @override
  Widget build(BuildContext context) {
    // Trên Android, đường dẫn thật là vùng riêng của app và người dùng không cần
    // biết tới nó — file hoàn chỉnh nằm ở Music/Sách lười, chỗ mà ứng dụng Files
    // và các app nghe nhạc đều thấy. Hiện chỗ đó cho đúng thực tế.
    final path = Platform.isAndroid
        ? 'Music/Sách lười/${sanitizeFileName(widget.book.title)}  (thư viện nhạc của máy)'
        : (widget.path ?? _resolved ?? '…');
    return Row(
      children: [
        Icon(Icons.folder_outlined, size: 19, color: Theme.of(context).hintColor),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            path,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 13),
          ),
        ),
        // Android không cho chọn thư mục: mọi đường ghi thẳng vào bộ nhớ chung
        // đều bị chặn, nên file luôn đi vào Music/Sách lười qua MediaStore.
        if (!Platform.isAndroid)
          TextButton(
            onPressed: () async {
              final chosen =
                  await FilePicker.platform.getDirectoryPath(dialogTitle: 'Chọn nơi lưu file');
              if (chosen != null) widget.onChanged(chosen);
            },
            child: const Text('Đổi thư mục'),
          ),
      ],
    );
  }
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job});
  final ExportJob job;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final hint = Theme.of(context).hintColor;
    final scheme = Theme.of(context).colorScheme;

    final preparing = state.preparingJobs.contains(job.id);
    final stopping = state.exports.isStopping(job.id);
    final running = job.status == JobStatus.running;
    final remaining = running ? state.exports.remainingFor(job) : null;

    final badgeColor = switch (job.status) {
      JobStatus.done => Colors.green,
      JobStatus.error || JobStatus.canceled => scheme.error,
      JobStatus.running || JobStatus.queued => scheme.primary,
      JobStatus.paused => Colors.blueGrey,
    };

    final modeText = switch (job.splitMode) {
      SplitMode.chapter => 'mỗi chương một file',
      SplitMode.single => 'một file duy nhất',
      SplitMode.duration => '${job.partMinutes} phút mỗi file',
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(job.bookTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        '${job.voiceName} · $modeText · ${job.speed}×',
                        style: TextStyle(fontSize: 12.5, color: hint),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: badgeColor),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Vòng quay nhỏ báo việc vẫn đang chạy: một đoạn có thể mất
                      // vài giây nên thanh tiến trình đứng yên trông như bị treo.
                      if (running || preparing) ...[
                        SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(strokeWidth: 1.8, color: badgeColor),
                        ),
                        const SizedBox(width: 7),
                      ],
                      Text(
                        preparing
                            ? 'Đang chuẩn bị'
                            : stopping
                                ? 'Đang dừng'
                                : job.status.label,
                        style: TextStyle(fontSize: 12, color: badgeColor),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 11),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: preparing && job.doneChunks == 0 ? null : job.progress,
                minHeight: 5,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${job.doneChunks}/${job.totalChunks} đoạn (${(job.progress * 100).round()}%) · '
              'đã tạo ${formatTime(job.secondsDone)} âm thanh'
              '${remaining == null ? '' : ' · còn khoảng ${formatTime(remaining.inSeconds.toDouble())}'}',
              style: TextStyle(fontSize: 12.5, color: hint),
            ),
            if (job.error != null) ...[
              const SizedBox(height: 5),
              Text(job.error!, style: TextStyle(fontSize: 12.5, color: scheme.error)),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                if (job.isActive)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9)),
                    onPressed: stopping ? null : () => state.pauseExport(job),
                    icon: const Icon(Icons.pause, size: 18),
                    label: Text(stopping ? 'Đang dừng…' : 'Tạm dừng'),
                  ),
                if (job.canResume)
                  FilledButton.icon(
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9)),
                    onPressed: preparing ? null : () => state.resumeExport(job),
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: Text(preparing ? 'Đang chuẩn bị…' : 'Chạy tiếp'),
                  ),
                if (job.parts.isNotEmpty)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9)),
                    onPressed: () => _openFolder(job.outputDir),
                    icon: const Icon(Icons.folder_open, size: 18),
                    label: const Text('Mở thư mục'),
                  ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9)),
                  onPressed: () async {
                    await state.exports.deleteJob(job);
                    await state.reloadJobs();
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Xoá'),
                ),
              ],
            ),
            if (job.parts.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final part in job.parts)
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Row(
                    children: [
                      Icon(Icons.audio_file_outlined, size: 16, color: hint),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(part.fileName,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                      ),
                      Text('${formatTime(part.seconds)} · ${formatBytes(part.bytes)}',
                          style: TextStyle(fontSize: 12, color: hint)),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  void _openFolder(String dir) {
    if (!Directory(dir).existsSync()) return;
    if (Platform.isWindows) {
      Process.run('explorer', [p.normalize(dir)]);
    } else if (Platform.isMacOS) {
      Process.run('open', [dir]);
    } else if (Platform.isLinux) {
      Process.run('xdg-open', [dir]);
    }
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Chọn một chương trong danh sách dài.
///
/// Thay cho DropdownButton: với 2.466 chương thì menu buông xuống dựng cả 2.466
/// ô một lượt, cuộn nặng và thanh cuộn thì bé xíu không kéo được. Bảng mở từ
/// dưới lên vừa dựng ô theo nhu cầu, vừa có thanh cuộn kéo tay và ô tìm theo tên.
class _ChonChuong extends StatelessWidget {
  const _ChonChuong({required this.chapters, required this.selected, required this.onPicked});

  final List<Chapter> chapters;
  final int selected;
  final ValueChanged<int> onPicked;

  @override
  Widget build(BuildContext context) {
    final at = chapters.indexWhere((c) => c.index == selected);
    final nhan = at < 0 ? 'Chọn chương' : '${at + 1}. ${chapters[at].title}';

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () async {
        final chon = await showModalBottomSheet<int>(
          context: context,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (_) => FractionallySizedBox(
            heightFactor: 0.88,
            child: _BangChonChuong(chapters: chapters, selected: selected),
          ),
        );
        if (chon != null) onPicked(chon);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Expanded(child: Text(nhan, maxLines: 1, overflow: TextOverflow.ellipsis)),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

class _BangChonChuong extends StatefulWidget {
  const _BangChonChuong({required this.chapters, required this.selected});
  final List<Chapter> chapters;
  final int selected;

  @override
  State<_BangChonChuong> createState() => _BangChonChuongState();
}

class _BangChonChuongState extends State<_BangChonChuong> {
  final _controller = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  int _firstVisible = 0;
  String _tim = '';

  bool get _dungThanhKeo => Platform.isAndroid || Platform.isIOS;

  List<Chapter> get _hien {
    if (_tim.isEmpty) return widget.chapters;
    final k = _tim.toLowerCase();
    return widget.chapters.where((c) => c.title.toLowerCase().contains(k)).toList();
  }

  @override
  void initState() {
    super.initState();
    _firstVisible = _viTriChon();
    _positions.itemPositions.addListener(_theoDoi);
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_theoDoi);
    super.dispose();
  }

  int _viTriChon() {
    final at = widget.chapters.indexWhere((c) => c.index == widget.selected);
    return at < 0 ? 0 : at;
  }

  void _theoDoi() {
    final v = _positions.itemPositions.value;
    if (v.isEmpty) return;
    final dau = v.where((p) => p.itemTrailingEdge > 0).fold<int>(
        v.first.index, (nho, p) => p.index < nho ? p.index : nho);
    if (dau != _firstVisible && mounted) setState(() => _firstVisible = dau);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ds = _hien;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
          child: TextField(
            autofocus: false,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Tìm trong ${widget.chapters.length} chương',
              border: const OutlineInputBorder(),
            ),
            onChanged: (v) => setState(() => _tim = v),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ds.isEmpty
              ? const Center(child: Text('Không có chương nào khớp'))
              : Stack(
                  children: [
                    ScrollablePositionedList.builder(
                      itemScrollController: _controller,
                      itemPositionsListener: _positions,
                      // Ô tìm đổi thì danh sách ngắn lại, không nhảy nữa.
                      initialScrollIndex: _tim.isEmpty ? _viTriChon() : 0,
                      initialAlignment: 0.2,
                      padding: EdgeInsets.only(
                          top: 6, bottom: 6, left: 8, right: _dungThanhKeo ? 42 : 8),
                      itemCount: ds.length,
                      itemBuilder: (context, i) {
                        final c = ds[i];
                        final chon = c.index == widget.selected;
                        final so = widget.chapters.indexOf(c) + 1;
                        return InkWell(
                          borderRadius: BorderRadius.circular(9),
                          onTap: () => Navigator.of(context).pop(c.index),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
                            decoration: BoxDecoration(
                              color: chon ? scheme.primaryContainer.withValues(alpha: 0.55) : null,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text(
                              '$so. ${c.title}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                color: chon ? scheme.primary : null,
                                fontWeight: chon ? FontWeight.w600 : null,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    if (_dungThanhKeo && ds.length > 12)
                      Positioned(
                        top: 4,
                        bottom: 4,
                        right: 0,
                        child: FastScrollBar(
                          count: ds.length,
                          firstVisible: _firstVisible,
                          labelBuilder: (i) => i < ds.length ? ds[i].title : '',
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
