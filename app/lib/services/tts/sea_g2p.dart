/// Chuyển chữ tiếng Việt sang âm vị, gọi thư viện Rust qua FFI.
///
/// Mô hình VieNeu không nhận chữ thô mà nhận âm vị, nên đây là bước bắt buộc
/// trước mọi lần đọc. Phần chuyển đổi nằm trong thư viện `sea-g2p` viết bằng
/// Rust: bản gốc chỉ có binding Python, ta dựng thêm một cổng C để gọi được từ
/// Dart trên cả máy tính lẫn điện thoại.
///
/// Kèm theo thư viện là một file từ điển nhị phân (~48 MB) được ánh xạ bộ nhớ,
/// nên mở nhanh và không ngốn RAM.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// -- chữ ký hàm trong thư viện Rust ------------------------------------------

typedef _NewNative = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _NewDart = Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>);

typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);

typedef _ConvertNative = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Int32);
typedef _ConvertDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, int);

typedef _StringFreeNative = Void Function(Pointer<Utf8>);
typedef _StringFreeDart = void Function(Pointer<Utf8>);

typedef _VersionNative = Int32 Function();
typedef _VersionDart = int Function();

/// Phiên bản cổng C mà mã Dart này biết nói chuyện.
const int _expectedAbiVersion = 1;

class SeaG2pException implements Exception {
  const SeaG2pException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Bộ chuyển chữ sang âm vị. Mở một lần rồi dùng lại cho cả cuốn sách.
class SeaG2p {
  SeaG2p._(this._handle, this._lib);

  final Pointer<Void> _handle;
  final DynamicLibrary _lib;
  bool _closed = false;

  late final _ConvertDart _phonemize =
      _lib.lookupFunction<_ConvertNative, _ConvertDart>('sea_g2p_phonemize');
  late final _ConvertDart _normalize =
      _lib.lookupFunction<_ConvertNative, _ConvertDart>('sea_g2p_normalize');
  late final _StringFreeDart _stringFree =
      _lib.lookupFunction<_StringFreeNative, _StringFreeDart>('sea_g2p_string_free');
  late final _FreeDart _free = _lib.lookupFunction<_FreeNative, _FreeDart>('sea_g2p_free');

  /// Tên thư viện theo từng hệ điều hành.
  static String get _libraryName {
    if (Platform.isWindows) return 'sea_g2p_rs.dll';
    if (Platform.isMacOS) return 'libsea_g2p_rs.dylib';
    return 'libsea_g2p_rs.so';
  }

  /// Mở thư viện và từ điển.
  ///
  /// [dictPath] là đường dẫn tới `sea_g2p.bin`. [libraryPath] chỉ cần trên máy
  /// tính lúc chạy test — trên điện thoại thư viện nằm sẵn trong ứng dụng.
  static SeaG2p open({required String dictPath, String? libraryPath}) {
    if (!File(dictPath).existsSync()) {
      throw SeaG2pException('Không tìm thấy từ điển âm vị: $dictPath');
    }

    final DynamicLibrary lib;
    try {
      lib = DynamicLibrary.open(libraryPath ?? _libraryName);
    } on ArgumentError catch (err) {
      throw SeaG2pException('Không nạp được ${libraryPath ?? _libraryName}: $err');
    }

    final version = lib.lookupFunction<_VersionNative, _VersionDart>('sea_g2p_abi_version')();
    if (version != _expectedAbiVersion) {
      throw SeaG2pException(
        'Thư viện âm vị phiên bản $version, mã Dart cần $_expectedAbiVersion',
      );
    }

    final create = lib.lookupFunction<_NewNative, _NewDart>('sea_g2p_new');
    final dict = dictPath.toNativeUtf8();
    final lang = 'vi'.toNativeUtf8();
    try {
      final handle = create(dict, lang);
      if (handle == nullptr) {
        throw SeaG2pException('Không mở được từ điển âm vị: $dictPath');
      }
      return SeaG2p._(handle, lib);
    } finally {
      calloc.free(dict);
      calloc.free(lang);
    }
  }

  String _call(_ConvertDart fn, String text, bool puncNorm) {
    if (_closed) throw const SeaG2pException('Bộ chuyển âm vị đã đóng');
    if (text.isEmpty) return '';

    final input = text.toNativeUtf8();
    try {
      final result = fn(_handle, input, puncNorm ? 1 : 0);
      if (result == nullptr) return '';
      try {
        return result.toDartString();
      } finally {
        _stringFree(result);
      }
    } finally {
      calloc.free(input);
    }
  }

  /// Chuẩn hoá rồi chuyển sang âm vị — đúng chuỗi việc mà bản Python làm.
  String phonemize(String text, {bool puncNorm = false}) =>
      _call(_phonemize, text, puncNorm);

  /// Chỉ chuẩn hoá văn bản (số, ngày tháng, viết tắt) mà không chuyển âm vị.
  String normalize(String text, {bool puncNorm = false}) =>
      _call(_normalize, text, puncNorm);

  void close() {
    if (_closed) return;
    _closed = true;
    _free(_handle);
  }
}
