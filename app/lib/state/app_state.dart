/// Trạng thái dùng chung của toàn ứng dụng.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/nhan_vat.dart';
import '../models/book.dart';
import '../services/laya_native.dart';
import '../models/export_job.dart';
import '../models/settings.dart';
import '../models/work_progress.dart';
import '../services/export_service.dart';
import '../services/import_worker.dart' show DoanVanSach;
import '../services/khoa_cam_ung.dart';
import '../services/library_service.dart';
import '../services/media_session.dart';
import '../services/player_controller.dart';
import '../services/storage.dart';
import '../services/thu_muc_xuat.dart';
import '../services/tts/tts_engine.dart';
import '../services/tts/tts_manager.dart';

/// Thư mục xuất file không ghi được.
class ExportDirException implements Exception {
  const ExportDirException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Giọng [v] hợp giới tính [gioi] ('nam' | 'nu') không. Giới tính của giọng lưu bằng chữ Việt
/// ("Nam", "Nữ" — xem `_genders` ở model_store) hoặc 'male'/'female'; bản cũ so tiền tố 'm'/'f' nên
/// KHÔNG giọng nào khớp và mọi giọng bị ghi "(khác giới)".
bool giongHopGioi(TtsVoice v, String gioi) {
  final g = v.gender.toLowerCase().trim();
  final laNu = g.startsWith('nữ') || g.startsWith('nu') || g.startsWith('f');
  final laNam = g.startsWith('nam') || g.startsWith('m');
  return gioi == 'nu' ? laNu : laNam;
}

class AppState extends ChangeNotifier {
  AppState._(this.settings) {
    player = PlayerController(tts, library)..attachStreams();
    exports = ExportService(tts);
  }

  static Future<AppState> create() async {
    await Storage.init();
    final json = await Storage.readJsonMap(Storage.instance.settingsFile);

    final settings = json != null ? AppSettings.fromJson(json) : AppSettings(engineId: defaultEngineId);

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

  /// Nhân vật của sách đang mở; null là chưa phân tích.
  NhanVatSach? nhanVat;

  /// Tiến trình phân tích nhân vật (value = đã hỏi / tổng câu thoại), null khi không chạy.
  WorkProgress? nhanVatTienDo;

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

  /// Đang khoá cảm ứng hay không.
  ///
  /// KHÔNG lưu xuống đĩa, có chủ ý: mở ứng dụng lên mà thấy màn hình khoá sẵn
  /// thì người dùng không hiểu chuyện gì, lại còn phải trượt mới dùng được. Khoá
  /// chỉ sống trong đúng phiên đang nghe.
  bool khoaCamUng = false;

  Future<void> batKhoaCamUng() async {
    if (khoaCamUng) return;
    khoaCamUng = true;
    notifyListeners();
    await batKhoaManHinh();
  }

  Future<void> moKhoaCamUng() async {
    if (!khoaCamUng) return;
    khoaCamUng = false;
    notifyListeners();
    await tatKhoaManHinh();
  }

  /// Bộ file của engine v2 đã có chưa (null nghĩa là chưa kiểm tra).
  ///
  /// Tách hẳn khỏi [modelInstalled]: hai engine tải riêng, người dùng có thể chỉ
  /// muốn một trong hai chứ không phải cả 693 MB.
  bool? v2Installed;

  Future<void> refreshModelStatus() async {
    modelInstalled = await tts.modelStore.isInstalled();
    notifyListeners();
  }

  Future<void> refreshV2Status() async {
    v2Installed = await tts.modelStore.isV2Installed();
    notifyListeners();
  }

  /// Tải bộ file của engine v2 (khoảng 478 MB).
  Future<void> downloadV2Model() async {
    if (modelProgress != null) return;
    modelProgress = const WorkProgress('Đang chuẩn bị…');
    notifyListeners();
    try {
      await tts.modelStore.downloadV2(onProgress: (p) {
        modelProgress = p;
        notifyListeners();
      });
      v2Installed = true;
      tts.vieneuV2.unawaitedStart();
      await refreshEngine();
    } finally {
      modelProgress = null;
      notifyListeners();
    }
  }

  /// Tải bộ mã hoá NeuCodec, chỉ cần khi thêm giọng cho v2.
  Future<void> downloadV2Encoder() async {
    modelProgress = const WorkProgress('Đang chuẩn bị…');
    notifyListeners();
    try {
      await tts.modelStore.downloadV2Encoder(onProgress: (p) {
        modelProgress = p;
        notifyListeners();
      });
    } finally {
      modelProgress = null;
      notifyListeners();
    }
  }

  /// Thêm một giọng cho engine v2 từ file ghi âm kèm lời của đoạn ấy.
  Future<void> addVoiceV2({
    required String name,
    required String wavPath,
    required String text,
  }) async {
    modelProgress = const WorkProgress('Đang phân tích giọng…', value: 0.5);
    notifyListeners();
    try {
      await tts.vieneuV2.addVoice(name: name, wavPath: wavPath, text: text);
      await refreshEngine();
    } finally {
      modelProgress = null;
      notifyListeners();
    }
  }

  Future<void> removeVoiceV2(String name) async {
    await tts.vieneuV2.removeVoice(name);
    await refreshEngine();
  }

  Future<void> deleteV2Model() async {
    tts.vieneuV2.dispose();
    await tts.modelStore.deleteV2();
    await refreshV2Status();
    await refreshEngine();
  }

  /// Bộ file của engine Matcha đã có chưa (null nghĩa là chưa kiểm tra).
  ///
  /// Tách hẳn khỏi hai cờ trên, cùng lý do: ba engine tải riêng và gỡ riêng.
  bool? matchaInstalled;
  bool? coWav2vec2;
  WorkProgress? tienDoWav2vec2;

  Future<void> xemWav2vec2() async {
    coWav2vec2 = await tts.kiemAm.kho.sanSang();
    notifyListeners();
  }

  Future<void> taiWav2vec2() async {
    if (tienDoWav2vec2 != null) return;
    tienDoWav2vec2 = const WorkProgress('Đang chuẩn bị wav2vec2…');
    notifyListeners();
    try {
      await tts.kiemAm.kho.tai(tienDo: (p) {
        tienDoWav2vec2 = p;
        notifyListeners();
      });
      await tts.kiemAm.napLai();
      await xemWav2vec2();
    } finally {
      tienDoWav2vec2 = null;
      notifyListeners();
    }
  }


  Future<void> refreshMatchaStatus() async {
    matchaInstalled = await tts.modelStore.isMatchaInstalled();
    notifyListeners();
  }

  /// Tải bộ file của engine Matcha (gói nén khoảng 59 MB).
  Future<void> downloadMatchaModel() async {
    if (modelProgress != null) return;
    modelProgress = const WorkProgress('Đang chuẩn bị…');
    notifyListeners();
    try {
      await tts.modelStore.downloadMatcha(onProgress: (p) {
        modelProgress = p;
        notifyListeners();
      });
      matchaInstalled = true;
      tts.matcha.unawaitedStart();
      await refreshEngine();
    } finally {
      modelProgress = null;
      notifyListeners();
    }
  }

  Future<void> deleteMatchaModel() async {
    tts.matcha.dispose();
    await tts.modelStore.deleteMatcha();
    await refreshMatchaStatus();
    await refreshEngine();
  }

  /// Tải mô hình về máy. Khoảng 145 MB, chỉ làm một lần.
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
        // Hai trang chọn giọng riêng nên phải kiểm cả hai.
        var doi = false;
        if (voices.isNotEmpty && !voices.any((v) => v.id == settings.voiceNghe)) {
          settings.voiceNghe = voices.first.id;
          doi = true;
        }
        if (voices.isNotEmpty && !voices.any((v) => v.id == settings.voiceXuat)) {
          settings.voiceXuat = voices.first.id;
          doi = true;
        }
        if (doi) await saveSettings();
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
    await _khongCoViecXuatDo(book);
    await _chuoiLuu.catchError((Object _) {}); // đọc nhanvat.json SAU khi mọi lượt ghi đã xong
    importLabel = label;
    _setImportProgress(const WorkProgress('Đang mở file gốc…'));
    try {
      final nv = await library.docNhanVat(book.id);
      final dangNghe = currentBook?.id == book.id && player.isPlaying;
      final result = await library.rebuild(
        book.id,
        expandNumbers: settings.expandNumbers,
        // Sách ĐÃ CÓ phân tích nhân vật (dù đang tắt nhiều giọng) luôn cắt bằng cài đặt dọn quảng cáo
        // của lần phân tích: nhãn người nói gắn theo (chương, đoạn văn) của cách dọn ấy, và cả số
        // chương của đoạn đang nghe cũng phải cùng hệ để lần phân tích kế không nhầm chương.
        removeBoilerplate: nv != null ? (nv.donRac ?? settings.removeBoilerplate) : settings.removeBoilerplate,
        onProgress: _setImportProgress,
      );
      if (currentBook?.id == book.id) {
        currentBook = result.book;
        await player.open(result.book, settings);
        nhanVat = nv;
        _capNhatNhanVatChoTrinhPhat();
        // `open` dừng phát; đang nghe dở thì nghe tiếp từ chỗ đã giữ lại.
        if (dangNghe) unawaited(player.togglePlay());
      }
      await reloadBooks();
      return result;
    } finally {
      importProgress = null;
      importLabel = '';
      notifyListeners();
    }
  }

  // -- nhân vật và giọng theo nhân vật --------------------------------------

  /// Laya (mô hình chọn người nói) đã có trên máy chưa.
  bool get coLaya => tts.modelStore.daCoLaya;

  void _capNhatNhanVatChoTrinhPhat() {
    player.datNhanVat(nhanVat, () => {for (final v in voices) v.id});
  }

  /// Chỉ số chương của đoạn đang nghe (cùng hệ chỉ số với `Chunk.chapter`).
  int get chuongHienTai {
    final cs = player.chunks;
    if (cs.isEmpty) return 0;
    return cs[player.index.clamp(0, cs.length - 1)].chapter;
  }

  // Đoạn văn của cả sách chỉ đọc lại từ file gốc khi chưa có trong bộ nhớ: mỗi lần phân tích một
  // chương mà đọc và tách lại cả cuốn thì vài giây mỗi lần là phí.
  String? _doanVanSachId;
  bool? _doanVanDonRac;
  DoanVanSach? _doanVanSach;

  /// Các lượt ghi nhanvat.json xếp hàng nối đuôi nhau. `Storage.writeJsonText` ghi qua MỘT file tạm
  /// chung rồi xoá-đổi-tên không nguyên tử, nên hai lượt ghi chồng nhau (nút "Tự chọn giọng" bắn
  /// cả chục lượt một lúc) đè lên nhau và có thể để lại file thiếu, hoặc mất luôn. Hàng đợi này giữ
  /// đúng một lượt ghi tại một thời điểm; mỗi lượt mã hoá trạng thái MỚI NHẤT lúc nó thật sự chạy.
  Future<void> _chuoiLuu = Future<void>.value();

  Future<void> _ghiNhanVat(String bookId, NhanVatSach nv) {
    _chuoiLuu = _chuoiLuu.catchError((Object _) {}).then((_) => library.luuNhanVat(bookId, nv));
    return _chuoiLuu;
  }

  /// Cắt lại sách làm ĐỔI số thứ tự các đoạn, mà việc xuất file lưu vị trí bằng số thứ tự đoạn
  /// tuyệt đối (`fromChunk`/`toChunk`/`cursor`) và không dịch lại được. Có việc xuất dở cho sách này
  /// thì chạy tiếp sẽ ghi lại những đoạn đã xuất và dừng sớm một đoạn bằng số đoạn thêm vào.
  Future<void> _khongCoViecXuatDo(Book book) async {
    jobs = await exports.listJobs();
    final dang = jobs.any((j) => j.bookId == book.id && (j.isActive || j.status == JobStatus.paused));
    if (dang) {
      throw StateError('Sách này còn việc xuất file đang dở. Cắt lại sách làm đổi số thứ tự các đoạn '
          'nên việc xuất sẽ lệch — hoàn tất hoặc huỷ việc xuất trước.');
    }
  }

  Future<DoanVanSach> _doanVanCuaSach(Book book, bool donRac) async {
    if (_doanVanSach == null || _doanVanSachId != book.id || _doanVanDonRac != donRac) {
      _doanVanSach = await library.doanVanCuaSach(book.id, removeBoilerplate: donRac);
      _doanVanSachId = book.id;
      _doanVanDonRac = donRac;
    }
    return _doanVanSach!;
  }

  /// Phân tích nhân vật của MỘT chương (mặc định chương đang nghe) bằng Laya rồi gộp vào danh bạ
  /// nhân vật của sách.
  ///
  /// Chỉ một chương vì hỏi Laya từng câu thoại (~0,1 giây mỗi câu) cho cả cuốn dày mất hàng chục
  /// phút. Nhân vật đã gặp ở chương trước GIỮ NGUYÊN giọng và giới tính khi gặp lại, nên mỗi chương
  /// kế chỉ cần xử lý những người mới. Đang đọc nhiều giọng thì áp dụng luôn (cắt lại sách).
  Future<void> phanTichNhanVat(Book book, {int? chuong}) async {
    if (!coLaya) {
      throw StateError('Chưa có mô hình Laya. Đặt laya.onnx, tokenizer.json và '
          'rl_agent_config.json vào ${tts.modelStore.layaDir.path}');
    }
    final c = chuong ?? chuongHienTai;
    nhanVatTienDo = const WorkProgress('Đang đọc sách…', value: 0);
    notifyListeners();
    try {
      final cu = await library.docNhanVat(book.id);
      // Nhãn đã lưu gắn theo chỉ số (chương, đoạn văn) của lần dọn quảng cáo lúc phân tích; chương
      // mới PHẢI dùng cùng cài đặt ấy, không thì nhãn cũ và mới thuộc hai cách đánh số khác nhau.
      final donRac = cu?.donRac ?? settings.removeBoilerplate;
      final sach = await _doanVanCuaSach(book, donRac);
      final doanVan = sach.doanVan;
      if (c < 0 || c >= doanVan.length) throw StateError('Sách không có chương số ${c + 1}');
      // Số chương của đoạn đang nghe (`Chunk.chapter`) và số chương của đoạn văn đưa cho Laya đến từ
      // hai lần dọn quảng cáo có thể khác cài đặt. Đối chiếu tiêu đề: lệch thì dừng chứ không phân
      // tích nhầm chương rồi đánh dấu là xong.
      final chuongCuaSach = book.chapters.where((x) => x.index == c).firstOrNull;
      if (chuongCuaSach != null &&
          sach.tieuDe[c].trim().isNotEmpty &&
          chuongCuaSach.title.trim() != sach.tieuDe[c].trim()) {
        throw StateError('Số thứ tự chương của sách không còn khớp với lúc phân tích (cài đặt dọn quảng '
            'cáo đã đổi). Bấm "Dọn lại" trong thư viện rồi phân tích lại.');
      }
      final kq = await phanTichTrongNen(
        doanVan: doanVan,
        thuMucLaya: tts.modelStore.layaDir.path,
        chuong: {c},
        gioiDaBiet: {for (final n in cu?.nhanVat ?? const <NhanVat>[]) n.ten: n.gioi},
        tienDo: (xong, tong) {
          nhanVatTienDo = WorkProgress('Đang phân tích chương ${c + 1} ($xong/$tong câu thoại)',
              value: tong == 0 ? 1.0 : xong / tong);
          notifyListeners();
        },
      );
      // Hợp vào bản ĐANG MỞ (nếu có) chứ không phải bản `cu` đọc từ đĩa trước khi chạy: trong lúc phân
      // tích (nửa phút đến vài phút) người dùng vẫn chọn giọng, và hợp vào bản cũ rồi ghi đè là mất
      // hết những lựa chọn ấy.
      final nv = (currentBook?.id == book.id ? nhanVat : null) ?? cu ?? NhanVatSach(donRac: donRac);
      nv.hopNhatChuong(kq, {c});
      tuChonGiongChoNguoiMoi(nv);
      await _ghiNhanVat(book.id, nv);
      if (currentBook?.id == book.id) {
        nhanVat = nv;
        _capNhatNhanVatChoTrinhPhat();
      }
      // KHÔNG cắt lại sách: mỗi lời nói đã là một đoạn riêng từ lúc nhập, trình phát tra người nói
      // của từng đoạn từ nhãn vừa lưu.
    } finally {
      nhanVatTienDo = null;
      notifyListeners();
    }
  }

  /// Tự chọn giọng cho nhân vật CHƯA có giọng: cùng giới tính, tránh giọng người dẫn và giọng đã
  /// dùng cho người khác (hết giọng chưa dùng thì mới lặp lại). Người nghe chỉ chỉnh khi muốn đổi.
  /// Nhân vật đã có giọng (kể cả do người dùng chọn) giữ nguyên.
  void tuChonGiongChoNguoiMoi(NhanVatSach nv) {
    final daDung = {settings.voiceNghe, for (final n in nv.nhanVat) if (n.giong.isNotEmpty) n.giong};
    for (final n in nv.nhanVat) {
      if (n.giong.isNotEmpty) continue;
      final hop = voices.where((v) => giongHopGioi(v, n.gioi)).toList();
      final ung = hop.where((v) => !daDung.contains(v.id)).firstOrNull ?? hop.firstOrNull;
      if (ung == null) continue;
      daDung.add(ung.id);
      n.giong = ung.id;
    }
  }

  Future<void> _luuNhanVat() async {
    final b = currentBook, nv = nhanVat;
    if (b == null || nv == null) return;
    _capNhatNhanVatChoTrinhPhat();
    notifyListeners();
    await _ghiNhanVat(b.id, nv);
  }

  /// Chọn giọng cho NHIỀU nhân vật một lượt ([giongTheoTen]: tên -> mã giọng) và ghi file đúng một
  /// lần. Gọi [datGiongNhanVat] trong vòng lặp thì bắn cả chục lượt ghi chồng nhau.
  Future<void> datGiongNhieuNhanVat(Map<String, String> giongTheoTen) async {
    final nv = nhanVat;
    if (nv == null) return;
    for (final e in giongTheoTen.entries) {
      nv.tim(e.key)?.giong = e.value;
    }
    await _luuNhanVat();
  }

  /// Chọn giọng cho một nhân vật; [giong] rỗng là bỏ chọn (về giọng mặc định).
  Future<void> datGiongNhanVat(String ten, String giong) async {
    final n = nhanVat?.tim(ten);
    if (n == null) return;
    n.giong = giong;
    await _luuNhanVat();
  }

  /// Sửa giới tính một nhân vật ('nam' hoặc 'nu'). Laya đoán giới tính nhân vật nữ kém (khoảng
  /// một nửa), nên giao diện cho sửa tay.
  Future<void> datGioiNhanVat(String ten, String gioi) async {
    final n = nhanVat?.tim(ten);
    if (n == null) return;
    n.gioi = gioi;
    await _luuNhanVat();
  }

  /// Bật hoặc tắt đọc nhiều giọng: chỉ đổi GIỌNG, không cắt lại sách — mỗi lời nói đã là một đoạn
  /// riêng từ lúc nhập. Tắt thì mọi đoạn đọc bằng giọng người dẫn.
  ///
  /// Ngoại lệ một lần: sách nhập trước khi có luật tách lời nói ([Book.catThoai] false) thì cắt lại
  /// MỘT lần lúc bật, để có đoạn riêng cho từng lời nói. Từ đó về sau bật/tắt không cắt gì nữa.
  Future<void> batNhieuGiong(Book book, bool bat) async {
    final nv = nhanVat;
    if (nv == null || nv.bat == bat) return;
    if (bat && !book.catThoai) {
      await rebuildBook(book, label: 'Tách lời nói thành đoạn riêng');
    }
    nv.bat = bat;
    await _ghiNhanVat(book.id, nv);
    _capNhatNhanVatChoTrinhPhat();
    notifyListeners();
  }

  Future<void> openBook(Book book) async {
    currentBook = book;
    nhanVat = await library.docNhanVat(book.id);
    _capNhatNhanVatChoTrinhPhat();
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

  Future<void> setVoiceNghe(String voiceId) async {
    settings.voiceNghe = voiceId;
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

    // Android: thư mục người dùng chọn cũng phải kiểm — quyền có thể đã bị rút
    // trong Cài đặt của máy, hoặc mất sau khi cài lại app.
    final cay = settings.exportTreeUri;
    if (cay.isNotEmpty && !await conQuyenThuMuc(cay)) {
      throw const ExportDirException(
        'Không còn quyền ghi vào thư mục đã chọn. Bấm "Đổi thư mục" để chọn lại.',
      );
    }

    final voiceName =
        voices.where((v) => v.id == settings.voiceXuat).map((v) => v.name).firstOrNull ??
            settings.voiceXuat;
    final job = await exports.createJob(
      book: book,
      settings: settings,
      voiceName: voiceName,
      outputDir: outputDir,
      treeUri: cay,
      fromChunk: fromChunk,
      toChunk: toChunk,
      giongNhanVat: _bangGiongNhanVat(book),
      nguoiNoi: _bangGiongNhanVat(book).isEmpty ? const {} : Map.of(nhanVat!.nguoiNoi),
    );
    await resumeExport(job);
    return job;
  }

  /// Bảng "nhân vật -> giọng" để chụp vào job xuất file. Chỉ khi sách đang bật nhiều giọng, và chỉ
  /// những giọng còn dùng được với engine hiện tại.
  Map<String, String> _bangGiongNhanVat(Book book) {
    final nv = nhanVat;
    if (nv == null || !nv.bat || currentBook?.id != book.id) return const {};
    final hopLe = {for (final v in voices) v.id};
    return {
      for (final n in nv.nhanVat)
        if (n.giong.isNotEmpty && hopLe.contains(n.giong)) n.ten: n.giong,
    };
  }

  Future<void> resumeExport(ExportJob job) async {
    if (!preparingJobs.add(job.id)) return;
    // Tạm dừng, đổi cách nối ngữ cảnh, rồi chạy tiếp — phần còn lại theo mức mới.
    job.nguCanh = settings.nguCanhXuat;
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
    unawaited(tts.kiemAm.dong());
    super.dispose();
  }
}
