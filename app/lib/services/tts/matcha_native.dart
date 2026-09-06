/// Chạy mô hình Matcha-TTS qua thư viện Rust (ONNX Runtime).
///
/// Cùng khuôn với [vieneu_v2_native.dart]: mô hình sống trong một isolate riêng
/// suốt phiên, isolate giao diện chỉ gửi tin nhắn. Khác ở ba chỗ:
///
/// - **không có danh sách giọng** — mô hình một người nói, nên không có hàm nào
///   hỏi giọng và cũng không nhân bản giọng được;
/// - tần số 22 050 Hz;
/// - tốc độ đọc là **tham số của mô hình** (`length_scale`) chứ không phải phép
///   lấy mẫu lại sau khi đọc xong, nên đổi tốc độ không kéo cao độ đi theo.
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
    Pointer<Void>, Pointer<Utf8>, Float, Uint32, Uint64, Pointer<Int32>);
typedef _SynthDart = Pointer<Float> Function(
    Pointer<Void>, Pointer<Utf8>, double, int, int, Pointer<Int32>);

typedef _HuyNative = Void Function(Uint64);
typedef _HuyDart = void Function(int);

typedef _SamplesFreeNative = Void Function(Pointer<Float>, Int32);
typedef _SamplesFreeDart = void Function(Pointer<Float>, int);

typedef _StringFreeNative = Void Function(Pointer<Utf8>);
typedef _StringFreeDart = void Function(Pointer<Utf8>);

typedef _HandleToStringNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _HandleToStringDart = Pointer<Utf8> Function(Pointer<Void>);

typedef _CloseNative = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

class MatchaPaths {
  const MatchaPaths({
    required this.encoderPath,
    required this.decoderPath,
    required this.vocoderPath,
    required this.symbolsPath,
    this.libraryPath,
    this.threads = 0,
  });

  final String encoderPath;
  final String decoderPath;
  final String vocoderPath;

  /// Bảng ký tự → số hiệu của mô hình. Không phải từ điển âm vị: Matcha đọc
  /// thẳng mặt chữ nên không đi qua sea-g2p.
  final String symbolsPath;

  final String? libraryPath;
  final int threads;
}

class MatchaException implements Exception {
  const MatchaException(this.message);
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
      _lib.lookupFunction<_SynthNative, _SynthDart>('matcha_synthesize');
  // Hai hàm giải phóng dùng chung với hai engine VieNeu — cùng thư viện, cùng
  // bộ cấp phát.
  late final _SamplesFreeDart _freeSamples =
      _lib.lookupFunction<_SamplesFreeNative, _SamplesFreeDart>('vieneu_samples_free');
  late final _StringFreeDart _freeString =
      _lib.lookupFunction<_StringFreeNative, _StringFreeDart>('vieneu_string_free');
  late final _HandleToStringDart _lastError =
      _lib.lookupFunction<_HandleToStringNative, _HandleToStringDart>('matcha_last_error');

  static String get _defaultLibraryName {
    if (Platform.isWindows) return 'sachnoi_vieneu.dll';
    if (Platform.isMacOS) return 'libsachnoi_vieneu.dylib';
    return 'libsachnoi_vieneu.so';
  }

  static _Native open(MatchaPaths paths) {
    final lib = DynamicLibrary.open(paths.libraryPath ?? _defaultLibraryName);

    final enc = paths.encoderPath.toNativeUtf8();
    final dec = paths.decoderPath.toNativeUtf8();
    final voc = paths.vocoderPath.toNativeUtf8();
    final sym = paths.symbolsPath.toNativeUtf8();
    final errorOut = calloc<Pointer<Utf8>>();

    try {
      final handle = lib.lookupFunction<_OpenNative, _OpenDart>('matcha_open')(
        enc,
        dec,
        voc,
        sym,
        paths.threads,
        errorOut,
      );
      if (handle == nullptr) {
        final err = errorOut.value;
        final message = err == nullptr ? 'không rõ nguyên nhân' : err.toDartString();
        if (err != nullptr) {
          lib.lookupFunction<_StringFreeNative, _StringFreeDart>('vieneu_string_free')(err);
        }
        throw MatchaException('Không mở được mô hình Matcha: $message');
      }
      return _Native(lib, handle);
    } finally {
      calloc.free(enc);
      calloc.free(dec);
      calloc.free(voc);
      calloc.free(sym);
      calloc.free(errorOut);
    }
  }

  int get sampleRate => _lib.lookupFunction<_IntNative, _IntDart>('matcha_sample_rate')();

  Float32List synthesize(String text, double tocDo, int seed, int ma) {
    final textPtr = text.toNativeUtf8();
    final lenPtr = calloc<Int32>();
    try {
      final data = _synthesize(_handle, textPtr, tocDo, seed, ma, lenPtr);
      if (data == nullptr) {
        final err = _lastError(_handle);
        final message = err == nullptr ? 'không rõ nguyên nhân' : err.toDartString();
        if (err != nullptr) _freeString(err);
        throw MatchaException(message);
      }
      // Sao sang bộ nhớ của Dart rồi trả lại vùng nhớ của Rust ngay.
      final out = Float32List.fromList(data.asTypedList(lenPtr.value));
      _freeSamples(data, lenPtr.value);
      return out;
    } finally {
      calloc.free(textPtr);
      calloc.free(lenPtr);
    }
  }

  void close() => _lib.lookupFunction<_CloseNative, _CloseDart>('matcha_close')(_handle);
}

// -- giao thức với isolate nền -----------------------------------------------

class _Request {
  const _Request(this.id, this.text, this.tocDo, this.seed, this.ma);
  final int id;
  final String text;
  final double tocDo;
  final int seed;

  /// Mã để huỷ — xem [MatchaNative.huyToi].
  final int ma;
}

class _Ready {
  const _Ready(this.port, this.sampleRate);
  final SendPort port;
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

void _worker((SendPort, MatchaPaths) args) {
  final (reply, paths) = args;
  final _Native native;
  try {
    native = _Native.open(paths);
  } catch (err) {
    reply.send(_Failure(-1, '$err'));
    return;
  }

  final inbox = ReceivePort();
  reply.send(_Ready(inbox.sendPort, native.sampleRate));

  inbox.listen((message) {
    if (message is! _Request) {
      native.close();
      inbox.close();
      return;
    }
    try {
      reply.send(_Audio(
          message.id, native.synthesize(message.text, message.tocDo, message.seed, message.ma)));
    } catch (err) {
      reply.send(_Failure(message.id, '$err'));
    }
  });
}

/// Mô hình Matcha chạy trong isolate nền.
class MatchaNative {
  MatchaNative._(this._send, this.sampleRate);

  final SendPort _send;
  final int sampleRate;

  final _pending = <int, Completer<Float32List>>{};
  var _nextId = 0;
  var _closed = false;

  static Future<MatchaNative> start(MatchaPaths paths) async {
    final receive = ReceivePort();
    final ready = Completer<MatchaNative>();
    late final MatchaNative engine;

    receive.listen((message) {
      if (message is _Ready) {
        engine = MatchaNative._(message.port, message.sampleRate);
        ready.complete(engine);
      } else if (message is _Audio) {
        engine._pending.remove(message.id)?.complete(message.samples);
      } else if (message is _Failure) {
        if (message.id < 0) {
          if (!ready.isCompleted) ready.completeError(MatchaException(message.message));
        } else {
          engine._pending.remove(message.id)?.completeError(MatchaException(message.message));
        }
      }
    });

    await Isolate.spawn(_worker, (receive.sendPort, paths), debugName: 'matcha');
    return ready.future;
  }

  Future<Float32List> synthesize(String text, {double tocDo = 1.0, int seed = 0, int ma = 0}) {
    if (_closed) throw const MatchaException('Engine đã đóng');
    final id = _nextId++;
    final completer = Completer<Float32List>();
    _pending[id] = completer;
    _send.send(_Request(id, text, tocDo, seed, ma));
    return completer.future;
  }

  /// Mã cấp cho yêu cầu kế tiếp. Chung cho MỌI worker và mọi isolate: lệnh huỷ
  /// phải quét được tất cả, không riêng bể của một worker.
  static var _maKeTiep = 1;
  static int maMoi() => _maKeTiep++;

  /// Mã lớn nhất đã cấp — huỷ tới đây là dọn sạch mọi việc đang chờ.
  static int get maHienTai => _maKeTiep - 1;

  /// Bỏ mọi yêu cầu có mã ≤ [denMa], kể cả đang xếp hàng trong isolate.
  ///
  /// Gọi thẳng vào thư viện native từ isolate giao diện, KHÔNG đi qua cổng của
  /// isolate nền — cùng lý do như `VieNeuV2Native.huyToi`: isolate nền lúc này
  /// đang kẹt trong một lượt đọc, tin nhắn gửi vào chỉ nằm xếp hàng sau đúng
  /// cái cần huỷ.
  static void huyToi(int denMa, {String? libraryPath}) {
    try {
      final lib = DynamicLibrary.open(libraryPath ?? _Native._defaultLibraryName);
      lib.lookupFunction<_HuyNative, _HuyDart>('matcha_huy')(denMa);
    } catch (_) {
      // Chưa nạp được thư viện thì cũng chẳng có gì đang chạy để mà huỷ.
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _send.send(null);
  }
}
