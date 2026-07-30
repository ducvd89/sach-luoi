/// Xuất sách nói ra file MP3.
///
/// Điểm quan trọng: công việc có thể dừng và chạy tiếp bất cứ lúc nào, kể cả
/// sau khi tắt ứng dụng. Trạng thái nằm trong job.json, phần âm thanh đang ghi
/// dở nằm trong file .part, còn âm thanh từng đoạn nằm trong cache — nên chạy
/// tiếp gần như không mất công đã làm.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../core/mp3.dart';
import '../core/wav.dart';
import '../models/book.dart';
import '../models/export_job.dart';
import '../models/settings.dart';
import 'storage.dart';
import 'tts/tts_manager.dart';

/// Số đoạn tổng hợp trước để không phải chờ mạng/GPU giữa chừng.
/// Số đoạn tổng hợp trước trong lúc đang ghi đoạn hiện tại.
///
/// Phải nhiều hơn số worker chạy song song, không thì có worker ngồi không.
/// Mỗi đoạn chờ sẵn chỉ tốn vài trăm KB trong bộ nhớ đệm nên để rộng tay.
const _lookahead = 10;

class ExportService {
  ExportService(this._tts);

  final TtsManager _tts;
  final _storage = Storage.instance;

  /// Cờ điều khiển các job đang chạy.
  final _controls = <String, _Control>{};

  final _changes = StreamController<ExportJob>.broadcast();
  Stream<ExportJob> get changes => _changes.stream;

  File _jobFile(String id) => File(p.join(_storage.jobsDir.path, '$id.json'));
  Directory _workDir(String id) => Directory(p.join(_storage.jobsDir.path, id));

  Future<List<ExportJob>> listJobs({String? bookId}) async {
    if (!await _storage.jobsDir.exists()) return [];
    final jobs = <ExportJob>[];
    await for (final entity in _storage.jobsDir.list()) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      final json = await Storage.readJsonMap(entity);
      if (json == null) continue;
      final job = ExportJob.fromJson(json);
      if (bookId == null || job.bookId == bookId) jobs.add(job);
    }
    jobs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return jobs;
  }

  Future<ExportJob?> getJob(String id) async {
    final json = await Storage.readJsonMap(_jobFile(id));
    return json == null ? null : ExportJob.fromJson(json);
  }

  Future<void> _save(ExportJob job) async {
    await Storage.writeJson(_jobFile(job.id), job.toJson());
    if (!_changes.isClosed) _changes.add(job);
  }

  /// Các job còn dở từ lần chạy trước được đánh dấu tạm dừng để người dùng chủ động chạy tiếp.
  Future<void> recoverJobs() async {
    for (final job in await listJobs()) {
      if (job.isActive) {
        job.status = JobStatus.paused;
        await _save(job);
      }
    }
  }

  Future<ExportJob> createJob({
    required Book book,
    required AppSettings settings,
    required String voiceName,
    required String outputDir,
    required int fromChunk,
    required int toChunk,
  }) async {
    final id = '${DateTime.now().toIso8601String().substring(0, 10)}-'
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36).substring(4)}';

    final job = ExportJob(
      id: id,
      bookId: book.id,
      bookTitle: book.title,
      author: book.author,
      createdAt: DateTime.now(),
      engineId: settings.engineId,
      voiceId: settings.voiceId,
      voiceName: voiceName,
      speed: settings.speed,
      pauseMs: settings.chunkPauseMs,
      splitMode: settings.splitMode,
      partMinutes: settings.partMinutes,
      alignChapter: settings.alignChapter,
      fromChunk: fromChunk,
      toChunk: toChunk,
      outputDir: outputDir,
    );

    await _workDir(id).create(recursive: true);
    await Directory(outputDir).create(recursive: true);
    await _save(job);
    return job;
  }

  bool isRunning(String jobId) => _controls.containsKey(jobId);

  /// Đã bấm tạm dừng nhưng đoạn đang tổng hợp chưa xong.
  bool isStopping(String jobId) {
    final control = _controls[jobId];
    return control != null && (control.pause || control.cancel);
  }

  /// Ước lượng thời gian còn lại của một job đang chạy.
  ///
  /// Tính từ nhịp thực tế của chính máy này (trung bình động), vì tốc độ tổng
  /// hợp chênh nhau rất nhiều giữa giọng Edge và mô hình chạy trên GPU.
  Duration? remainingFor(ExportJob job) {
    final control = _controls[job.id];
    if (control == null || control.secondsPerChunk <= 0) return null;
    final left = job.totalChunks - job.doneChunks;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left * control.secondsPerChunk).round());
  }

  /// Bắt đầu hoặc chạy tiếp. Trả về ngay, công việc chạy nền.
  Future<void> start(ExportJob job, List<Chunk> chunks, List<Chapter> chapters) async {
    if (_controls.containsKey(job.id) || job.status == JobStatus.done) return;

    final control = _Control();
    _controls[job.id] = control;
    job.status = JobStatus.running;
    job.error = null;
    await _save(job);

    // Mở thêm luồng tổng hợp trong lúc xuất file. Đo được 8,94x thời gian thực
    // thay vì 2,87x — sách 10 giờ mất hơn một tiếng thay vì ba tiếng rưỡi.
    await _tts.engine(job.engineId).setBulkMode(true);

    unawaited(_run(job, chunks, chapters, control).catchError((Object err) async {
      if (job.status != JobStatus.canceled) {
        job.status = JobStatus.error;
        job.error = err.toString();
        await _save(job);
      }
    }).whenComplete(() async {
      _controls.remove(job.id);
      // Còn job khác đang chạy thì giữ nguyên; hết mới trả RAM về.
      if (_controls.isEmpty) await _tts.engine(job.engineId).setBulkMode(false);
    }));
  }

  Future<void> pause(ExportJob job) async {
    final control = _controls[job.id];
    if (control != null) {
      control.pause = true;
    } else if (job.isActive) {
      job.status = JobStatus.paused;
      await _save(job);
    }
  }

  Future<void> cancel(ExportJob job) async {
    final control = _controls[job.id];
    if (control != null) {
      control.cancel = true;
    } else if (job.status != JobStatus.done) {
      job.status = JobStatus.canceled;
      await _save(job);
    }
  }

  Future<void> deleteJob(ExportJob job, {bool deleteFiles = false}) async {
    _controls[job.id]?.cancel = true;
    final work = _workDir(job.id);
    if (await work.exists()) await work.delete(recursive: true);
    if (await _jobFile(job.id).exists()) await _jobFile(job.id).delete();

    if (deleteFiles) {
      for (final part in job.parts) {
        final file = File(p.join(job.outputDir, part.fileName));
        if (await file.exists()) await file.delete();
      }
    }
  }

  // -- phần chạy chính -------------------------------------------------------

  Future<void> _run(ExportJob job, List<Chunk> chunks, List<Chapter> chapters, _Control control) async {
    final targetSeconds = job.splitMode == SplitMode.duration ? job.partMinutes * 60.0 : double.infinity;

    // Engine chạy trong ứng dụng trả về WAV chứ không phải MP3. Cách ghép khác
    // nhau: MP3 nối thẳng khung dữ liệu và gắn thẻ ID3, WAV thì nối phần mẫu âm
    // rồi dựng lại phần đầu file khi đóng.
    final isWav = _tts.engine(job.engineId).audioFormat == 'wav';
    var wavRate = 22050;

    String chapterTitleOf(int chunkIndex) {
      if (chunkIndex < 0 || chunkIndex >= chunks.length) return '';
      final chapterIndex = chunks[chunkIndex].chapter;
      for (final chapter in chapters) {
        if (chapter.index == chapterIndex) return chapter.title;
      }
      return '';
    }

    var current = job.current ??
        PartInProgress(
          index: job.parts.length,
          chunkFrom: job.cursor,
          seconds: 0,
          bytes: 0,
          chapterTitle: chapterTitleOf(job.cursor),
        );

    File tmpFile() => File(p.join(_workDir(job.id).path, 'part-${(current.index + 1).toString().padLeft(3, '0')}.part'));

    await _workDir(job.id).create(recursive: true);
    final tmp = tmpFile();
    if (await tmp.exists()) {
      // Lần trước có thể bị tắt đột ngột: cắt file về đúng số byte đã ghi nhận
      // để không lặp lại một đoạn âm thanh.
      final size = await tmp.length();
      if (size > current.bytes) {
        final raf = await tmp.open(mode: FileMode.write);
        await raf.truncate(current.bytes);
        await raf.close();
      }
    } else {
      await tmp.writeAsBytes(const [], flush: true);
    }

    Future<void> closePart(int chunkTo) async {
      final file = tmpFile();
      if (!await file.exists()) return;
      final frames = await file.readAsBytes();
      if (frames.isEmpty) return;

      final partTitle = job.splitMode == SplitMode.chapter
          ? (current.chapterTitle.isEmpty ? 'Phần ${current.index + 1}' : current.chapterTitle)
          : '${job.bookTitle} — Phần ${current.index + 1}';

      final base = sanitizeFileName(job.bookTitle);
      final fileName = '${(current.index + 1).toString().padLeft(3, '0')} - '
          '${base.isEmpty ? 'sach-noi' : base}.${isWav ? 'wav' : 'mp3'}';
      final target = File(p.join(job.outputDir, fileName));

      // WAV không có chỗ ghi tên sách như thẻ ID3 của MP3, chỉ cần đúng phần đầu
      // mô tả số mẫu là mọi trình phát đọc được.
      final header = isWav
          ? wavHeader(frames.length, wavRate)
          : buildId3(
              title: partTitle,
              artist: job.author.isEmpty ? 'Sách nói' : job.author,
              album: job.bookTitle,
              track: '${current.index + 1}',
            );
      final output = BytesBuilder()..add(header)..add(frames);
      await target.writeAsBytes(output.takeBytes(), flush: true);
      await file.delete();

      job.parts.add(ExportPart(
        index: current.index,
        fileName: fileName,
        title: partTitle,
        seconds: current.seconds,
        bytes: await target.length(),
        chunkFrom: current.chunkFrom,
        chunkTo: chunkTo,
      ));
    }

    // Tổng hợp trước vài đoạn cho khỏi phải chờ.
    void prefetchFrom(int index) {
      final texts = <String>[];
      for (var i = index + 1; i <= min(index + _lookahead, job.toChunk); i++) {
        texts.add(chunks[i].speech);
      }
      if (texts.isNotEmpty) {
        _tts.prefetch(
          engineId: job.engineId,
          voiceId: job.voiceId,
          speed: job.speed,
          texts: texts,
        );
      }
    }

    while (job.cursor <= job.toChunk) {
      if (control.cancel) {
        job.status = JobStatus.canceled;
        job.current = current;
        await _save(job);
        return;
      }
      if (control.pause) {
        job.status = JobStatus.paused;
        job.current = current;
        await _save(job);
        return;
      }

      final index = job.cursor;
      if (index >= chunks.length) break;
      final chunk = chunks[index];

      prefetchFrom(index);
      final audio = await _tts.audioFor(
        engineId: job.engineId,
        voiceId: job.voiceId,
        speed: job.speed,
        text: chunk.speech,
      );

      // Quyết định đóng phần hiện tại *sau khi* biết đoạn này dài bao nhiêu, và
      // chọn bên nào gần mốc hơn — thiếu một chút hay thừa một chút — để độ dài
      // file bám sát con số người dùng đã chọn.
      final startsChapter = chunk.heading && index > current.chunkFrom;
      final overshoot = current.seconds + audio.seconds - targetSeconds;
      final undershoot = targetSeconds - current.seconds;
      final reachedTarget = overshoot > 0 && current.seconds >= targetSeconds * 0.5 && overshoot > undershoot;
      final nearTargetAtChapter = job.splitMode == SplitMode.duration &&
          job.alignChapter &&
          startsChapter &&
          current.seconds >= targetSeconds * 0.6;
      final newChapter = job.splitMode == SplitMode.chapter && startsChapter;

      if (current.seconds > 0 && (reachedTarget || nearTargetAtChapter || newChapter)) {
        await closePart(index - 1);
        current = PartInProgress(
          index: current.index + 1,
          chunkFrom: index,
          seconds: 0,
          bytes: 0,
          chapterTitle: chapterTitleOf(index),
        );
        await tmpFile().writeAsBytes(const [], flush: true);
        job.current = current;
        await _save(job);
      }

      final raw = await audio.file.readAsBytes();
      final Uint8List frames;
      if (isWav) {
        wavRate = readWavInfo(raw)?.sampleRate ?? wavRate;
        frames = wavPcm(raw);
      } else {
        frames = stripTags(raw);
      }

      // Khoảng nghỉ giữa hai đoạn phải nằm trong chính file xuất ra, nghe thử
      // trong ứng dụng thế nào thì mở bằng máy khác cũng đúng như thế.
      final pause = pauseAfterChunk(heading: chunk.heading, pauseMs: job.pauseMs).inMilliseconds / 1000;
      final silence = pause <= 0
          ? Uint8List(0)
          : isWav
              ? Uint8List((wavRate * 2 * pause).round() & ~1) // 16-bit mono: chẵn byte
              : silentFramesLike(frames, pause);

      final sink = tmpFile().openWrite(mode: FileMode.append);
      sink.add(frames);
      if (silence.isNotEmpty) sink.add(silence);
      await sink.flush();
      await sink.close();

      control.noteChunkDone();
      current.seconds += audio.seconds + pause;
      current.bytes += frames.length + silence.length;
      job.secondsDone += audio.seconds + pause;
      job.doneChunks++;
      job.cursor = index + 1;
      job.current = current;

      // Ghi trạng thái sau mỗi đoạn: chỉ tốn vài trăm byte nhưng đảm bảo chạy
      // tiếp đúng vị trí kể cả khi máy tắt đột ngột.
      await _save(job);
    }

    await closePart(job.toChunk);
    job.current = null;
    job.status = JobStatus.done;
    job.secondsDone = job.parts.fold<double>(0, (sum, part) => sum + part.seconds);
    await _save(job);
  }

  void dispose() => unawaited(_changes.close());
}

class _Control {
  bool pause = false;
  bool cancel = false;

  /// Thời gian trung bình cho một đoạn, làm mượt để con số ước lượng khỏi nhảy.
  double secondsPerChunk = 0;
  DateTime? _lastChunkAt;

  void noteChunkDone() {
    final now = DateTime.now();
    final last = _lastChunkAt;
    _lastChunkAt = now;
    if (last == null) return;
    final elapsed = now.difference(last).inMilliseconds / 1000;
    if (elapsed <= 0 || elapsed > 600) return; // máy ngủ hoặc treo mạng thì bỏ qua
    secondsPerChunk = secondsPerChunk == 0 ? elapsed : secondsPerChunk * 0.7 + elapsed * 0.3;
  }
}
