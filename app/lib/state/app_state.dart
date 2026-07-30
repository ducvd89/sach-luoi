/// Trạng thái dùng chung của toàn ứng dụng.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/book.dart';
import '../models/export_job.dart';
import '../models/settings.dart';
import '../models/work_progress.dart';
import '../services/export_service.dart';
import '../services/library_service.dart';
import '../services/media_session.dart';
import '../services/player_controller.dart';
import '../services/storage.dart';
import '../services/tts/tts_engine.dart';
import '../services/tts/tts_manager.dart';

/// Thư mục xuất file không ghi được.
class ExportDirException implements Exception {
  const ExportDirException(this.message);
  final String message;
  @override
  String toString() => message;
}

class AppState extends ChangeNotifier {
  AppState._(this.settings) {
    player = PlayerController(tts, library)..attachStreams();
    exports = ExportService(tts);
  }

  static Future<AppState> create() async {
    await Storage.init();
    final json = await Storage.readJsonMap(Storage.instance.settingsFile);

    final settings = json != null ? AppSettings.fromJson(json) : AppSettings();

    final state = AppState._(settings);
    await state._bootstrap();
    return state;
  }

  final LibraryService library = LibraryService();
  final TtsManager tts = TtsManager();
  late final PlayerController player;
  late final ExportService exports;

  AppSettings settings;

  List<Book> books = const [];
  Book? currentBook;
  List<ExportJob> jobs = const [];
  List<TtsVoice> voices = const [];

  /// Tiến trình nhập sách đang chạy, null khi rảnh. Cả thư viện lẫn khung chính
  /// đều đọc để hiện thanh tiến trình.
  WorkProgress? importProgress;

  /// Tên file đang nhập và vị trí trong hàng đợi, ví dụ "2/5".
  String importLabel = '';

  /// Các job đang nạp dữ liệu để bắt đầu chạy — bấm xong là thấy phản hồi ngay.
  final Set<String> preparingJobs = {};

  /// Tiến trình tải mô hình giọng đọc, null khi không tải.
  WorkProgress? modelProgress;

  /// Mô hình đã có trên máy chưa (null nghĩa là chưa kiểm tra).
  bool? modelInstalled;

  Future<void> refreshModelStatus() async {
    modelInstalled = await tts.modelStore.isInstalled();
    notifyListeners();
  }

  /// Tải mô hình về máy. Khoảng 206 MB, chỉ làm một lần.
  Future<void> downloadModel() async {
    if (modelProgress != null) return;
    modelProgress = const WorkProgress('Đang chuẩn bị…');
    notifyListeners();
    try {
      await tts.modelStore.download(onProgress: (p) {
        modelProgress = p;
        notifyListeners();
      });
      modelInstalled = true;
      // Có mô hình rồi thì nạp luôn để nghe được ngay.
      tts.onDevice.unawaitedStart();
      await refreshEngine();
    } finally {
      modelProgress = null;
      notifyListeners();
    }
  }

  /// Thêm một giọng từ file ghi âm. Tải sẵn hai mô hình phụ nếu chưa có.
  Future<void> addVoice({required String name, required String wavPath}) async {
    modelProgress = const WorkProgress('Đang chuẩn bị…');
    notifyListeners();
    try {
      if (!await tts.modelStore.canEnroll()) {
        await tts.modelStore.downloadEnrollModels(onProgress: (p) {
          modelProgress = p;
          notifyListeners();
        });
      }
      modelProgress = const WorkProgress('Đang phân tích giọng…', value: 0.95);
      notifyListeners();
      await tts.onDevice.addVoice(name: name, wavPath: wavPath);
      await refreshEngine();
    } finally {
      modelProgress = null;
      notifyListeners();
    }
  }

  Future<void> removeVoice(String name) async {
    await tts.onDevice.removeVoice(name);
    await refreshEngine();
  }

  Future<void> deleteModel() async {
    await tts.modelStore.delete();
    await refreshModelStatus();
    await refreshEngine();
  }

  /// Job đang chạy đầu tiên, để khung chính hiện thanh tiến trình ở mọi tab.
  ExportJob? get runningJob => jobs.where((j) => exports.isRunning(j.id)).firstOrNull;

  EngineStatus engineStatus = const EngineStatus(ready: false, message: 'Đang kiểm tra…', loading: true);

  SachLuoiAudioHandler? _mediaSession;

  Timer? _statusTimer;
  StreamSubscription<ExportJob>? _jobSubscription;

  Future<void> _bootstrap() async {
    tts.cacheLimitBytes = settings.cacheLimitBytes;
    await exports.recoverJobs();
    books = await library.listBooks();
    jobs = await exports.listJobs();

    // Job tự lưu trạng thái sau mỗi đoạn. Chỉ thay đúng phần tử đã đổi thay vì
    // đọc lại toàn bộ thư mục jobs — nếu không thì mỗi đoạn lại một lượt đọc đĩa
    // ngay trên isolate giao diện.
    _jobSubscription = exports.changes.listen((job) {
      final list = [...jobs];
      final at = list.indexWhere((j) => j.id == job.id);
      if (at >= 0) {
        list[at] = job;
      } else {
        list.insert(0, job);
      }
      jobs = list;
      notifyListeners();
    });

    // Đưa lên phần "Đang phát" của hệ điều hành để điều khiển được từ màn hình
    // khoá và tai nghe. Không có cũng không sao — nghe trong app vẫn chạy.
    _mediaSession = await startMediaSession(player);

    unawaited(refreshEngine());
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!engineStatus.ready) unawaited(refreshEngine());
    });
    notifyListeners();
  }

  // -- engine và giọng đọc ---------------------------------------------------

  Future<void> refreshEngine() async {
    final engine = tts.engine(settings.engineId);
    final status = await engine.status();
    engineStatus = status;

    if (status.ready) {
      try {
        voices = await engine.voices();
        if (voices.isNotEmpty && !voices.any((v) => v.id == settings.voiceId)) {
          settings.voiceId = voices.first.id;
          await saveSettings();
        }
      } catch (err) {
        engineStatus = EngineStatus(ready: false, message: 'Không lấy được danh sách giọng: $err');
      }
    }
    notifyListeners();
  }

  Future<void> setEngine(String engineId) async {
    settings.engineId = engineId;
    voices = const [];
    engineStatus = const EngineStatus(ready: false, message: 'Đang kiểm tra…', loading: true);
    notifyListeners();

    await saveSettings();
    await refreshEngine();
  }

  // -- thư viện --------------------------------------------------------------

  Future<void> reloadBooks() async {
    books = await library.listBooks();
    notifyListeners();
  }

  /// Nhập một file sách. [label] là vị trí trong hàng đợi, ví dụ "2/5".
  Future<ImportResult> importFile(String path, {String label = ''}) async {
    importLabel = label;
    _setImportProgress(const WorkProgress('Đang mở file…'));
    try {
      final result = await library.importFile(
        path,
        expandNumbers: settings.expandNumbers,
        removeBoilerplate: settings.removeBoilerplate,
        onProgress: _setImportProgress,
      );
      await reloadBooks();
      return result;
    } finally {
      importProgress = null;
      importLabel = '';
      notifyListeners();
    }
  }

  void _setImportProgress(WorkProgress progress) {
    importProgress = progress;
    notifyListeners();
  }

  /// Dựng lại một cuốn sách đã có từ file gốc, áp cài đặt hiện tại.
  ///
  /// Dùng khi người dùng bật lại việc dọn quảng cáo hay chuẩn hoá số cho những
  /// cuốn đã nhập từ trước — không phải thêm lại sách và không mất chỗ đang nghe.
  Future<ImportResult> rebuildBook(Book book, {String label = ''}) async {
    importLabel = label;
    _setImportProgress(const WorkProgress('Đang mở file gốc…'));
    try {
      final result = await library.rebuild(
        book.id,
        expandNumbers: settings.expandNumbers,
        removeBoilerplate: settings.removeBoilerplate,
        onProgress: _setImportProgress,
      );
      if (currentBook?.id == book.id) {
        currentBook = result.book;
        await player.open(result.book, settings);
      }
      await reloadBooks();
      return result;
    } finally {
      importProgress = null;
      importLabel = '';
      notifyListeners();
    }
  }

  Future<void> openBook(Book book) async {
    currentBook = book;
    await player.open(book, settings);
    jobs = await exports.listJobs();
    notifyListeners();
  }

  Future<void> deleteBook(Book book) async {
    if (currentBook?.id == book.id) {
      await player.stop();
      currentBook = null;
    }
    await library.deleteBook(book.id);
    await reloadBooks();
  }

  // -- cài đặt ---------------------------------------------------------------

  /// Vẽ lại theo cài đặt vừa đổi mà chưa ghi xuống đĩa — dùng khi kéo thanh
  /// trượt, ghi file sau mỗi khung hình thì phí.
  void notifySettingsChanged() {
    player.updateSettings(settings);
    tts.cacheLimitBytes = settings.cacheLimitBytes;
    notifyListeners();
  }

  Future<void> saveSettings() async {
    await Storage.writeJson(Storage.instance.settingsFile, settings.toJson());
    tts.cacheLimitBytes = settings.cacheLimitBytes;
    player.updateSettings(settings);
    notifyListeners();
  }

  Future<void> setSpeed(double speed) async {
    settings.speed = speed;
    await saveSettings();
  }

  Future<void> setVoice(String voiceId) async {
    settings.voiceId = voiceId;
    await saveSettings();
  }

  Future<({int bytes, int files})> cacheStats() => Storage.instance.cacheStats();

  /// Đổi trần bộ nhớ đệm và dọn ngay nếu đang vượt.
  ///
  /// Dọn ngay chứ không đợi lần đọc sau: người dùng vừa hạ trần thì họ muốn thấy
  /// dung lượng giảm liền, không phải nghe thêm mười phút mới thấy.
  Future<int> setCacheLimit(int megabytes) async {
    settings.cacheLimitMb = megabytes;
    await saveSettings();
    return Storage.instance.trimCache(settings.cacheLimitBytes);
  }

  Future<void> clearCache() async {
    await Storage.instance.clearCache();
    notifyListeners();
  }

  // -- xuất file -------------------------------------------------------------

  Future<ExportJob> startExport({
    required Book book,
    required String outputDir,
    required int fromChunk,
    required int toChunk,
  }) async {
    // Kiểm tra ghi được trước khi tạo job: sai thư mục thì nói ngay chứ đừng để
    // người dùng chờ rồi mới vỡ ở file đầu tiên.
    final loi = await Storage.checkWritable(outputDir);
    if (loi != null) throw ExportDirException(loi);

    final voiceName = voices.where((v) => v.id == settings.voiceId).map((v) => v.name).firstOrNull ?? settings.voiceId;
    final job = await exports.createJob(
      book: book,
      settings: settings,
      voiceName: voiceName,
      outputDir: outputDir,
      fromChunk: fromChunk,
      toChunk: toChunk,
    );
    await resumeExport(job);
    return job;
  }

  Future<void> resumeExport(ExportJob job) async {
    if (!preparingJobs.add(job.id)) return;
    notifyListeners();
    try {
      final book = await library.getBook(job.bookId);
      if (book == null) return;
      final chunks = await library.loadChunks(job.bookId);
      await exports.start(job, chunks, book.chapters);
    } finally {
      preparingJobs.remove(job.id);
      notifyListeners();
    }
  }

  /// Tạm dừng chỉ có hiệu lực khi đoạn đang tổng hợp xong, nên phải vẽ lại ngay
  /// để nút đổi sang "Đang dừng…" thay vì trông như bấm hụt.
  Future<void> pauseExport(ExportJob job) async {
    await exports.pause(job);
    notifyListeners();
  }

  Future<void> reloadJobs() async {
    jobs = await exports.listJobs();
    notifyListeners();
  }

  String get dataDirectory => Storage.instance.root.path;

  /// Thư mục mặc định để lưu file MP3 xuất ra.
  Future<String> defaultExportDir(Book book) async {
    final name = sanitizeFileName(book.title);
    final sub = name.isEmpty ? book.id : name;

    // Android: ghi vào vùng riêng của app — chỗ duy nhất luôn ghi được. File
    // hoàn chỉnh sau đó được đăng ký vào Music/Sách lười của hệ thống qua
    // MediaStore rồi bản tạm này bị xoá, nên người dùng không bao giờ phải mở
    // thư mục này ra.
    if (Platform.isAndroid) {
      return p.join(Storage.instance.root.path, 'xuat', sub);
    }

    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? Storage.instance.root.path;
    return '$home${Platform.pathSeparator}Music${Platform.pathSeparator}Sách nói'
        '${Platform.pathSeparator}$sub';
  }

  @override
  void dispose() {
    _mediaSession?.detach();
    _statusTimer?.cancel();
    unawaited(_jobSubscription?.cancel());
    player.dispose();
    exports.dispose();
    super.dispose();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
