/// Nén file WAV đã xuất sang Opus hoặc MP3, gọi thư viện Rust.
///
/// Máy tính dùng libopus/libmp3lame liên kết trong thư viện Rust; Android dùng
/// MediaCodec của hệ điều hành qua platform channel. Hai đường cho ra định dạng
/// hơi khác nhau (Android không có bộ mã hoá MP3, và Opus chỉ có từ API 29), nên
/// hàm nén **trả về đường dẫn thật đã ghi** thay vì tin vào đuôi file đoán trước.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';

/// Định dạng nén, khớp với mã số bên Rust.
enum EncodeFormat {
  /// Opus trong container Ogg. Bitrate tính theo bit/s.
  opus(0, 'opus'),

  /// MP3. Bitrate tính theo kbps.
  mp3(1, 'mp3'),

  /// AAC-LC, đóng khung ADTS (`.aac`). Bitrate tính theo bit/s.
  aac(2, 'aac');

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

/// Máy này nén được không. iOS chưa có đường nào nên vẫn ra WAV.
bool get encoderAvailable => !Platform.isIOS;

const _kenh = MethodChannel('sachnoi/ma_hoa');

/// Tiến trình nén trên Android — MediaCodec chạy trên luồng nền của Kotlin,
/// đẩy % qua đây thay vì chỉ trả lời một lần lúc xong hẳn. Chỉ Android có, máy
/// tính nén xong trong vài giây nên không đáng thêm kênh riêng.
const _kenhTienDoNen = EventChannel('sachnoi/ma_hoa_tien_do');

/// Đường dẫn thư viện, để kiểm thử trỏ vào bản dựng trong native/.
String? encoderLibraryOverride;

String get _libraryName {
  if (Platform.isWindows) return 'sachnoi_vieneu.dll';
  if (Platform.isMacOS) return 'libsachnoi_vieneu.dylib';
  return 'libsachnoi_vieneu.so';
}

/// Nén [wavPath], ghi cạnh [outBase] với đuôi do bộ mã hoá quyết định.
///
/// Trả về đường dẫn file đã ghi. Trên Android xin MP3 sẽ nhận `.m4a` (AAC) vì
/// hệ điều hành không có bộ mã hoá MP3, và máy dưới Android 10 xin Opus cũng
/// nhận AAC — nên bên gọi phải dùng đường dẫn trả về, đừng tự ghép đuôi.
///
/// [onProgress] báo phần đã nén xong (0..1) — chỉ Android gọi, và chỉ khi máy
/// đó thật sự đang nén (không gọi lúc mở đầu/kết thúc).
///
/// Ném [EncodeException] kèm lý do nếu lỗi.
Future<String> encodeAudioFile({
  required String wavPath,
  required String outBase,
  required EncodeFormat format,
  required int bitrate,
  void Function(double phan)? onProgress,
}) async {
  if (!encoderAvailable) {
    throw const EncodeException('Máy này không nén được, giữ nguyên WAV');
  }
  if (Platform.isAndroid) {
    // requestId rỗng báo cho phía Kotlin biết khỏi mất công đẩy sự kiện qua
    // kênh cho không ai nghe. Khác rỗng thì phải riêng cho từng lượt gọi: lỡ
    // hai job xuất file cùng lúc đều đang nén thì mới tách đúng lượt nào của
    // ai — kênh sự kiện là MỘT luồng dùng chung cho toàn app.
    final requestId =
        onProgress == null ? '' : '${DateTime.now().microsecondsSinceEpoch}';
    StreamSubscription<dynamic>? sub;
    if (onProgress != null) {
      sub = _kenhTienDoNen.receiveBroadcastStream().listen((event) {
        final goi = event as Map<Object?, Object?>;
        if (goi['requestId'] == requestId) {
          onProgress((goi['phan'] as num).toDouble());
        }
      });
    }
    try {
      final ra = await _kenh.invokeMethod<String>('nen', {
        'wavPath': wavPath,
        'outBase': outBase,
        'dinhDang': format.extension,
        'bitrate': bitrate,
        'requestId': requestId,
      });
      if (ra == null || ra.isEmpty) throw const EncodeException('MediaCodec không trả về đường dẫn');
      return ra;
    } on PlatformException catch (err) {
      throw EncodeException(err.message ?? '$err');
    } on MissingPluginException {
      throw const EncodeException('Bản này chưa nối MediaCodec');
    } finally {
      await sub?.cancel();
    }
  }
  // Máy tính: gọi thư viện Rust ở isolate riêng, một part 30 phút mất 5-9 giây
  // nên chạy trên isolate chính là thấy giao diện đứng.
  final lib = encoderLibraryOverride ?? _libraryName;
  final outPath = '$outBase.${format.extension}';
  await Isolate.run(() => _encodeBlocking(lib, wavPath, outPath, format.code, bitrate));
  return outPath;
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

/// Android có đưa file ra thư viện nhạc được không.
///
/// Trên Android mọi đường ghi thẳng vào bộ nhớ chung đều bị chặn, nên file phải
/// đi qua MediaStore mới tới được chỗ người dùng lấy được.
bool get needsMediaStore => Platform.isAndroid;

/// Chép [nguon] vào `Music/[thuMucCon]/[tenFile]` của hệ thống rồi xoá bản gốc.
///
/// Trả về đường dẫn người dùng thấy. Chỉ gọi trên Android.
Future<String> publishToMusicLibrary({
  required String nguon,
  required String thuMucCon,
  required String tenFile,
}) async {
  try {
    final ra = await _kenh.invokeMethod<String>('dangKy', {
      'nguon': nguon,
      'thuMucCon': thuMucCon,
      'tenFile': tenFile,
    });
    if (ra == null || ra.isEmpty) {
      throw const EncodeException('MediaStore không trả về đường dẫn');
    }
    return ra;
  } on PlatformException catch (err) {
    throw EncodeException(err.message ?? '$err');
  } on MissingPluginException {
    throw const EncodeException('Bản này chưa nối MediaStore');
  }
}
