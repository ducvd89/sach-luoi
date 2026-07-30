/// Engine VieNeu chạy thẳng trong ứng dụng — không Python, không mạng.
///
/// Đây là engine dùng trên điện thoại. Nó trả về mẫu âm thô nên ứng dụng đóng
/// gói thành WAV: nhúng bộ mã hoá MP3 vào Flutter còn nặng hơn cả mô hình.
library;

import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
      return const EngineStatus(ready: true, message: 'Sẵn sàng', device: 'cpu');
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

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
  }) async {
    final native = await _ensure();
    final voice = voiceId.isEmpty ? (native.voices.firstOrNull ?? '') : voiceId;
    if (voice.isEmpty) throw TtsException('Chưa có giọng nào trong mô hình');

    // Hạt giống cố định theo nội dung: cùng một đoạn phải luôn cho cùng kết quả,
    // nếu không bộ nhớ đệm của ứng dụng mất hết ý nghĩa.
    final seed = _seedOf('$voice|$text');
    var samples = await native.synthesize(text, voice, seed: seed);

    if ((speed - 1.0).abs() > 0.01) {
      samples = _resample(samples, speed);
    }
    samples = normalizePeak(samples);

    final wav = buildWav(samples, native.sampleRate);
    final seconds = samples.length / native.sampleRate;
    return TtsResult(wav, seconds);
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
  }

  /// Xoá một giọng tự thêm. Giọng dựng sẵn thì thư viện native từ chối.
  Future<void> removeVoice(String name) async {
    final native = await _ensure();
    await native.removeVoice(name, _store.voicesFile.path);
  }

  void dispose() {
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

extension _FirstOrNull<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// Cho phép engine báo lỗi mà không cần import chéo.
Future<bool> modelInstalled(Directory dir) => dir.exists();
