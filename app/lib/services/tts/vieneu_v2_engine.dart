/// Engine VieNeu **v2** — Qwen3 0,3B chạy qua llama.cpp, NeuCodec dựng sóng.
///
/// Đứng cạnh [OnDeviceVieNeuEngine] (v3 Turbo) chứ không thay nó. Hai bản mạnh
/// yếu khác nhau và người dùng chọn trong Cài đặt:
///
/// - **v3 Turbo** chở gấp 2,5 lần thông tin âm cho mỗi giây tiếng (16 codebook ở
///   12,5 khung/giây, ra 48 kHz) nên trần độ trung thực cao hơn.
/// - **v2** gấp ba tham số và biết chuyển giữa tiếng Việt với tiếng Anh, nên
///   ngắt nghỉ và tên riêng nước ngoài thường tự nhiên hơn. Đo trên máy 12 nhân:
///   3,05× thời gian thực, nhỉnh hơn cả v3 (2,87×) dù mô hình to gấp ba — vì
///   trọng số Q4 chỉ 189 MB nên đọc bộ nhớ ít hơn.
///
/// Chưa nhân bản được giọng: việc đó cần bộ MÃ HOÁ của NeuCodec, mà repo công
/// khai chỉ có bộ giải mã. Bảy giọng dựng sẵn thì dùng được ngay vì mã tham
/// chiếu của chúng nằm sẵn trong voices.json.
library;

import 'dart:io';
import 'dart:typed_data';

import '../../core/wav.dart';
import 'model_store.dart';
import 'tts_engine.dart';
import 'vieneu_engine.dart';
import 'vieneu_v2_native.dart';

class VieNeuV2Engine implements TtsEngine {
  VieNeuV2Engine(this._store);

  final ModelStore _store;
  VieNeuV2Native? _native;
  String? _error;
  bool _starting = false;

  /// Các bản sao mô hình dùng thêm lúc xuất file. Mỗi bản một isolate riêng.
  final List<VieNeuV2Native> _extra = [];

  /// Số đoạn đang chạy ở từng worker, để đưa đoạn mới cho worker rảnh nhất.
  final Map<VieNeuV2Native, int> _busy = {};
  bool _bulk = false;
  Future<void>? _resizing;

  @override
  String get id => 'vieneu_v2';

  @override
  String get displayName => 'VieNeu-TTS v2';

  @override
  bool get isLocal => true;

  @override
  String get description =>
      'Mô hình lớn hơn v3 Turbo, đọc tự nhiên hơn và biết cả tiếng Anh xen kẽ. '
      'Âm thanh 24 kHz, tải nặng hơn.';

  /// Mô hình có lấy mẫu ngẫu nhiên nên đọc lại ra bản khác — bộ soi âm lúc xuất
  /// file dùng được cửa đọc lại này. Đo thực tế: khoảng một phần tư số lần đọc
  /// bị vọt dài gấp mấy lần (mô hình không chịu dừng), mà đổi hạt giống là hết —
  /// nên cửa đọc lại không phải phòng xa mà là cần thật.
  @override
  bool get docLaiRaKhac => true;

  /// v2 bám giọng bằng mã tham chiếu cố định của giọng, không nối đuôi đoạn
  /// trước — nhờ vậy các đoạn độc lập nhau và đọc trước song song được.
  @override
  bool get noiNguCanh => false;

  @override
  Future<EngineStatus> status() async {
    if (_native != null) {
      return const EngineStatus(ready: true, message: 'Sẵn sàng');
    }
    if (_error != null) {
      return EngineStatus(ready: false, message: _error!);
    }
    if (!await _store.isV2Installed()) {
      return EngineStatus(
        ready: false,
        message: 'Chưa tải mô hình v2 (${v2Megabytes.round()} MB) — vào Cài đặt để tải',
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
      _native = await VieNeuV2Native.start(await _store.v2Paths(threads: _soLuong()));
      _error = null;
    } catch (err) {
      _error = '$err';
    }
  }

  /// Số luồng cho llama.cpp.
  ///
  /// Một nửa số nhân: quá nửa thì các luồng tranh nhau băng thông bộ nhớ mà
  /// không nhanh thêm — vòng lặp sinh từng token bị chặn ở chỗ ĐỌC trọng số chứ
  /// không phải ở chỗ tính. Đo trên máy 12 nhân với 6 luồng: 3,05× thời gian
  /// thực.
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

    final paths = await _store.v2Paths(threads: _soLuongMoiWorker);
    for (var i = _extra.length; i < can; i++) {
      try {
        _extra.add(await VieNeuV2Native.start(paths));
      } catch (_) {
        // Hết RAM hay lỗi nạp: chạy với số worker đang có, chậm hơn chứ không hỏng.
        break;
      }
      if (!_bulk) break; // xuất file vừa xong giữa chừng
    }
  }

  /// Số worker chạy song song lúc xuất file. Chặn ở **2**, không phải 3 như v3.
  ///
  /// Đo trên máy 24 nhân, đoạn 250 ký tự — đường cong phẳng gần như ngay lập tức:
  ///
  /// | worker | thông lượng | RAM đỉnh |
  /// |---|---|---|
  /// | 1 | 2,83× | 816 MB |
  /// | 2 | **3,57×** | 1.541 MB |
  /// | 3 | 3,86× | 2.321 MB |
  /// | 4 | 4,12× | 3.049 MB |
  ///
  /// Worker thứ hai đáng giá (+26%), thứ ba thì không (+8% cho thêm 780 MB).
  /// Lý do nằm ở chính chỗ khiến v2 nhanh: sinh token là bài toán ĐỌC bộ nhớ,
  /// nên các worker giành nhau đúng một băng thông. Khác hẳn v3 qua ONNX (1
  /// worker 2,87× → 3 worker 6,85×) vì bên đó nặng phần tính hơn.
  ///
  /// Đừng tin lời hứa "mmap nên worker phụ gần như miễn phí" — đo thật thì mỗi
  /// worker tốn ~750 MB.
  static int get _soWorker {
    if (Platform.isAndroid || Platform.isIOS) return 1;
    final theoNhan = (Platform.numberOfProcessors ~/ 4).clamp(1, 2);
    final ram = OnDeviceVieNeuEngine.tongRamGb();
    if (ram == null) return 1; // không biết RAM thì dè dặt
    // Mỗi worker ~750 MB; chỉ mở bản thứ hai khi máy có từ 8 GB trở lên.
    return ram >= 8 ? theoNhan : 1;
  }

  /// Số luồng cho MỖI worker lúc chạy song song.
  ///
  /// Chia đều số nhân cho các worker: để nguyên nửa số nhân như lúc nghe thì hai
  /// worker đòi trọn số nhân của máy, và chúng giành nhau làm chậm cả lượt.
  static int get _soLuongMoiWorker =>
      (Platform.numberOfProcessors ~/ (2 * _soWorker)).clamp(1, 8);

  @override
  void huyDangDoc() => VieNeuV2Native.huyToi(VieNeuV2Native.maHienTai);

  /// Worker đang rảnh nhất. Lúc nghe chỉ có một nên hàm này trả về luôn nó.
  VieNeuV2Native _leastBusy(VieNeuV2Native primary) {
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

  Future<VieNeuV2Native> _ensure() async {
    if (_native != null) return _native!;
    if (!await _store.isV2Installed()) {
      throw TtsException('Chưa tải mô hình v2 (${v2Megabytes.round()} MB)');
    }
    _starting = true;
    try {
      await _start();
    } finally {
      _starting = false;
    }
    final native = _native;
    if (native == null) throw TtsException(_error ?? 'Không nạp được mô hình v2');
    return native;
  }

  @override
  Future<List<TtsVoice>> voices() async {
    final native = await _ensure();
    return native.voices
        .map((v) => TtsVoice(
              id: v.name,
              name: v.name,
              // voices.json của v2 không tách riêng giới tính; mô tả đã ghi sẵn
              // kiểu "Thanh Bình (nam miền Bắc)" nên để nguyên cho người đọc.
              gender: '',
              description: v.description,
              builtIn: !v.tuThem,
            ))
        .toList();
  }

  /// Nhân bản một giọng từ file ghi âm **kèm lời của chính đoạn ấy**.
  ///
  /// [text] phải khớp với những gì nghe thấy trong [wavPath]. Đây là khác biệt
  /// lớn nhất so với v3: v3 trích vector đặc trưng người nói từ riêng sóng âm
  /// nên không cần lời, còn v2 nhận cặp *mã tham chiếu + lời tương ứng* — lời
  /// sai thì mô hình học nhầm cách phát âm.
  Future<void> addVoice({
    required String name,
    required String wavPath,
    required String text,
  }) async {
    final native = await _ensure();
    await native.addVoice(
      name: name,
      wavPath: wavPath,
      text: text,
      encoderPath: _store.v2Encoder.path,
      userVoicesPath: _store.v2UserVoices.path,
    );
  }

  Future<void> removeVoice(String name) async {
    final native = await _ensure();
    await native.removeVoice(name, _store.v2UserVoices.path);
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

    // Hạt giống suy từ nội dung, cùng lý do như v3: cùng một đoạn phải cho cùng
    // kết quả, không thì bộ nhớ đệm vô nghĩa. [nguCanh] bỏ qua — v2 bám giọng
    // bằng mã tham chiếu của chính giọng ấy chứ không bằng đuôi đoạn trước.
    final seed = _seedOf('$voiceId|$text${lanThu == 0 ? '' : '|lần $lanThu'}');

    // Đưa cho worker đang rảnh nhất. Lúc nghe chỉ có một nên trả về chính nó.
    final worker = _leastBusy(native);
    _busy[worker] = (_busy[worker] ?? 0) + 1;
    final Float32List raw;
    try {
      raw = await worker.synthesize(
        text,
        voiceId,
        seed: seed,
        ma: VieNeuV2Native.maMoi(),
      );
    } finally {
      final con = (_busy[worker] ?? 1) - 1;
      if (con <= 0) {
        _busy.remove(worker);
      } else {
        _busy[worker] = con;
      }
    }

    var samples = raw;
    if (samples.isEmpty) {
      throw TtsException('Mô hình v2 không đọc ra âm thanh nào');
    }

    if ((speed - 1.0).abs() > 0.01) {
      samples = _resample(samples, speed);
    }
    samples = normalizePeak(samples);

    final wav = buildWav(samples, native.sampleRate);
    return TtsResult(wav, samples.length / native.sampleRate);
  }

  /// Đổi tốc độ bằng cách lấy mẫu lại — cao độ đổi theo, chỉ dùng lúc xuất file.
  /// Lúc nghe thì trình phát tự chỉnh tốc độ, không đụng tới đây.
  Float32List _resample(Float32List input, double speed) {
    final out = Float32List((input.length / speed).round());
    for (var i = 0; i < out.length; i++) {
      final at = i * speed;
      final a = at.floor();
      final b = (a + 1).clamp(0, input.length - 1);
      final t = at - a;
      if (a >= input.length) break;
      out[i] = input[a] * (1 - t) + input[b] * t;
    }
    return out;
  }

  int _seedOf(String key) {
    // FNV-1a 64 bit, giống v3 — rẻ và ổn định giữa các lần chạy.
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
