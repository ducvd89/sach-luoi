/// Nén file WAV đã xuất sang Opus hoặc MP3, gọi thư viện Rust.
///
/// Chỉ có trên máy tính. Điện thoại sẽ dùng MediaCodec của hệ điều hành, nên
/// [encoderAvailable] trả về false ở đó và phần xuất file giữ nguyên WAV.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

/// Định dạng nén, khớp với mã số bên Rust.
enum EncodeFormat {
  /// Opus trong container Ogg. Bitrate tính theo bit/s.
  opus(0, 'opus'),

  /// MP3. Bitrate tính theo kbps.
  mp3(1, 'mp3');

  const EncodeFormat(this.code, this.extension);
  final int code;
  final String extension;
}

typedef _EncodeNative = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Pointer<Pointer<Utf8>>);
typedef _EncodeDart = int Function(
    Pointer<Utf8>, Pointer<Utf8>, int, int, Pointer<Pointer<Utf8>>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

class EncodeException implements Exception {
  const EncodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Máy này nén được không.
///
/// Android không có bộ mã hoá trong thư viện native (xem Cargo.toml), nên hỏi
/// trước còn hơn để lời gọi vỡ ở tầng FFI.
bool get encoderAvailable => !Platform.isAndroid && !Platform.isIOS;

/// Đường dẫn thư viện, để kiểm thử trỏ vào bản dựng trong native/.
String? encoderLibraryOverride;

String get _libraryName {
  if (Platform.isWindows) return 'sachnoi_vieneu.dll';
  if (Platform.isMacOS) return 'libsachnoi_vieneu.dylib';
  return 'libsachnoi_vieneu.so';
}

/// Nén [wavPath] thành [outPath]. Ném [EncodeException] kèm lý do nếu lỗi.
///
/// Chạy ở isolate riêng: một part 30 phút mất khoảng 5–9 giây, đủ lâu để làm
/// đứng giao diện nếu chạy ngay trên isolate chính.
Future<void> encodeAudioFile({
  required String wavPath,
  required String outPath,
  required EncodeFormat format,
  required int bitrate,
}) async {
  if (!encoderAvailable) {
    throw const EncodeException('Máy này không nén được, giữ nguyên WAV');
  }
  final lib = encoderLibraryOverride ?? _libraryName;
  await Isolate.run(() => _encodeBlocking(lib, wavPath, outPath, format.code, bitrate));
}

/// Phần chạy đồng bộ trong isolate nền.
void _encodeBlocking(String lib, String wavPath, String outPath, int code, int bitrate) {
  final library = DynamicLibrary.open(lib);
  final encode = library.lookupFunction<_EncodeNative, _EncodeDart>('sachnoi_ma_hoa_file');
  final freeString = library.lookupFunction<_FreeNative, _FreeDart>('vieneu_string_free');

  final inPtr = wavPath.toNativeUtf8();
  final outPtr = outPath.toNativeUtf8();
  final errPtr = calloc<Pointer<Utf8>>();
  try {
    final result = encode(inPtr, outPtr, code, bitrate, errPtr);
    if (result != 0) {
      final err = errPtr.value;
      final message = err == nullptr ? 'không rõ nguyên nhân' : err.toDartString();
      if (err != nullptr) freeString(err);
      throw EncodeException(message);
    }
  } finally {
    calloc.free(inPtr);
    calloc.free(outPtr);
    calloc.free(errPtr);
  }
}
