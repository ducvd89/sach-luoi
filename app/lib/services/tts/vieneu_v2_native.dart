/// Chạy mô hình VieNeu **v2** qua thư viện Rust (llama.cpp + NeuCodec).
///
/// Cùng khuôn với [vieneu_native.dart]: mô hình sống trong một isolate riêng
/// suốt phiên, isolate giao diện chỉ gửi tin nhắn. Khác ở ba chỗ:
///
/// - không có ngữ cảnh nối đoạn (`duoi`) — v2 bám giọng bằng mã tham chiếu cố
///   định của giọng, nên cùng một đoạn văn luôn ra cùng âm thanh;
/// - tần số 24 kHz thay vì 48 kHz;
/// - hồ sơ giọng kèm sẵn mô tả, lấy luôn để hiện trong Cài đặt.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// -- chữ ký hàm trong thư viện Rust ------------------------------------------

typedef _OpenNative = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Pointer<Utf8>>);
typedef _OpenDart = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Pointer<Utf8>>);

typedef _AddVoiceNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _AddVoiceDart = int Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _RemoveVoiceNative = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);
typedef _RemoveVoiceDart = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>);

typedef _IndexedIntNative = Int32 Function(Pointer<Void>, Int32);
typedef _IndexedIntDart = int Function(Pointer<Void>, int);

typedef _SynthNative = Pointer<Float> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Uint32, Pointer<Int32>);
typedef _SynthDart = Pointer<Float> Function(
    Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Int32>);

typedef _SamplesFreeNative = Void Function(Pointer<Float>, Int32);
typedef _SamplesFreeDart = void Function(Pointer<Float>, int);

typedef _HandleToStringNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _HandleToStringDart = Pointer<Utf8> Function(Pointer<Void>);

typedef _HandleToIntNative = Int32 Function(Pointer<Void>);
typedef _HandleToIntDart = int Function(Pointer<Void>);

typedef _IndexedStringNative = Pointer<Utf8> Function(Pointer<Void>, Int32);
typedef _IndexedStringDart = Pointer<Utf8> Function(Pointer<Void>, int);

typedef _StringFreeNative = Void Function(Pointer<Utf8>);
typedef _StringFreeDart = void Function(Pointer<Utf8>);

typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

/// Một giọng của v2.
class VieNeuV2Voice {
  const VieNeuV2Voice(this.name, this.description, {this.tuThem = false});
  final String name;
  final String description;

  /// Người dùng tự thêm trên máy này — chỉ những giọng này mới xoá được.
  final bool tuThem;
}

class VieNeuV2Paths {
  const VieNeuV2Paths({
    required this.ggufPath,
    required this.codecPath,
    required this.voicesPath,
    required this.extraVoicesPath,
    required this.userVoicesPath,
    required this.dictPath,
    this.libraryPath,
    this.threads = 0,
  });

  final String ggufPath;
  final String codecPath;

  /// Bảy giọng của tác giả mô hình, tải từ HuggingFace.
  final String voicesPath;

  /// Giọng nhân bản sẵn đi kèm ứng dụng (Latradio, Việt Sử).
  final String extraVoicesPath;

  /// Giọng người dùng tự thêm — nơi duy nhất được ghi lúc chạy.
  final String userVoicesPath;

  final String dictPath;
  final String? libraryPath;
  final int threads;
}

class VieNeuV2Exception implements Exception {
  const VieNeuV2Exception(this.message);
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
      _lib.lookupFunction<_SynthNative, _SynthDart>('vieneu_v2_synthesize');
  // Hai hàm giải phóng dùng chung với engine v3 — cùng thư viện, cùng bộ cấp phát.
  late final _SamplesFreeDart _freeSamples =
      _lib.lookupFunction<_SamplesFreeNative, _SamplesFreeDart>('vieneu_samples_free');
  late final _StringFreeDart _freeString =
      _lib.lookupFunction<_StringFreeNative, _StringFreeDart>('vieneu_string_free');
  late final _HandleToStringDart _lastError =
      _lib.lookupFunction<_HandleToStringNative, _HandleToStringDart>('vieneu_v2_last_error');

  static String get _defaultLibraryName {
    if (Platform.isWindows) return 'sachnoi_vieneu.dll';
    if (Platform.isMacOS) return 'libsachnoi_vieneu.dylib';
    return 'libsachnoi_vieneu.so';
  }

  static _Native open(VieNeuV2Paths paths) {
    final lib = DynamicLibrary.open(paths.libraryPath ?? _defaultLibraryName);

    final gguf = paths.ggufPath.toNativeUtf8();
    final codec = paths.codecPath.toNativeUtf8();
    final voices = paths.voicesPath.toNativeUtf8();
    final extra = paths.extraVoicesPath.toNativeUtf8();
    final user = paths.userVoicesPath.toNativeUtf8();
    final dict = paths.dictPath.toNativeUtf8();
    final errorOut = calloc<Pointer<Utf8>>();

    try {
      final handle = lib.lookupFunction<_OpenNative, _OpenDart>('vieneu_v2_open')(
        gguf,
        codec,
        voices,
        extra,
        user,
        dict,
        paths.threads,
        errorOut,
      );
      if (handle == nullptr) {
        final err = errorOut.value;
        final message = err == nullptr ? 'không rõ nguyên nhân' : err.toDartString();
        if (err != nullptr) {
          lib.lookupFunction<_StringFreeNative, _StringFreeDart>('vieneu_string_free')(err);
        }
        throw VieNeuV2Exception('Không mở được mô hình v2: $message');
      }
      return _Native(lib, handle);
    } finally {
      calloc.free(gguf);
      calloc.free(codec);
      calloc.free(voices);
      calloc.free(extra);
      calloc.free(user);
      calloc.free(dict);
      calloc.free(errorOut);
    }
  }

  String _errorText() {
    final err = _lastError(_handle);
    if (err == nullptr) return 'không rõ nguyên nhân';
    final text = err.toDartString();
    _freeString(err);
    return text;
  }

  void addVoice(String name, String wavPath, String text, String encoderPath, String userPath) {
    final args = [name, wavPath, text, encoderPath, userPath].map((s) => s.toNativeUtf8()).toList();
    try {
      final code = _lib.lookupFunction<_AddVoiceNative, _AddVoiceDart>('vieneu_v2_add_voice')(
          _handle, args[0], args[1], args[2], args[3], args[4]);
      if (code != 0) throw VieNeuV2Exception(_errorText());
    } finally {
      for (final a in args) {
        calloc.free(a);
      }
    }
  }

  void removeVoice(String name, String userPath) {
    final n = name.toNativeUtf8();
    final u = userPath.toNativeUtf8();
    try {
      final code =
          _lib.lookupFunction<_RemoveVoiceNative, _RemoveVoiceDart>('vieneu_v2_remove_voice')(
              _handle, n, u);
      if (code != 0) throw VieNeuV2Exception(_errorText());
    } finally {
      calloc.free(n);
      calloc.free(u);
    }
  }

  int get sampleRate => _lib.lookupFunction<_IntNative, _IntDart>('vieneu_v2_sample_rate')();

  List<VieNeuV2Voice> voices() {
    final count =
        _lib.lookupFunction<_HandleToIntNative, _HandleToIntDart>('vieneu_v2_voice_count')(_handle);
    final nameOf =
        _lib.lookupFunction<_IndexedStringNative, _IndexedStringDart>('vieneu_v2_voice_name');
    final descOf = _lib
        .lookupFunction<_IndexedStringNative, _IndexedStringDart>('vieneu_v2_voice_description');
    final tuThemOf =
        _lib.lookupFunction<_IndexedIntNative, _IndexedIntDart>('vieneu_v2_voice_tu_them');

    final out = <VieNeuV2Voice>[];
    for (var i = 0; i < count; i++) {
      final namePtr = nameOf(_handle, i);
      if (namePtr == nullptr) continue;
      final name = namePtr.toDartString();
      _freeString(namePtr);

      final descPtr = descOf(_handle, i);
      final desc = descPtr == nullptr ? '' : descPtr.toDartString();
      if (descPtr != nullptr) _freeString(descPtr);

      out.add(VieNeuV2Voice(name, desc, tuThem: tuThemOf(_handle, i) != 0));
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
        throw VieNeuV2Exception(message);
      }
      // Sao sang bộ nhớ của Dart rồi trả lại vùng nhớ của Rust ngay.
      final out = Float32List.fromList(data.asTypedList(lenPtr.value));
      _freeSamples(data, lenPtr.value);
      return out;
    } finally {
      calloc.free(textPtr);
      calloc.free(voicePtr);
      calloc.free(lenPtr);
    }
  }

  void close() => _lib.lookupFunction<_CloseNative, _CloseDart>('vieneu_v2_close')(_handle);
}

// -- giao thức với isolate nền -----------------------------------------------

class _Request {
  const _Request(this.id, this.text, this.voice, this.seed);
  final int id;
  final String text;
  final String voice;
  final int seed;
}

/// Thêm hoặc xoá giọng — làm trong chính isolate đang giữ mô hình để danh sách
/// giọng ở hai nơi không lệch nhau.
class _VoiceEdit {
  const _VoiceEdit(this.id, this.remove, this.name, this.wavPath, this.text, this.encoderPath,
      this.userPath);
  final int id;
  final bool remove;
  final String name;
  final String wavPath;
  final String text;
  final String encoderPath;
  final String userPath;
}

class _VoicesChanged {
  const _VoicesChanged(this.id, this.voices, this.error);
  final int id;
  final List<VieNeuV2Voice> voices;
  final String? error;
}

class _Ready {
  const _Ready(this.port, this.voices, this.sampleRate);
  final SendPort port;
  final List<VieNeuV2Voice> voices;
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

void _worker((SendPort, VieNeuV2Paths) args) {
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
          native.removeVoice(message.name, message.userPath);
        } else {
          native.addVoice(
              message.name, message.wavPath, message.text, message.encoderPath, message.userPath);
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

/// Mô hình VieNeu v2 chạy trong isolate nền.
class VieNeuV2Native {
  VieNeuV2Native._(this._send, this.voices, this.sampleRate);

  final SendPort _send;
  List<VieNeuV2Voice> voices;
  final int sampleRate;

  final _pending = <int, Completer<Float32List>>{};
  final _edits = <int, Completer<void>>{};
  var _nextId = 0;
  var _closed = false;

  static Future<VieNeuV2Native> start(VieNeuV2Paths paths) async {
    final receive = ReceivePort();
    final ready = Completer<VieNeuV2Native>();
    late final VieNeuV2Native engine;

    receive.listen((message) {
      if (message is _Ready) {
        engine = VieNeuV2Native._(message.port, message.voices, message.sampleRate);
        ready.complete(engine);
      } else if (message is _Audio) {
        engine._pending.remove(message.id)?.complete(message.samples);
      } else if (message is _VoicesChanged) {
        engine.voices = message.voices;
        final waiting = engine._edits.remove(message.id);
        if (message.error != null) {
          waiting?.completeError(VieNeuV2Exception(message.error!));
        } else {
          waiting?.complete();
        }
      } else if (message is _Failure) {
        if (message.id < 0) {
          if (!ready.isCompleted) ready.completeError(VieNeuV2Exception(message.message));
        } else {
          engine._pending.remove(message.id)?.completeError(VieNeuV2Exception(message.message));
        }
      }
    });

    await Isolate.spawn(_worker, (receive.sendPort, paths), debugName: 'vieneu_v2');
    return ready.future;
  }

  Future<Float32List> synthesize(String text, String voice, {int seed = 0}) {
    if (_closed) throw const VieNeuV2Exception('Engine đã đóng');
    final id = _nextId++;
    final completer = Completer<Float32List>();
    _pending[id] = completer;
    _send.send(_Request(id, text, voice, seed));
    return completer.future;
  }

  /// Nhân bản một giọng mới từ file ghi âm kèm lời của đúng đoạn ấy.
  Future<void> addVoice({
    required String name,
    required String wavPath,
    required String text,
    required String encoderPath,
    required String userVoicesPath,
  }) {
    final id = _nextId++;
    final completer = Completer<void>();
    _edits[id] = completer;
    _send.send(_VoiceEdit(id, false, name, wavPath, text, encoderPath, userVoicesPath));
    return completer.future;
  }

  Future<void> removeVoice(String name, String userVoicesPath) {
    final id = _nextId++;
    final completer = Completer<void>();
    _edits[id] = completer;
    _send.send(_VoiceEdit(id, true, name, '', '', '', userVoicesPath));
    return completer.future;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _send.send(null);
  }
}
