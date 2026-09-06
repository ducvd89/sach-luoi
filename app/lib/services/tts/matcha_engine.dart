/// Engine **Matcha-TTS** — khớp dòng chảy (flow matching) + Vocos, chạy ONNX.
///
/// Đứng cạnh hai bản VieNeu chứ không thay bản nào. Chỗ nó thắng là **tốc độ và
/// dung lượng**, chỗ nó thua là giọng:
///
/// | | Matcha | VieNeu v3 Turbo | VieNeu v2 |
/// |---|---|---|---|
/// | Tải về | **59 MB** | 145 MB | 478 MB |
/// | Thông lượng, 1 worker | **19,4×** thời gian thực | 2,87× | 2,83× |
/// | Tần số | 22 050 Hz | 48 kHz | 24 kHz |
/// | Số giọng | **1, cố định** | 9 | 9 |
/// | Nhân bản giọng | không | có | có |
///
/// Đo trên cùng máy 24 nhân, cùng đoạn 261 ký tự. Nhanh hơn gần bảy lần với bộ
/// mô hình nhẹ hơn một nửa — vì nó **không sinh token**: bộ đoán độ dài trải cả
/// đoạn ra một lượt rồi giải ODE đúng 10 bước trên toàn bộ khung, chứ không
/// chạy vòng lặp từng khung một như hai engine kia.
///
/// Cái mất là giọng: mô hình một người nói, không có hồ sơ giọng nào để chọn và
/// không nhân bản được. Ai cần đổi giọng thì vẫn phải dùng VieNeu.
library;

import 'dart:io';
import 'dart:typed_data';

import '../../core/text_normalizer.dart';
import '../../core/wav.dart';
import 'matcha_native.dart';
import 'model_store.dart';
import 'tts_engine.dart';
import 'vieneu_engine.dart';

/// Mã giọng duy nhất của engine. Nằm trong khoá bộ nhớ đệm nên **đừng đổi** —
/// đổi là mọi đoạn đã đọc phải tổng hợp lại.
const matchaVoiceId = 'mac-dinh';

class MatchaEngine implements TtsEngine {
  MatchaEngine(this._store);

  final ModelStore _store;
  MatchaNative? _native;
  String? _error;
  bool _starting = false;

  /// Các bản sao mô hình dùng thêm lúc xuất file. Mỗi bản một isolate riêng.
  final List<MatchaNative> _extra = [];

  /// Số đoạn đang chạy ở từng worker, để đưa đoạn mới cho worker rảnh nhất.
  final Map<MatchaNative, int> _busy = {};
  bool _bulk = false;
  Future<void>? _resizing;

  @override
  String get id => 'matcha';

  @override
  String get displayName => 'Matcha-TTS';

  @override
  bool get isLocal => true;

  @override
  String get description =>
      'Nhẹ nhất và nhanh nhất trong các mô hình chạy trên máy — tải 59 MB, đọc '
      'nhanh gấp gần bảy lần VieNeu. Chỉ có một giọng cố định.';

  /// Các đoạn độc lập nhau: mô hình một người nói, không có mã tham chiếu hay
  /// đuôi ngữ cảnh nào để nối. Đo trên 8 đoạn liền nhau, lệch chuẩn cao độ giữa
  /// các đoạn là 4,13 Hz — ngang mức VieNeu đạt được KHI ĐÃ nối (4,8 Hz) — nên
  /// không có gì để mà nối thêm. Xem ghi chú dài trong `native/vieneu/src/matcha.rs`.
  @override
  bool get noiNguCanh => false;

  /// **Đọc lại không giúp gì**, khác hẳn hai bản VieNeu.
  ///
  /// Đổi hạt giống chỉ đổi nhiễu khởi tạo của bộ giải ODE; độ dài đoạn do bộ
  /// đoán độ dài quyết định và nó tất định. Đo trên cùng một câu với năm hạt
  /// giống khác nhau: thời lượng **giống hệt nhau tới từng mẫu** (6,478 s),
  /// sóng chỉ lệch trung bình 0,04.
  ///
  /// Nghĩa là bộ soi âm (`core/kiem_am.dart`) đếm ra đúng chừng ấy nhân âm ở
  /// mọi lần đọc lại: nếu lần đầu bị coi là hỏng thì bốn lần sau cũng hỏng y
  /// hệt, chỉ tốn thêm thời gian. Bật cờ này lên là tự chuốc lấy đúng cái vòng
  /// lặp vô ích ấy.
  @override
  bool get docLaiRaKhac => false;

  @override
  Future<EngineStatus> status() async {
    if (_native != null) {
      return const EngineStatus(ready: true, message: 'Sẵn sàng');
    }
    if (_error != null) {
      return EngineStatus(ready: false, message: _error!);
    }
    if (!await _store.isMatchaInstalled()) {
      return EngineStatus(
        ready: false,
        message: 'Chưa tải mô hình Matcha (${matchaMegabytes.round()} MB) — vào Cài đặt để tải',
      );
    }
    if (_starting) {
      return const EngineStatus(ready: false, loading: true, message: 'Đang nạp mô hình…');
    }
    unawaitedStart();
    return const EngineStatus(ready: false, loading: true, message: 'Đang nạp mô hình…');
  }

  void unawaitedStart() {
    if (_native != null || _starting) return;
    _starting = true;
    _start().whenComplete(() => _starting = false);
  }

  Future<void> _start() async {
    try {
      _native = await MatchaNative.start(await _store.matchaPaths(threads: _soLuong()));
      _error = null;
    } catch (err) {
      _error = '$err';
    }
  }

  /// Số luồng cho một worker lúc nghe.
  ///
  /// Một nửa số nhân, chặn ở 8. Đo trên máy 24 nhân, đoạn 261 ký tự: 1 luồng
  /// 8,71×, 4 luồng 10,78×, 8 luồng 15,16× thời gian thực. Đường cong còn lên
  /// nhưng lúc nghe chỉ cần vượt 1× là đủ — thừa xa rồi, nên không việc gì phải
  /// chiếm hết máy của người dùng.
  int _soLuong() => (Platform.numberOfProcessors ~/ 2).clamp(1, 8);

  /// Mở thêm hoặc đóng bớt worker khi xuất file.
  ///
  /// Nối vào [_resizing] để hai lần bật/tắt liên tiếp không cùng lúc mở mô hình.
  @override
  Future<void> setBulkMode(bool on) {
    if (on == _bulk) return _resizing ?? Future.value();
    _bulk = on;
    final truoc = _resizing ?? Future.value();
    return _resizing = truoc.then((_) => _applyBulk()).catchError((Object _) {});
  }

  Future<void> _applyBulk() async {
    if (!_bulk) {
      final dong = [..._extra];
      _extra.clear();
      for (final w in dong) {
        _busy.remove(w);
        w.close();
      }
      return;
    }
    if (_native == null) return; // chưa nạp xong thì thôi, lần sau sẽ mở
    final can = _soWorker - 1; // worker chính đã có sẵn
    if (can <= 0) return;

    final paths = await _store.matchaPaths(threads: _soLuongMoiWorker);
    for (var i = _extra.length; i < can; i++) {
      try {
        _extra.add(await MatchaNative.start(paths));
      } catch (_) {
        // Hết RAM hay lỗi nạp: chạy với số worker đang có, chậm hơn chứ không hỏng.
        break;
      }
      if (!_bulk) break; // xuất file vừa xong giữa chừng
    }
  }

  /// Số worker chạy song song lúc xuất file. Chặn ở **2**.
  ///
  /// Đo trên máy 24 nhân, đoạn 261 ký tự, mỗi worker chia đều số nhân:
  ///
  /// | worker | thông lượng |
  /// |---|---|
  /// | 1 | 19,43× |
  /// | 2 | **25,02×** |
  /// | 3 | 28,49× |
  /// | 4 | 32,23× |
  ///
  /// Đường cong vẫn lên nhưng phần thêm ngày càng mỏng (+29%, rồi +14%, rồi
  /// +13%) trong khi mỗi worker tốn khoảng 270 MB — mô hình thường trú 95 MB
  /// cộng bộ đệm lúc chạy. Ở mức 25× thời gian thực thì cuốn sách 10 giờ xuất
  /// xong trong 24 phút; mua thêm 3 phút bằng 270 MB nữa là không đáng.
  ///
  /// Khác v3 (chặn 3) vì nền khác hẳn: v3 xuất phát từ 2,87× nên mỗi worker
  /// thêm vào còn cứu được thời gian thật.
  static int get _soWorker {
    if (Platform.isAndroid || Platform.isIOS) return 1;
    final theoNhan = (Platform.numberOfProcessors ~/ 4).clamp(1, 2);
    final ram = OnDeviceVieNeuEngine.tongRamGb();
    if (ram == null) return 1; // không biết RAM thì dè dặt
    // Mỗi worker ~270 MB; nhẹ hơn nhiều so với v2 nên 4 GB là đủ mở bản thứ hai.
    return ram >= 4 ? theoNhan : 1;
  }

  /// Số luồng cho MỖI worker lúc chạy song song — chia đều số nhân, cùng lý do
  /// như engine v2: để nguyên nửa số nhân thì hai worker đòi trọn máy rồi giành
  /// nhau.
  static int get _soLuongMoiWorker =>
      (Platform.numberOfProcessors ~/ (2 * _soWorker)).clamp(1, 8);

  @override
  void huyDangDoc() => MatchaNative.huyToi(MatchaNative.maHienTai);

  /// Worker đang rảnh nhất. Lúc nghe chỉ có một nên hàm này trả về luôn nó.
  MatchaNative _leastBusy(MatchaNative primary) {
    var chon = primary;
    var it = _busy[primary] ?? 0;
    for (final w in _extra) {
      final n = _busy[w] ?? 0;
      if (n < it) {
        chon = w;
        it = n;
      }
    }
    return chon;
  }

  Future<MatchaNative> _ensure() async {
    if (_native != null) return _native!;
    if (!await _store.isMatchaInstalled()) {
      throw TtsException('Chưa tải mô hình Matcha (${matchaMegabytes.round()} MB)');
    }
    _starting = true;
    try {
      await _start();
    } finally {
      _starting = false;
    }
    final native = _native;
    if (native == null) throw TtsException(_error ?? 'Không nạp được mô hình Matcha');
    return native;
  }

  /// Đúng một giọng, không đọc từ file nào cả.
  ///
  /// Mô hình một người nói: không có `voices.json` để mà tra, và cũng không có
  /// gì cho người dùng chọn. Trả một mục để màn hình Nghe và Xuất file vẫn có
  /// thứ hiển thị thay vì rơi vào nhánh "chưa có giọng nào".
  @override
  Future<List<TtsVoice>> voices() async {
    await _ensure();
    return const [
      TtsVoice(
        id: matchaVoiceId,
        name: 'Giọng Matcha',
        gender: 'Nữ',
        description: 'Giọng duy nhất của mô hình — không đổi và không thêm được',
      ),
    ];
  }

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
    List<int>? nguCanh,
    int lanThu = 0,
  }) async {
    final native = await _ensure();

    // Thẻ `<en>` là quy ước riêng của sea-g2p, mà Matcha đọc thẳng mặt chữ nên
    // không có ai bóc nó ra: để nguyên thì mô hình đọc thành tiếng "en" ngay
    // trước mỗi từ ngoại lai.
    final doc = boTheEn(text);

    // Hạt giống suy từ nội dung, cùng lý do như hai engine kia: cùng một đoạn
    // phải cho cùng kết quả, không thì bộ nhớ đệm vô nghĩa. [nguCanh] và
    // [lanThu] bỏ qua — engine không nối ngữ cảnh, và đọc lại ra đúng độ dài cũ
    // nên không có gì để đổi (xem [docLaiRaKhac]).
    final seed = _seedOf('$voiceId|$doc');

    // Đưa cho worker đang rảnh nhất. Lúc nghe chỉ có một nên trả về chính nó.
    final worker = _leastBusy(native);
    _busy[worker] = (_busy[worker] ?? 0) + 1;
    final Float32List raw;
    try {
      raw = await worker.synthesize(
        doc,
        // Tốc độ đi thẳng vào bộ đoán độ dài của mô hình chứ không lấy mẫu lại
        // như hai engine kia — nên **cao độ giữ nguyên** ở mọi tốc độ xuất file.
        // Lúc nghe thì speed luôn là 1.0: trình phát tự chỉnh nhịp phát.
        tocDo: speed,
        seed: seed,
        ma: MatchaNative.maMoi(),
      );
    } finally {
      final con = (_busy[worker] ?? 1) - 1;
      if (con <= 0) {
        _busy.remove(worker);
      } else {
        _busy[worker] = con;
      }
    }

    if (raw.isEmpty) {
      throw TtsException('Mô hình Matcha không đọc ra âm thanh nào');
    }

    final samples = normalizePeak(raw);
    final wav = buildWav(samples, native.sampleRate);
    return TtsResult(wav, samples.length / native.sampleRate);
  }

  int _seedOf(String key) {
    // FNV-1a 64 bit, giống hai engine kia — rẻ và ổn định giữa các lần chạy.
    var hash = 0xcbf29ce484222325;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    // Cổng C nhận u32 nên cắt xuống, vẫn đủ tản.
    return hash & 0xFFFFFFFF;
  }

  void dispose() {
    for (final w in _extra) {
      w.close();
    }
    _extra.clear();
    _busy.clear();
    _native?.close();
    _native = null;
  }
}
