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

import '../core/kiem_am.dart';
import '../core/mp3.dart';
import '../core/wav.dart';
import '../models/book.dart';
import '../models/export_job.dart';
import '../models/settings.dart';
import 'audio_encoder.dart';
import 'storage.dart';
import 'thu_muc_xuat.dart';
import 'tts/tts_manager.dart';

/// Số đoạn tổng hợp trước trong lúc đang ghi đoạn hiện tại.
///
/// Phải nhiều hơn số worker chạy song song, không thì có worker ngồi không.
/// Mỗi đoạn chờ sẵn chỉ tốn vài trăm KB trong bộ nhớ đệm nên để rộng tay.
const _lookahead = 10;

/// Bao nhiêu đoạn liền nhau nối chung một chuỗi ngữ cảnh ở chế độ "theo lô".
///
/// Trong một lô, đoạn sau chờ đuôi của đoạn trước. Hết lô thì cắt chuỗi, nên
/// đầu mỗi lô vẫn tổng hợp trước được song song với lô đang chạy. Chỗ chuyển
/// giọng chỉ còn ở ranh giới lô — cứ 24 đoạn một lần thay vì mọi đoạn.
const _kichThuocLo = 24;

/// Đọc lại tối đa mấy lần khi soi ra đoạn vừa đọc không khớp văn bản.
///
/// Mỗi lần đọc lại tốn đúng bằng một đoạn mới, nên phải có trần: đoạn nào mô
/// hình đọc hỏng đủ năm lần liền thì lần thứ sáu cũng khó khá hơn, mà cả lượt
/// xuất thì đứng lại chờ. Hết lượt vẫn lệch thì lấy bản gần đúng nhất.
const _docLaiToiDa = 5;

/// Tên file cho một phần đã xuất, chưa kèm đuôi.
///
/// Dạng `<tên truyện> - <chương> - <số thứ tự file>`, ví dụ:
///
///     Phàm Nhân Tu Tiên - 007 - 002
///     Phàm Nhân Tu Tiên - 007-009 - 003     (file gộp nhiều chương)
///
/// Số chương đệm 0 cho đủ số chữ số của chương lớn nhất trong truyện, để tên
/// file sắp theo bảng chữ cái là ra đúng thứ tự nghe — truyện 638 chương thì
/// chương 7 phải là "007", không thì máy xếp nó sau chương 60.
///
/// [chuongDau] và [chuongCuoi] đếm từ 1, đúng con số người dùng thấy trong ứng
/// dụng. Trùng nhau thì chỉ ghi một số.
String tenFileXuat({
  required String bookTitle,
  required int chuongDau,
  required int chuongCuoi,
  required int soChuongLonNhat,
  required int soThuTuFile,
}) {
  final ten = sanitizeFileName(bookTitle);
  final rong = soChuongLonNhat.toString().length;
  String so(int n) => n.toString().padLeft(rong, '0');
  final chuong = chuongDau == chuongCuoi ? so(chuongDau) : '${so(chuongDau)}-${so(chuongCuoi)}';
  return '${ten.isEmpty ? 'sach-noi' : ten} - $chuong - '
      '${soThuTuFile.toString().padLeft(3, '0')}';
}

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

  Future<void> _save(ExportJob job) async {
    await Storage.writeJson(_jobFile(job.id), job.toJson());
    if (!_changes.isClosed) _changes.add(job);
  }

  /// Báo giao diện vẽ lại mà KHÔNG ghi xuống đĩa — dùng cho cờ chạy trong bộ
  /// nhớ như [ExportJob.dangNen], đổi liên tục hơn những gì đáng để ghi file.
  void _notify(ExportJob job) {
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
    required String treeUri,
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
      voiceId: settings.voiceXuat,
      voiceName: voiceName,
      speed: settings.speed,
      pauseMs: settings.chunkPauseMs,
      // Máy không nén được (điện thoại) thì đừng hứa Opus rồi lại ra WAV.
      formatId: encoderAvailable ? settings.exportFormat.id : ExportFormat.wav.id,
      splitMode: settings.splitMode,
      partMinutes: settings.partMinutes,
      alignChapter: settings.alignChapter,
      fromChunk: fromChunk,
      toChunk: toChunk,
      outputDir: outputDir,
      treeUri: treeUri,
      nguCanh: settings.nguCanhXuat,
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
  /// hợp chênh nhau rất nhiều giữa các engine và giữa máy mạnh với máy yếu.
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

  Future<void> deleteJob(ExportJob job, {bool deleteFiles = false}) async {
    _controls[job.id]?.cancel = true;
    final work = _workDir(job.id);
    if (await work.exists()) await work.delete(recursive: true);
    if (await _jobFile(job.id).exists()) await _jobFile(job.id).delete();

    // Bản riêng để phát trong ứng dụng chỉ có ý nghĩa khi còn job — xoá theo
    // bất kể deleteFiles: đây không phải file người dùng thấy ở thư viện nhạc
    // hay thư mục họ chọn, xoá nó không mất gì của họ.
    final playDir = _storage.exportPlaybackDir(job.id);
    if (await playDir.exists()) await playDir.delete(recursive: true);

    if (deleteFiles) {
      for (final part in job.parts) {
        final file = File(p.join(job.outputDir, part.fileName));
        if (await file.exists()) await file.delete();
      }
    }
  }

  /// Đường dẫn thật để phát [part] của [job] ngay trong ứng dụng, null nếu
  /// không mở lại được.
  ///
  /// Máy tính: file xuất nằm nguyên trong outputDir của job, dùng thẳng.
  /// Android: bản gốc đã bị MediaStore/thư mục người dùng chọn dọn sau khi
  /// đăng ký — [part.fileName] ở đó chỉ còn là tên hiển thị dạng
  /// "Music/Sách lười/..." chứ không phải đường dẫn mở lại được — nên phải
  /// dùng bản riêng đã chép sẵn lúc xuất, xem [ExportPart.localPlayPath].
  String? playablePath(ExportJob job, ExportPart part) {
    if (needsMediaStore) return part.localPlayPath;
    return p.join(job.outputDir, part.fileName);
  }

  /// Xoá riêng file của [part] và bỏ nó khỏi danh sách của [job].
  ///
  /// Máy tính: xoá được thẳng file thật trong outputDir. Android: file thật
  /// đã nằm ngoài tầm với của app từ lúc đăng ký ra MediaStore/thư mục người
  /// dùng chọn (cùng lý do không phát lại được — xem [playablePath]), nên chỉ
  /// xoá được bản riêng dùng để phát trong ứng dụng; file ở thư viện nhạc hay
  /// thư mục đã chọn vẫn còn đó, người dùng phải tự xoá bằng ứng dụng quản lý
  /// file. Không ném lỗi vì việc này — thà xoá được một phần còn hơn không.
  Future<void> deletePart(ExportJob job, ExportPart part) async {
    try {
      final file = File(p.join(job.outputDir, part.fileName));
      if (await file.exists()) await file.delete();
    } catch (_) {}
    final local = part.localPlayPath;
    if (local != null) {
      try {
        final file = File(local);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }

    job.parts = job.parts.where((each) => each.index != part.index).toList();
    job.secondsDone = job.parts.fold<double>(0, (sum, each) => sum + each.seconds);
    await _save(job);
  }

  /// Đọc một đoạn rồi soi lại ngay: số âm nghe được có khớp số từ không.
  ///
  /// Không khớp là dấu hiệu mô hình đã đọc hỏng — lặp lại mấy chữ cuối, nuốt
  /// mất nửa câu, hay lảm nhảm không dừng — nên đọc lại, mỗi lần một hạt giống
  /// khác nên ra một bản đọc khác. Hết [_docLaiToiDa] lượt mà vẫn lệch thì lấy
  /// bản gần đúng nhất trong tất cả các lần: thà lệch một chút còn hơn để trống
  /// một đoạn giữa sách, mà cũng không thể bắt cả lượt xuất đứng lại mãi.
  ///
  /// Engine đọc theo luật (Piper, TTS hệ thống) thì đọc lại cũng ra đúng bản
  /// cũ — không phí thời gian, chỉ đọc một lần rồi lấy.
  Future<_DoanDaDoc> _docVaSoi(ExportJob job, Chunk chunk, List<int>? nguCanh) async {
    final soLan = _tts.engine(job.engineId).docLaiRaKhac ? _docLaiToiDa : 0;
    _DoanDaDoc? tot;

    // Dòng nhật ký của riêng đoạn này, chỉ mở ra khi thật sự có chuyện. Sửa tại
    // chỗ qua từng lượt đọc chứ không đẻ thêm dòng mới: người xem cần biết đoạn
    // nào đang vật lộn, không cần biên bản từng lượt một.
    MucNhatKy? muc;
    void ghiSo(KetQuaKiemAm ket, int lan, {bool xong = false}) {
      if (muc == null) {
        if (ket.dat) return; // đọc trúng ngay lần đầu thì không có gì để ghi
        muc = MucNhatKy(doan: chunk.index, soTu: ket.soTu, soAm: ket.soAm ?? 0, soLan: lan);
        job.ghiNhatKy(muc!);
      } else {
        muc!
          ..soAm = ket.soAm ?? 0
          ..soLan = lan;
      }
      muc!
        ..xong = xong
        ..dat = ket.dat;
      _notify(job);
    }

    for (var lan = 0; lan <= soLan; lan++) {
      final audio = await _tts.audioFor(
        engineId: job.engineId,
        voiceId: job.voiceId,
        speed: job.speed,
        text: chunk.speech,
        nguCanh: nguCanh,
        lanThu: lan,
      );
      final raw = await audio.file.readAsBytes();
      final doan = _DoanDaDoc(
        audio,
        raw,
        kiemAm(speech: chunk.speech, wav: raw, nhip: job.speed),
        lan + 1,
      );
      ghiSo(doan.kiem, lan + 1, xong: doan.kiem.dat);
      if (doan.kiem.dat) return doan;
      // Lệch bằng nhau thì giữ bản đầu: các lần sau không hơn gì mà bản đầu còn
      // là bản người dùng nghe thấy trong ứng dụng.
      if (tot == null || doan.kiem.lech < tot.kiem.lech) tot = doan;
    }
    // Chốt sổ theo bản được chọn, không phải bản đọc cuối cùng.
    ghiSo(tot!.kiem, soLan + 1, xong: true);
    // Số lần đọc là của cả lượt, không phải của riêng bản được chọn: bản gần
    // đúng nhất có thể chính là bản đọc đầu tiên.
    return _DoanDaDoc(tot.audio, tot.raw, tot.kiem, soLan + 1);
  }

  // -- phần chạy chính -------------------------------------------------------

  Future<void> _run(ExportJob job, List<Chunk> chunks, List<Chapter> chapters, _Control control) async {
    final targetSeconds = job.splitMode == SplitMode.duration ? job.partMinutes * 60.0 : double.infinity;

    // Engine chạy trong ứng dụng trả về WAV chứ không phải MP3. Cách ghép khác
    // nhau: MP3 nối thẳng khung dữ liệu và gắn thẻ ID3, WAV thì nối phần mẫu âm
    // rồi dựng lại phần đầu file khi đóng.
    final isWav = _tts.engine(job.engineId).audioFormat == 'wav';
    // Định dạng đích của job. null khi engine trả về MP3 sẵn (không nén lại).
    final dinhDang = isWav ? ExportFormat.fromId(job.formatId) : null;
    var wavRate = 22050;

    // Chương lớn nhất của cả truyện, không phải của khoảng đang xuất: xuất lại
    // vài chương lẻ thì bề rộng số vẫn phải giống lần xuất trước, không thì tên
    // file của cùng một truyện lệch nhau.
    //
    // Lấy chỉ số lớn nhất chứ không lấy số lượng: chương không có gì để đọc bị
    // bỏ khỏi danh sách nên hai con số này không phải lúc nào cũng bằng nhau.
    final soChuongLonNhat = chapters.isEmpty
        ? 1
        : chapters.map((c) => c.index + 1).reduce((a, b) => a > b ? a : b);

    /// Số chương chứa đoạn [chunkIndex], đếm từ 1 như người dùng thấy.
    int chuongCua(int chunkIndex) {
      final at = chunkIndex.clamp(0, chunks.length - 1);
      return chunks.isEmpty ? 1 : chunks[at].chapter + 1;
    }

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

      final tenGoc = tenFileXuat(
        bookTitle: job.bookTitle,
        chuongDau: chuongCua(current.chunkFrom),
        chuongCuoi: chuongCua(chunkTo),
        soChuongLonNhat: soChuongLonNhat,
        soThuTuFile: current.index + 1,
      );
      // Luôn ghi WAV trước rồi mới nén, nên bước này lúc nào cũng là .wav khi
      // engine trả về mẫu âm thô.
      final fileName = '$tenGoc.${isWav ? 'wav' : 'mp3'}';
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

      // Nén sau khi WAV đã hoàn chỉnh, chứ không nén từng đoạn: nối các khung
      // Opus lại với nhau là hỏng container, mà nén cả file một lần cũng cho ra
      // thời lượng và việc tua chính xác. Mất 5-9 giây cho một file 30 phút.
      var thanhPham = target;
      if (dinhDang != null && !dinhDang.isWav) {
        job.dangNen = true;
        job.nenPhan = null;
        _notify(job);
        try {
          // Đuôi file do bộ mã hoá quyết định: Android không có MP3, và máy dưới
          // Android 10 cũng không có Opus, cả hai trường hợp đều ra .m4a.
          final duongDan = await encodeAudioFile(
            wavPath: target.path,
            outBase: p.join(job.outputDir, tenGoc),
            format: switch (dinhDang.extension) {
              'opus' => EncodeFormat.opus,
              'aac' => EncodeFormat.aac,
              _ => EncodeFormat.mp3,
            },
            bitrate: dinhDang.bitrate,
            onProgress: (phan) {
              job.nenPhan = phan;
              _notify(job);
            },
          );
          await target.delete();
          thanhPham = File(duongDan);
        } catch (err) {
          // Nén lỗi thì giữ WAV lại — thà file nặng còn hơn mất cả phần vừa đọc.
          job.error = 'Không nén được $tenGoc: $err (giữ nguyên WAV)';
        } finally {
          job.dangNen = false;
          job.nenPhan = null;
          _notify(job);
        }
      }

      // Android: file vừa ghi đang nằm trong vùng riêng của app, chỗ mà từ
      // Android 11 chính người dùng cũng không mở ra xem được. Phải đưa nó ra
      // ngoài — hoặc vào thư mục người dùng đã chọn, hoặc vào thư viện nhạc của
      // hệ thống. Ghi thẳng bằng File API vào bộ nhớ chung thì bị chặn.
      final soByte = await thanhPham.length();
      var tenHienThi = p.basename(thanhPham.path);
      String? localPlayPath;
      if (needsMediaStore) {
        // Chép một bản riêng cho ứng dụng TRƯỚC khi đăng ký ra ngoài — cả
        // MediaStore lẫn thư mục người dùng chọn đều xoá bản gốc sau khi chép
        // và chỉ trả về chuỗi hiển thị, không phải đường dẫn hay URI dùng lại
        // được, nên đây là cách duy nhất phát file này ngay trong ứng dụng.
        try {
          final localDir = _storage.exportPlaybackDir(job.id);
          await localDir.create(recursive: true);
          final localFile =
              File(p.join(localDir.path, 'phan-${current.index}${p.extension(thanhPham.path)}'));
          await thanhPham.copy(localFile.path);
          localPlayPath = localFile.path;
        } catch (_) {
          // Chép hụt thì chỉ mất khả năng phát trong ứng dụng, file xuất ra
          // ngoài vẫn không sao — không đáng làm hỏng cả lượt xuất vì việc này.
        }

        final thuMuc = sanitizeFileName(job.bookTitle);
        final thuMucCon = thuMuc.isEmpty ? job.bookId : thuMuc;
        try {
          tenHienThi = job.treeUri.isEmpty
              ? await publishToMusicLibrary(
                  nguon: thanhPham.path,
                  thuMucCon: 'Sách lười/$thuMucCon',
                  tenFile: p.basename(thanhPham.path),
                )
              : await chepVaoThuMuc(
                  nguon: thanhPham.path,
                  cay: job.treeUri,
                  thuMucCon: thuMucCon,
                  tenFile: p.basename(thanhPham.path),
                );
        } catch (err) {
          // Giữ nguyên file trong vùng riêng chứ không xoá: chép hụt mà xoá mất
          // thì cả phần vừa đọc đi tong. Người dùng chọn lại thư mục rồi xuất
          // lại phần này là xong.
          job.error = 'Không cất được file ra ngoài: $err';
        }
      }

      job.parts.add(ExportPart(
        index: current.index,
        fileName: tenHienThi,
        title: partTitle,
        seconds: current.seconds,
        bytes: soByte,
        chunkFrom: current.chunkFrom,
        chunkTo: chunkTo,
        localPlayPath: localPlayPath,
      ));
    }

    final nguCanh = job.nguCanh;

    /// Đoạn này có mở đầu một lô mới không — đầu lô thì không nối ngữ cảnh.
    bool dauLo(int index) => switch (nguCanh) {
          NguCanh.khong => true,
          NguCanh.tuanTu => index == job.fromChunk,
          NguCanh.loLon => (index - job.fromChunk) % _kichThuocLo == 0,
        };

    // Tổng hợp trước vài đoạn cho khỏi phải chờ.
    //
    // Chỉ đọc trước những đoạn KHÔNG cần ngữ cảnh: đoạn cần ngữ cảnh mà đọc
    // trước thì vừa ra bản không nối, vừa lấp cache bằng đúng bản ấy.
    void prefetchFrom(int index) {
      final texts = <String>[];
      for (var i = index + 1; i <= min(index + _lookahead, job.toChunk); i++) {
        if (!dauLo(i)) continue;
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

    // Mã đuôi của đoạn vừa đọc, để nối cho đoạn kế trong cùng một lô.
    List<int> duoi = const [];

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
      final doc = await _docVaSoi(job, chunk, dauLo(index) ? null : duoi);
      final audio = doc.audio;
      duoi = audio.duoi;
      if (doc.soLanDoc > 1) {
        job.doanDocLai++;
        if (!doc.kiem.dat) job.doanChuaDat++;
      }

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

      final raw = doc.raw;
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

/// Một đoạn đã đọc xong kèm kết quả soi lại.
class _DoanDaDoc {
  const _DoanDaDoc(this.audio, this.raw, this.kiem, this.soLanDoc);

  final CachedAudio audio;

  /// Byte của chính bản đọc này. Giữ lại chứ không đọc lại từ đĩa: file trong
  /// bộ nhớ đệm có thể bị dọn bất cứ lúc nào (xem [TtsManager.cacheLimitBytes]).
  final Uint8List raw;
  final KetQuaKiemAm kiem;

  /// Đã đọc cả thảy mấy lượt cho đoạn này — 1 là đọc một lần rồi đạt luôn.
  final int soLanDoc;
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
