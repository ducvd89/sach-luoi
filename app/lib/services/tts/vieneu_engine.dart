/// Engine VieNeu chạy thẳng trong ứng dụng — không Python, không mạng.
///
/// Đây là engine dùng trên điện thoại. Nó trả về mẫu âm thô nên ứng dụng đóng
/// gói thành WAV: nhúng bộ mã hoá MP3 vào Flutter còn nặng hơn cả mô hình.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/wav.dart';
import 'model_store.dart';
import 'tts_engine.dart';
import 'vieneu_native.dart';

class OnDeviceVieNeuEngine implements TtsEngine {
  OnDeviceVieNeuEngine(this._store);

  final ModelStore _store;
  VieNeuNative? _native;
  String? _error;
  bool _starting = false;

  /// Các bản sao mô hình dùng thêm lúc xuất file. Mỗi bản là một isolate với
  /// mô hình riêng, nên tổng hợp được nhiều đoạn cùng lúc.
  final List<VieNeuNative> _extra = [];

  /// Số đoạn đang chạy ở từng worker, để đưa đoạn mới cho worker rảnh nhất.
  final Map<VieNeuNative, int> _busy = {};
  bool _bulk = false;
  Future<void>? _resizing;

  /// Số worker chạy song song lúc xuất file.
  ///
  /// Chặn theo **cả số nhân lẫn RAM**, vì một bản mô hình tốn nhiều hơn tưởng.
  /// Đo thật: một mô hình đứng ở 575-815 MB tuỳ độ dài đoạn (bộ cấp phát arena
  /// của ONNX Runtime phình tới mức lớn nhất từng cần rồi giữ luôn, không trả
  /// lại). Bản đầu ghi "~250 MB" là sai gấp ba, và với 6 worker thì riêng phần
  /// nền đã 5 GB — máy 8 GB là hết đường thở.
  ///
  /// Tốc độ đo được: 1 worker 2,87× thời gian thực, 3 worker 6,85×, 6 worker
  /// 8,94×. Đường cong đã phẳng dần nên bớt worker mất ít tốc độ mà đổi lại
  /// nhiều RAM.
  static int get _bulkWorkers {
    if (Platform.isAndroid || Platform.isIOS) return 1;
    // Chặn ở 3, không phải 6. Mỗi worker cần chỗ cho đỉnh bộ nhớ của bộ giải mã
    // âm, mà đỉnh đó tỉ lệ bình phương độ dài đoạn (xem chunker.dart): khoảng
    // 1,6 GB cho đoạn 14 giây. Sáu worker là hơn 10 GB chỉ để xuất file.
    final theoNhan = (Platform.numberOfProcessors ~/ 4).clamp(1, 3);
    final ram = _tongRamGb();
    if (ram == null) return 2; // không biết RAM thì dè dặt
    // Dành tối đa một phần tư RAM máy, mỗi worker tính 2 GB.
    final theoRam = (ram ~/ 8).clamp(1, 3);
    return theoNhan < theoRam ? theoNhan : theoRam;
  }

  /// Tổng RAM máy, tính bằng GB. null nếu không hỏi được.
  static int? _tongRamGb() {
    if (!Platform.isWindows) return null;
    try {
      final kernel = DynamicLibrary.open('kernel32.dll');
      final hoi = kernel.lookupFunction<Int32 Function(Pointer<Uint64>),
          int Function(Pointer<Uint64>)>('GetPhysicallyInstalledSystemMemory');
      final ra = calloc<Uint64>();
      try {
        if (hoi(ra) == 0) return null;
        return (ra.value ~/ (1024 * 1024)).toInt(); // hàm trả về KB
      } finally {
        calloc.free(ra);
      }
    } catch (_) {
      return null;
    }
  }

  /// Mỗi worker chỉ 2 thread: 6×2 nhanh hơn 3×4 vì lấp kín được số nhân mà
  /// không để các luồng trong cùng một phiên phải chờ nhau.
  static const _bulkThreadsPerWorker = 2;

  @override
  String get id => 'vieneu';

  @override
  String get displayName => 'VieNeu-TTS';

  @override
  bool get isLocal => true;

  @override
  String get description =>
      'Mô hình chạy thẳng trên máy, không cần mạng. Đọc nhanh hơn tốc độ nghe.';

  /// Mô hình sinh ra mẫu âm thô; ứng dụng tự đóng gói WAV.
  @override
  String get audioFormat => 'wav';

  @override
  Future<EngineStatus> status() async {
    if (_native != null) {
      return const EngineStatus(ready: true, message: 'Sẵn sàng');
    }
    if (_error != null) {
      return EngineStatus(ready: false, message: _error!);
    }
    if (!await _store.isInstalled()) {
      return const EngineStatus(
        ready: false,
        message: 'Chưa tải mô hình — vào Cài đặt bấm "Tải mô hình"',
      );
    }
    if (_starting) {
      return const EngineStatus(ready: false, loading: true, message: 'Đang nạp mô hình…');
    }
    unawaitedStart();
    return const EngineStatus(ready: false, loading: true, message: 'Đang nạp mô hình…');
  }

  /// Bắt đầu nạp mô hình ở nền, không chờ.
  void unawaitedStart() {
    if (_native != null || _starting) return;
    _starting = true;
    _start().whenComplete(() => _starting = false);
  }

  Future<void> _start() async {
    try {
      _native = await VieNeuNative.start(await _store.paths());
      _error = null;
    } catch (err) {
      _error = '$err';
    }
  }

  Future<VieNeuNative> _ensure() async {
    if (_native != null) return _native!;
    if (!await _store.isInstalled()) {
      throw const TtsExceptionMissingModel();
    }
    _starting = true;
    try {
      await _start();
    } finally {
      _starting = false;
    }
    final native = _native;
    if (native == null) throw TtsException(_error ?? 'Không nạp được mô hình');
    return native;
  }

  /// Worker đang rảnh nhất. Lúc nghe chỉ có một nên hàm này trả về luôn nó.
  VieNeuNative _leastBusy(VieNeuNative primary) {
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

  /// Mở thêm hoặc đóng bớt worker.
  ///
  /// Nối vào [_resizing] để hai lần bật/tắt liên tiếp không cùng lúc mở mô hình
  /// — mỗi bản tốn 575-815 MB, mở nhầm gấp đôi là thấy ngay.
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
    final can = _bulkWorkers - 1; // worker chính đã có sẵn
    if (can <= 0) return;

    final paths = await _store.paths();
    for (var i = _extra.length; i < can; i++) {
      try {
        _extra.add(await VieNeuNative.start(VieNeuPaths(
          modelDir: paths.modelDir,
          codecDir: paths.codecDir,
          dictPath: paths.dictPath,
          voicesPath: paths.voicesPath,
          libraryPath: paths.libraryPath,
          threads: _bulkThreadsPerWorker,
        )));
      } catch (_) {
        // Hết RAM hay lỗi nạp: chạy với số worker đang có, chậm hơn chứ không hỏng.
        break;
      }
      if (!_bulk) break; // xuất file vừa xong giữa chừng
    }
  }

  @override
  Future<List<TtsVoice>> voices() async {
    final native = await _ensure();
    // Thư viện native chỉ trả về tên; phần mô tả (giới tính, vùng miền, phong
    // cách) đọc từ chính file hồ sơ để giao diện hiện đủ thông tin.
    final meta = await _store.voiceMeta();
    return native.voices.map((name) {
      final info = meta[name];
      return TtsVoice(
        id: name,
        name: name,
        gender: info?.gender ?? '',
        description: info?.description ?? '',
        builtIn: info?.builtIn ?? true,
      );
    }).toList();
  }

  /// Đổi hạt giống là ra bản đọc khác — đoạn đọc hỏng còn đường sửa.
  @override
  bool get docLaiRaKhac => true;

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
    List<int>? nguCanh,
    int lanThu = 0,
  }) async {
    final primary = await _ensure();
    final native = _leastBusy(primary);
    final voice = voiceId.isEmpty ? (native.voices.firstOrNull ?? '') : voiceId;
    if (voice.isEmpty) throw TtsException('Chưa có giọng nào trong mô hình');

    // Hạt giống cố định theo nội dung: cùng một đoạn phải luôn cho cùng kết quả,
    // nếu không bộ nhớ đệm của ứng dụng mất hết ý nghĩa. Đọc lại lần thứ mấy
    // cũng nằm trong khoá — mỗi lần một bản đọc khác, nhưng lần thứ ba của đoạn
    // này thì mãi mãi là đúng bản đọc ấy.
    final seed = _seedOf('$voice|$text${lanThu == 0 ? '' : '|lần $lanThu'}');
    _busy[native] = (_busy[native] ?? 0) + 1;
    final Float32List raw;
    final Int32List duoi;
    final coNgu = nguCanh != null && nguCanh.isNotEmpty;
    try {
      final ra = await native.synthesize(
        text,
        voice,
        seed: seed,
        nguCanh: coNgu ? Int32List.fromList(nguCanh) : null,
      );
      raw = ra.samples;
      duoi = ra.duoi;
    } finally {
      final con = (_busy[native] ?? 1) - 1;
      if (con <= 0) {
        _busy.remove(native);
      } else {
        _busy[native] = con;
      }
    }
    var samples = raw;

    if ((speed - 1.0).abs() > 0.01) {
      samples = _resample(samples, speed);
    }
    samples = normalizePeak(samples);

    final wav = buildWav(samples, native.sampleRate);
    final seconds = samples.length / native.sampleRate;
    return TtsResult(wav, seconds, duoi: duoi);
  }

  /// Đổi tốc độ bằng cách lấy mẫu lại — cao độ đổi theo, chỉ dùng lúc xuất file.
  Float32List _resample(Float32List input, double speed) {
    if (input.isEmpty) return input;
    final target = (input.length / speed).round();
    if (target <= 1) return input;
    final out = Float32List(target);
    final scale = (input.length - 1) / (target - 1);
    for (var i = 0; i < target; i++) {
      final at = i * scale;
      final low = at.floor();
      final high = min(low + 1, input.length - 1);
      final frac = at - low;
      out[i] = input[low] * (1 - frac) + input[high] * frac;
    }
    return out;
  }

  int _seedOf(String key) {
    // FNV-1a 64 bit: rẻ, ổn định giữa các lần chạy và giữa các máy.
    var hash = 0xcbf29ce484222325;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash;
  }

  /// Nhân bản một giọng mới từ file .wav và thêm vào danh sách.
  Future<void> addVoice({required String name, required String wavPath}) async {
    final native = await _ensure();
    await native.addVoice(
      name: name,
      wavPath: wavPath,
      speakerEncoder: _store.speakerEncoder.path,
      codecEncoder: _store.codecEncoder.path,
      voicesPath: _store.voicesFile.path,
    );
    _dongWorkerPhu();
  }

  /// Xoá một giọng tự thêm. Giọng dựng sẵn thì thư viện native từ chối.
  Future<void> removeVoice(String name) async {
    final native = await _ensure();
    await native.removeVoice(name, _store.voicesFile.path);
    _dongWorkerPhu();
  }

  /// Danh sách giọng của các worker phụ đã cũ sau khi thêm/xoá giọng — đóng
  /// hết, lần xuất file sau chúng sẽ được mở lại với hồ sơ giọng mới.
  void _dongWorkerPhu() {
    for (final w in _extra) {
      _busy.remove(w);
      w.close();
    }
    _extra.clear();
  }

  void dispose() {
    _dongWorkerPhu();
    _native?.close();
    _native = null;
  }
}

/// Mô hình chưa có trên máy — giao diện bắt lỗi này để mời người dùng tải.
class TtsExceptionMissingModel implements Exception {
  const TtsExceptionMissingModel();

  @override
  String toString() => 'Chưa tải mô hình giọng đọc';
}

