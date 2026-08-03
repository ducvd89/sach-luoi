/// Màn hình xuất sách nói ra file MP3.
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'fast_scrollbar.dart';
import 'package:path/path.dart' as p;

import '../core/chunker.dart';
import '../models/book.dart';
import '../models/settings.dart';
import '../services/audio_encoder.dart';
import '../models/export_job.dart';
import '../services/storage.dart';
import '../services/thu_muc_xuat.dart';
import 'app_scope.dart';
import 'chon_giong.dart';
import 'kinh.dart';
import 'home_shell.dart';
import 'nut_sac.dart';
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

  /// Sách đang chọn để xuất, nếu khác cuốn đang nghe.
  ///
  /// Giữ riêng ở đây chứ không đụng tới cuốn đang nghe của cả ứng dụng: chọn
  /// sách để xuất mà làm gián đoạn cái đang nghe thì phiền. Job cất bookId nên
  /// việc xuất chạy độc lập, không cần cuốn này phải là cuốn "hiện tại".
  ///
  /// Giữ id chứ không giữ đối tượng Book — danh sách sách được nạp lại sau mỗi
  /// lần thêm/dọn sách, ôm đối tượng cũ là trỏ vào bản đã hết hạn.
  String? _bookId;

  /// Trình phát thử các file đã xuất, dùng chung cho mọi lần xuất trong trang
  /// này — tách khỏi PlayerController của cả cuốn sách vì đây chỉ nghe thử
  /// một file lẻ, không dính gì tới tiến trình đang đọc.
  final _xuatPlayer = _XuatPlayer();

  @override
  void dispose() {
    _xuatPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final books = state.books;
    if (books.isEmpty) {
      return _TrongRong(
        message: 'Thư viện chưa có sách nào để xuất',
        nhan: 'VỀ THƯ VIỆN',
      );
    }
    final book = books.firstWhere(
      (b) => b.id == _bookId,
      orElse: () => state.currentBook ?? books.first,
    );

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
        const SizedBox(height: 10),
        _ChonSach(
          books: books,
          dangChon: book,
          onChon: (id) => setState(() {
            _bookId = id;
            // Chỉ số chương là của riêng từng cuốn, giữ lại là chọn nhầm khoảng.
            _fromChapter = null;
            _toChapter = null;
          }),
        ),
        const SizedBox(height: 6),
        Text(
          '${chapters.length} chương · ~${formatTime(book.estimatedDuration.inSeconds.toDouble())}',
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
                const SizedBox(height: 4),
                BangChonGiong(
                  voices: state.voices,
                  voiceId: settings.voiceXuat,
                  nguCanh: settings.nguCanhXuat,
                  // Khoá khi có job đang chạy: đổi giữa chừng thì nửa file một
                  // giọng. Tạm dừng, đổi, chạy tiếp là phần còn lại theo mức mới.
                  khoaGiong: state.runningJob != null
                      ? 'Tạm dừng việc xuất file rồi mới đổi được'
                      : null,
                  // Chỉ VieNeu nối được ngữ cảnh giữa các đoạn.
                  khoaNguCanh: settings.engineId != 'vieneu'
                      ? 'Chỉ VieNeu hỗ trợ nối ngữ cảnh'
                      : (state.runningJob != null
                          ? 'Tạm dừng việc xuất file rồi mới đổi được'
                          : null),
                  onVoice: (v) {
                    settings.voiceXuat = v;
                    AppScope.read(context).saveSettings();
                  },
                  onNguCanh: (v) {
                    settings.nguCanhXuat = v;
                    AppScope.read(context).saveSettings();
                  },
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
                    'Giọng: ${state.voices.where((v) => v.id == settings.voiceXuat).map((v) => v.name).firstOrNull ?? settings.voiceXuat}'
                    ' · tốc độ ${settings.speed}× (được ghi thẳng vào file)'
                    '${isWav ? '\nWAV không nén nên nặng nhất — chọn Opus thì nhỏ hơn khoảng 30 lần mà nghe gần như không khác. Đổi ở mục '
                        'Định dạng file phía trên.' : ''}',
                    style: const TextStyle(fontSize: 13, height: 1.5),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    NutSac(
                      nhan: _starting ? 'ĐANG CHUẨN BỊ…' : 'BẮT ĐẦU XUẤT',
                      hinh: Icons.play_arrow_rounded,
                      dangChay: _starting,
                      onNhan: state.engineStatus.ready
                          ? () => _start(book, from, effectiveTo)
                          : null,
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
          ListenableBuilder(
            listenable: _xuatPlayer,
            builder: (context, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final job in jobs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _JobCard(job: job, player: _xuatPlayer),
                  ),
              ],
            ),
          ),
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

  /// Android: tên thư mục người dùng đã chọn, null nghĩa là đang dùng mặc định.
  String? _tenThuMuc;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    if (Platform.isAndroid) {
      final cay = AppScope.read(context).settings.exportTreeUri;
      if (cay.isEmpty) return;
      // Quyền có thể đã bị rút trong Cài đặt của máy hoặc mất khi cài lại app —
      // hiện tên một thư mục không ghi được nữa thì còn tệ hơn không hiện gì.
      final ten = await conQuyenThuMuc(cay) ? await tenThuMuc(cay) : null;
      if (mounted) setState(() => _tenThuMuc = ten);
      return;
    }
    if (widget.path != null) return;
    final dir = await AppScope.read(context).defaultExportDir(widget.book);
    if (mounted) setState(() => _resolved = dir);
  }

  /// Android: mở trình chọn thư mục của hệ thống, nhớ lại lựa chọn.
  ///
  /// Không dùng FilePicker.getDirectoryPath ở đây: trên Android nó cũng mở
  /// Storage Access Framework nhưng trả về một đường dẫn suy ra từ tree URI, ghi
  /// thẳng vào đó là EACCES. Phải giữ nguyên tree URI và ghi qua SAF.
  Future<void> _chonThuMucAndroid() async {
    final state = AppScope.read(context);
    try {
      final cay = await chonThuMuc();
      if (cay == null || !mounted) return;
      state.settings.exportTreeUri = cay;
      await state.saveSettings();
      final ten = await tenThuMuc(cay);
      if (mounted) setState(() => _tenThuMuc = ten);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không chọn được thư mục: $err')),
        );
      }
    }
  }

  /// Bỏ thư mục đã chọn, quay về thư viện nhạc của máy.
  Future<void> _veMacDinh() async {
    final state = AppScope.read(context);
    state.settings.exportTreeUri = '';
    await state.saveSettings();
    if (mounted) setState(() => _tenThuMuc = null);
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid) return _hangAndroid(context);

    final path = widget.path ?? _resolved ?? '…';
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

  /// Android: đường dẫn thật là vùng riêng của app và người dùng không cần biết
  /// tới nó. Chỉ hiện chỗ file hoàn chỉnh sẽ nằm.
  Widget _hangAndroid(BuildContext context) {
    final sach = sanitizeFileName(widget.book.title);
    final daChon = _tenThuMuc != null;
    final noiLuu = daChon
        ? '$_tenThuMuc/$sach'
        : 'Music/Sách lười/$sach  (thư viện nhạc của máy)';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.folder_outlined, size: 19, color: Theme.of(context).hintColor),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                noiLuu,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13),
              ),
            ),
            TextButton(
              onPressed: _chonThuMucAndroid,
              child: Text(daChon ? 'Đổi thư mục' : 'Chọn thư mục'),
            ),
          ],
        ),
        if (daChon)
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: TextButton(
              onPressed: _veMacDinh,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 30),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Dùng lại thư viện nhạc của máy', style: TextStyle(fontSize: 12.5)),
            ),
          ),
      ],
    );
  }
}

/// Hỏi lại trước khi xoá — dùng chung cho xoá cả lần xuất lẫn xoá riêng một
/// file, đều là việc không lấy lại được.
Future<bool> xacNhanXoa(BuildContext context, {required String tieuDe, required String noiDung}) async {
  final dong = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tieuDe),
      content: Text(noiDung),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Huỷ')),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error),
          child: const Text('Xoá'),
        ),
      ],
    ),
  );
  return dong ?? false;
}

class _JobCard extends StatelessWidget {
  const _JobCard({required this.job, required this.player});
  final ExportJob job;
  final _XuatPlayer player;

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
            // Đang chuẩn bị, hoặc đang nén mà chưa có % (máy tính — bộ mã hoá
            // Rust gọi đồng bộ, không báo giữa chừng) thì để nguyên thanh chạy
            // vô định của Material, khỏi trông như đứng hình trong lúc chờ.
            // Android báo được % thật lúc đang nén (xem audio_encoder.dart) nên
            // vẫn dùng thanh kính, chỉ đổi sang bám theo nenPhan.
            (preparing && job.doneChunks == 0) || (job.dangNen && job.nenPhan == null)
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: const LinearProgressIndicator(minHeight: 6),
                  )
                : ThanhKinh(phan: job.dangNen ? job.nenPhan! : job.progress, sac: SacNut.chinh, cao: 8),
            const SizedBox(height: 6),
            Text(
              job.dangNen
                  ? 'Đang nén phần vừa đọc sang ${ExportFormat.fromId(job.formatId).extension.toUpperCase()}'
                      '${job.nenPhan == null ? '…' : ' (${(job.nenPhan! * 100).round()}%)'}'
                  : '${job.doneChunks}/${job.totalChunks} đoạn (${(job.progress * 100).round()}%) · '
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
                  NutSac(
                    nho: true,
                    vienRong: true,
                    sac: SacNut.phu,
                    nhan: stopping ? 'Đang dừng…' : 'Tạm dừng',
                    hinh: Icons.pause_rounded,
                    onNhan: stopping ? null : () => state.pauseExport(job),
                  ),
                if (job.canResume)
                  NutSac(
                    nho: true,
                    nhan: preparing ? 'Đang chuẩn bị…' : 'Chạy tiếp',
                    hinh: Icons.play_arrow_rounded,
                    dangChay: preparing,
                    onNhan: () => state.resumeExport(job),
                  ),
                if (job.parts.isNotEmpty)
                  NutSac(
                    nho: true,
                    vienRong: true,
                    sac: SacNut.phu,
                    nhan: 'Mở thư mục',
                    hinh: Icons.folder_open_rounded,
                    onNhan: () => _openFolder(job.outputDir),
                  ),
                NutSac(
                  nho: true,
                  vienRong: true,
                  sac: SacNut.nguyHiem,
                  nhan: 'Xoá',
                  hinh: Icons.delete_outline_rounded,
                  onNhan: () async {
                    final dong = await xacNhanXoa(
                      context,
                      tieuDe: 'Xoá lần xuất này?',
                      noiDung: 'Bỏ cả danh sách ${job.parts.length} file của lần xuất này khỏi ứng dụng.',
                    );
                    if (!dong) return;
                    await player.stopIfCurrent(job);
                    await state.exports.deleteJob(job);
                    await state.reloadJobs();
                  },
                ),
              ],
            ),
            if (job.parts.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final part in job.parts) _PartRow(job: job, part: part, player: player),
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

/// Một file trong danh sách "Các lần xuất", nghe thử được ngay tại chỗ.
class _PartRow extends StatelessWidget {
  const _PartRow({required this.job, required this.part, required this.player});
  final ExportJob job;
  final ExportPart part;
  final _XuatPlayer player;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final scheme = Theme.of(context).colorScheme;
    final state = AppScope.of(context);
    final path = state.exports.playablePath(job, part);
    final active = player.isCurrent(job, part);
    final loading = active && player.isLoading;
    final playing = active && player.isPlaying;

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 22,
                height: 22,
                child: loading
                    ? Padding(
                        padding: const EdgeInsets.all(3),
                        child: CircularProgressIndicator(strokeWidth: 2, color: hint),
                      )
                    : IconButton(
                        padding: EdgeInsets.zero,
                        iconSize: 18,
                        color: active ? scheme.primary : hint,
                        tooltip: path == null
                            ? 'Không mở lại được trong ứng dụng'
                            : playing
                                ? 'Tạm dừng'
                                : 'Nghe thử',
                        icon: Icon(playing ? Icons.pause_circle_filled : Icons.play_circle_fill_rounded),
                        onPressed: path == null ? null : () => player.toggle(job, part, path),
                      ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(part.fileName,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 8),
              Text(
                active && player.duration > Duration.zero
                    ? '${formatTime(player.position.inMilliseconds / 1000)} / '
                        '${formatTime(player.duration.inMilliseconds / 1000)}'
                    : '${formatTime(part.seconds)} · ${formatBytes(part.bytes)}',
                style: TextStyle(fontSize: 12, color: hint),
              ),
              IconButton(
                padding: EdgeInsets.zero,
                iconSize: 17,
                color: scheme.error,
                tooltip: 'Xoá file này',
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () async {
                  final dong = await xacNhanXoa(
                    context,
                    tieuDe: 'Xoá file này?',
                    noiDung: '${part.fileName}\n\nMất luôn, không lấy lại được.',
                  );
                  if (!dong) return;
                  await player.stopIfCurrent(job);
                  await state.exports.deletePart(job, part);
                  await state.reloadJobs();
                },
              ),
            ],
          ),
          if (active)
            Padding(
              padding: const EdgeInsets.only(left: 22, right: 4),
              child: Row(
                children: [
                  IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    color: hint,
                    tooltip: 'Lùi 30 giây',
                    icon: const Icon(Icons.replay_30_rounded),
                    onPressed: () => player.seekRelative(const Duration(seconds: -30)),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 10),
                      ),
                      // Mỗi file xuất chỉ dài tối đa vài chục phút — khác thanh
                      // tiến trình cả cuốn sách, tua ở đây không lo nhảy vọt đi xa.
                      child: Slider(
                        value: player.duration.inMilliseconds > 0
                            ? (player.position.inMilliseconds / player.duration.inMilliseconds)
                                .clamp(0.0, 1.0)
                            : 0.0,
                        onChanged: (v) => player.seekFraction(v),
                      ),
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    color: hint,
                    tooltip: 'Tiến 30 giây',
                    icon: const Icon(Icons.forward_30_rounded),
                    onPressed: () => player.seekRelative(const Duration(seconds: 30)),
                  ),
                ],
              ),
            ),
          if (active && player.error != null)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Text(player.error!, style: TextStyle(fontSize: 11.5, color: scheme.error)),
            ),
        ],
      ),
    );
  }
}

/// Trình phát thử các file đã xuất — một Player dùng chung cho mọi phần của
/// mọi lần xuất trong trang này, mở lại (thay vì tạo mới) mỗi lần bấm nghe.
class _XuatPlayer extends ChangeNotifier {
  final Player _player = Player();
  final List<StreamSubscription<dynamic>> _subs = [];

  /// `<jobId>#<partIndex>` của phần đang mở, null nếu chưa mở gì.
  String? _key;

  bool isLoading = false;
  String? error;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;

  _XuatPlayer() {
    _subs.addAll([
      _player.stream.position.listen((v) {
        position = v;
        notifyListeners();
      }),
      _player.stream.duration.listen((v) {
        duration = v;
        notifyListeners();
      }),
      _player.stream.playing.listen((_) => notifyListeners()),
      _player.stream.completed.listen((done) {
        if (!done) return;
        position = Duration.zero;
        notifyListeners();
      }),
    ]);
  }

  bool get isPlaying => _player.state.playing;

  String _keyOf(ExportJob job, ExportPart part) => '${job.id}#${part.index}';

  bool isCurrent(ExportJob job, ExportPart part) => _key == _keyOf(job, part);

  Future<void> toggle(ExportJob job, ExportPart part, String path) async {
    final key = _keyOf(job, part);
    if (_key == key) {
      if (isPlaying) {
        await _player.pause();
      } else {
        await _player.play();
      }
      return;
    }

    _key = key;
    isLoading = true;
    error = null;
    position = Duration.zero;
    duration = Duration.zero;
    notifyListeners();
    try {
      await _player.open(Media(path));
    } catch (err) {
      error = err.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> seekFraction(double fraction) async {
    if (duration <= Duration.zero) return;
    await _player.seek(Duration(milliseconds: (duration.inMilliseconds * fraction).round()));
  }

  Future<void> seekRelative(Duration delta) async {
    var target = position + delta;
    if (target.isNegative) target = Duration.zero;
    if (duration > Duration.zero && target > duration) target = duration;
    await _player.seek(target);
  }

  /// Dừng nếu đang phát một phần thuộc [job] — gọi trước khi xoá job đó, kẻo
  /// giao diện biến mất mà tiếng vẫn còn phát dở.
  Future<void> stopIfCurrent(ExportJob job) async {
    final key = _key;
    if (key == null || !key.startsWith('${job.id}#')) return;
    await _player.stop();
    _key = null;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    unawaited(_player.dispose());
    super.dispose();
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


/// Ô chọn sách để xuất, ngay trong màn hình xuất file.
///
/// Trước đây phải sang thư viện mở sách rồi mới quay lại đây được. Sách nào cũng
/// xuất được từ chỗ này, và không làm gián đoạn cuốn đang nghe.
class _ChonSach extends StatelessWidget {
  const _ChonSach({required this.books, required this.dangChon, required this.onChon});

  final List<Book> books;
  final Book dangChon;
  final ValueChanged<String> onChon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.menu_book_outlined, size: 19, color: Theme.of(context).hintColor),
          const SizedBox(width: 10),
          Expanded(
            child: DropdownButton<String>(
              value: dangChon.id,
              isExpanded: true,
              underline: const SizedBox.shrink(),
              borderRadius: BorderRadius.circular(12),
              items: [
                for (final b in books)
                  DropdownMenuItem(
                    value: b.id,
                    child: Text(
                      b.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14.5),
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null && value != dangChon.id) onChon(value);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Màn hình trống khi chưa có gì để xuất.
class _TrongRong extends StatelessWidget {
  const _TrongRong({required this.message, required this.nhan});
  final String message;
  final String nhan;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.menu_book_outlined, size: 44, color: Theme.of(context).disabledColor),
          const SizedBox(height: 12),
          Text(message, style: TextStyle(color: Theme.of(context).hintColor)),
          const SizedBox(height: 16),
          NutSac(
            nhan: nhan,
            hinh: Icons.library_books_rounded,
            sac: SacNut.phu,
            vienRong: true,
            onNhan: () => HomeShellState.of(context)?.goTo(0),
          ),
        ],
      ),
    );
  }
}
