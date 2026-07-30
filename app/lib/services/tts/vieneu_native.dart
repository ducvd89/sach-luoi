/// Chạy mô hình VieNeu ngay trong ứng dụng, qua thư viện Rust.
///
/// Mô hình nạp mất hơn một giây và mỗi đoạn mất vài giây để đọc, nên tất cả
/// nằm trong một isolate riêng sống suốt phiên: nạp một lần rồi phục vụ mọi
/// yêu cầu, còn isolate giao diện thì không bao giờ bị chặn.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// -- chữ ký hàm trong thư viện Rust ------------------------------------------

typedef _OpenNative = Pointer<Void> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Pointer<Utf8>>);
typedef _OpenDart = Pointer<Void> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Pointer<Utf8>>);

typedef _SynthNative = Pointer<Float> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Uint64, Pointer<Int32>);
typedef _SynthDart = Pointer<Float> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Int32>);

typedef _SamplesFreeNative = Void Function(Pointer<Float>, Int32);
typedef _SamplesFreeDart = void Function(Pointer<Float>, int);

typedef _HandleToStringNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _HandleToStringDart = Pointer<Utf8> Function(Pointer<Void>);

typedef _HandleToIntNative = Int32 Function(Pointer<Void>);
typedef _HandleToIntDart = int Function(Pointer<Void>);

typedef _VoiceNameNative = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _VoiceNameDart = Pointer<Utf8> Function(Pointer<Void>, int);

typedef _AddVoiceNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _AddVoiceDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _RemoveVoiceNative = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _RemoveVoiceDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _StringFreeNative = Void Function(Pointer<Utf8>);
typedef _StringFreeDart = void Function(Pointer<Utf8>);

typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

/// Nơi đặt các file mô hình. Isolate nền chỉ nhận đúng mấy đường dẫn này.
class VieNeuPaths {
  const VieNeuPaths({
    required this.modelDir,
    required this.codecDir,
    required this.dictPath,
    required this.voicesPath,
    this.libraryPath,
    this.threads = 0,
  });

  final String modelDir;
  final String codecDir;
  final String dictPath;
  final String voicesPath;

  /// Chỉ cần trên máy tính lúc chạy test; trên điện thoại thư viện nằm sẵn.
  final String? libraryPath;
  final int threads;
}

class VieNeuException implements Exception {
  const VieNeuException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Bọc thư viện native. Chỉ dùng bên trong isolate nền.
class _Native {
  _Native(this._lib, this._handle);

  final DynamicLibrary _lib;
  final Pointer<Void> _handle;

  late final _SynthDart _synthesize =
      _lib.lookupFunction<_SynthNative, _SynthDart>('vieneu_synthesize');
  late final _SamplesFreeDart _freeSamples =
      _lib.lookupFunction<_SamplesFreeNative, _SamplesFreeDart>('vieneu_samples_free');
  late final _HandleToStringDart _lastError =
      _lib.lookupFunction<_HandleToStringNative, _HandleToStringDart>('vieneu_last_error');
  late final _StringFreeDart _freeString =
      _lib.lookupFunction<_StringFreeNative, _StringFreeDart>('vieneu_string_free');

  static String get _defaultLibraryName {
    if (Platform.isWindows) return 'sachnoi_vieneu.dll';
    if (Platform.isMacOS) return 'libsachnoi_vieneu.dylib';
    return 'libsachnoi_vieneu.so';
  }

  static _Native open(VieNeuPaths paths) {
    final lib = DynamicLibrary.open(paths.libraryPath ?? _defaultLibraryName);

    final modelDir = paths.modelDir.toNativeUtf8();
    final codecDir = paths.codecDir.toNativeUtf8();
    final dictPath = paths.dictPath.toNativeUtf8();
    final voicesPath = paths.voicesPath.toNativeUtf8();
    final errorOut = calloc<Pointer<Utf8>>();

    try {
      final handle = lib.lookupFunction<_OpenNative, _OpenDart>('vieneu_open')(
        modelDir,
        codecDir,
        dictPath,
        voicesPath,
        paths.threads,
        errorOut,
      );
      if (handle == nullptr) {
        final err = errorOut.value;
        final message = err == nullptr ? 'không rõ nguyên nhân' : err.toDartString();
        throw VieNeuException('Không mở được mô hình: $message');
      }
      return _Native(lib, handle);
    } finally {
      calloc.free(modelDir);
      calloc.free(codecDir);
      calloc.free(dictPath);
      calloc.free(voicesPath);
      calloc.free(errorOut);
    }
  }

  int get sampleRate => _lib.lookupFunction<_IntNative, _IntDart>('vieneu_sample_rate')();

  List<String> voices() {
    final count = _lib.lookupFunction<_HandleToIntNative, _HandleToIntDart>('vieneu_voice_count')(_handle);
    final nameOf = _lib.lookupFunction<_VoiceNameNative, _VoiceNameDart>('vieneu_voice_name');
    final out = <String>[];
    for (var i = 0; i < count; i++) {
      final ptr = nameOf(_handle, i);
      if (ptr == nullptr) continue;
      out.add(ptr.toDartString());
      _freeString(ptr);
    }
    return out;
  }

  Float32List synthesize(String text, String voice, int seed) {
    final textPtr = text.toNativeUtf8();
    final voicePtr = voice.toNativeUtf8();
    final lenPtr = calloc<Int32>();
    try {
      final data = _synthesize(_handle, textPtr, voicePtr, seed, lenPtr);
      if (data == nullptr) {
        final err = _lastError(_handle);
        final message = err == nullptr ? 'không rõ nguyên nhân' : err.toDartString();
        if (err != nullptr) _freeString(err);
        throw VieNeuException(message);
      }
      final length = lenPtr.value;
      // Sao chép sang bộ nhớ của Dart rồi trả lại vùng nhớ của Rust ngay.
      final out = Float32List.fromList(data.asTypedList(length));
      _freeSamples(data, length);
      return out;
    } finally {
      calloc.free(textPtr);
      calloc.free(voicePtr);
      calloc.free(lenPtr);
    }
  }

  String _errorText() {
    final err = _lastError(_handle);
    if (err == nullptr) return 'không rõ nguyên nhân';
    final text = err.toDartString();
    _freeString(err);
    return text;
  }

  void addVoice(String name, String wavPath, String speakerEncoder, String codecEncoder,
      String voicesPath) {
    final args = [name, wavPath, speakerEncoder, codecEncoder, voicesPath]
        .map((s) => s.toNativeUtf8())
        .toList();
    try {
      final code = _lib.lookupFunction<_AddVoiceNative, _AddVoiceDart>('vieneu_add_voice')(
          _handle, args[0], args[1], args[2], args[3], args[4]);
      if (code != 0) throw VieNeuException(_errorText());
    } finally {
      for (final a in args) {
        calloc.free(a);
      }
    }
  }

  void removeVoice(String name, String voicesPath) {
    final n = name.toNativeUtf8();
    final v = voicesPath.toNativeUtf8();
    try {
      final code = _lib.lookupFunction<_RemoveVoiceNative, _RemoveVoiceDart>('vieneu_remove_voice')(
          _handle, n, v);
      if (code != 0) throw VieNeuException(_errorText());
    } finally {
      calloc.free(n);
      calloc.free(v);
    }
  }

  void close() => _lib.lookupFunction<_CloseNative, _CloseDart>('vieneu_close')(_handle);
}

// -- giao thức với isolate nền -----------------------------------------------

class _Request {
  const _Request(this.id, this.text, this.voice, this.seed);
  final int id;
  final String text;
  final String voice;
  final int seed;
}

/// Thêm hoặc xoá giọng — làm luôn trong isolate đang giữ mô hình để danh sách
/// giọng ở hai nơi không lệch nhau.
class _VoiceEdit {
  const _VoiceEdit(this.id, this.remove, this.name, this.wavPath, this.speakerEncoder,
      this.codecEncoder, this.voicesPath);
  final int id;
  final bool remove;
  final String name;
  final String wavPath;
  final String speakerEncoder;
  final String codecEncoder;
  final String voicesPath;
}

class _VoicesChanged {
  const _VoicesChanged(this.id, this.voices, this.error);
  final int id;
  final List<String> voices;
  final String? error;
}

class _Ready {
  const _Ready(this.port, this.voices, this.sampleRate);
  final SendPort port;
  final List<String> voices;
  final int sampleRate;
}

class _Failure {
  const _Failure(this.id, this.message);
  final int id;
  final String message;
}

class _Audio {
  const _Audio(this.id, this.samples);
  final int id;
  final Float32List samples;
}

void _worker((SendPort, VieNeuPaths) args) {
  final (reply, paths) = args;
  final _Native native;
  try {
    native = _Native.open(paths);
  } catch (err) {
    reply.send(_Failure(-1, '$err'));
    return;
  }

  final inbox = ReceivePort();
  reply.send(_Ready(inbox.sendPort, native.voices(), native.sampleRate));

  inbox.listen((message) {
    if (message is _VoiceEdit) {
      try {
        if (message.remove) {
          native.removeVoice(message.name, message.voicesPath);
        } else {
          native.addVoice(message.name, message.wavPath, message.speakerEncoder,
              message.codecEncoder, message.voicesPath);
        }
        reply.send(_VoicesChanged(message.id, native.voices(), null));
      } catch (err) {
        reply.send(_VoicesChanged(message.id, native.voices(), '$err'));
      }
      return;
    }
    if (message is! _Request) {
      native.close();
      inbox.close();
      return;
    }
    try {
      reply.send(_Audio(message.id, native.synthesize(message.text, message.voice, message.seed)));
    } catch (err) {
      reply.send(_Failure(message.id, '$err'));
    }
  });
}

/// Mô hình VieNeu chạy trong isolate nền.
class VieNeuNative {
  VieNeuNative._(this._send, this.voices, this.sampleRate);

  final SendPort _send;
  List<String> voices;
  final int sampleRate;

  final _pending = <int, Completer<Float32List>>{};
  final _edits = <int, Completer<void>>{};
  var _nextId = 0;
  var _closed = false;

  /// Nạp mô hình. Mất khoảng một giây rưỡi, chỉ làm một lần.
  static Future<VieNeuNative> start(VieNeuPaths paths) async {
    final receive = ReceivePort();
    final ready = Completer<VieNeuNative>();
    late final VieNeuNative engine;

    receive.listen((message) {
      if (message is _Ready) {
        engine = VieNeuNative._(message.port, message.voices, message.sampleRate);
        ready.complete(engine);
      } else if (message is _Audio) {
        engine._pending.remove(message.id)?.complete(message.samples);
      } else if (message is _VoicesChanged) {
        engine.voices = message.voices;
        final waiting = engine._edits.remove(message.id);
        if (message.error != null) {
          waiting?.completeError(VieNeuException(message.error!));
        } else {
          waiting?.complete();
        }
      } else if (message is _Failure) {
        if (message.id < 0) {
          if (!ready.isCompleted) ready.completeError(VieNeuException(message.message));
        } else {
          engine._pending.remove(message.id)?.completeError(VieNeuException(message.message));
        }
      }
    });

    await Isolate.spawn(_worker, (receive.sendPort, paths), debugName: 'vieneu');
    return ready.future;
  }

  /// Đọc một đoạn, trả về mẫu âm 48 kHz.
  Future<Float32List> synthesize(String text, String voice, {int seed = 0}) {
    if (_closed) throw const VieNeuException('Engine đã đóng');
    final id = _nextId++;
    final completer = Completer<Float32List>();
    _pending[id] = completer;
    _send.send(_Request(id, text, voice, seed));
    return completer.future;
  }

  /// Nhân bản một giọng mới từ file .wav.
  Future<void> addVoice({
    required String name,
    required String wavPath,
    required String speakerEncoder,
    required String codecEncoder,
    required String voicesPath,
  }) {
    final id = _nextId++;
    final completer = Completer<void>();
    _edits[id] = completer;
    _send.send(_VoiceEdit(id, false, name, wavPath, speakerEncoder, codecEncoder, voicesPath));
    return completer.future;
  }

  Future<void> removeVoice(String name, String voicesPath) {
    final id = _nextId++;
    final completer = Completer<void>();
    _edits[id] = completer;
    _send.send(_VoiceEdit(id, true, name, '', '', '', voicesPath));
    return completer.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _send.send(null);
  }
}
