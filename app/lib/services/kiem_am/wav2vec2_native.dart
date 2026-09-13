/// Giữ một phiên nhận dạng trong isolate để nghe/xuất dùng chung, không nạp
/// lại 122 MB mỗi đoạn và không chạy suy luận trên luồng vẽ giao diện.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _MoC = Pointer<Void> Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _MoDart = Pointer<Void> Function(Pointer<Utf8>, Pointer<Pointer<Utf8>>);
typedef _NhanC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Float);
typedef _NhanDart =
    Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, double);
typedef _DongC = Void Function(Pointer<Void>);
typedef _DongDart = void Function(Pointer<Void>);
typedef _TraC = Void Function(Pointer<Utf8>);
typedef _TraDart = void Function(Pointer<Utf8>);

class AmNhanDang {
  const AmNhanDang(this.soAm, this.amVi);
  final int soAm;
  final String amVi;
}

void _nhanNen((SendPort, String, String?) cauHinh) {
  final (tra, thuMuc, thuVien) = cauHinh;
  Pointer<Void> bo = nullptr;
  _DongDart? dong;
  try {
    final lib = DynamicLibrary.open(
      thuVien ??
          (Platform.isWindows
              ? 'sachnoi_vieneu.dll'
              : Platform.isMacOS
              ? 'libsachnoi_vieneu.dylib'
              : 'libsachnoi_vieneu.so'),
    );
    final mo = lib.lookupFunction<_MoC, _MoDart>('kiem_am_mo');
    final nhan = lib.lookupFunction<_NhanC, _NhanDart>('kiem_am_nhan');
    dong = lib.lookupFunction<_DongC, _DongDart>('kiem_am_dong');
    final traChuoi = lib.lookupFunction<_TraC, _TraDart>('vieneu_string_free');
    final duongDan = thuMuc.toNativeUtf8();
    final loi = calloc<Pointer<Utf8>>();
    try {
      bo = mo(duongDan, loi);
      if (bo == nullptr) {
        final thongBao = loi.value == nullptr
            ? 'Không nạp được wav2vec2'
            : loi.value.toDartString();
        throw StateError(thongBao);
      }
    } finally {
      if (loi.value != nullptr) traChuoi(loi.value);
      calloc.free(loi);
      calloc.free(duongDan);
    }
    final nhanTin = ReceivePort();
    tra.send(nhanTin.sendPort);
    nhanTin.listen((tin) {
      if (tin == null) {
        dong!(bo);
        bo = nullptr;
        nhanTin.close();
        return;
      }
      final (ma, wav, nhip) = tin as (int, String, double);
      final duongDan = wav.toNativeUtf8();
      Pointer<Utf8> ra = nullptr;
      try {
        ra = nhan(bo, duongDan, nhip);
        if (ra == nullptr) throw StateError('wav2vec2 không trả kết quả');
        final ket = jsonDecode(ra.toDartString()) as Map<String, dynamic>;
        tra.send((ma, ket));
      } catch (loi) {
        tra.send((ma, <String, dynamic>{'loi': '$loi'}));
      } finally {
        if (ra != nullptr) traChuoi(ra);
        calloc.free(duongDan);
      }
    });
  } catch (loi) {
    if (bo != nullptr) dong?.call(bo);
    tra.send('$loi');
  }
}

class Wav2vec2Native {
  Wav2vec2Native._();
  final _tin = ReceivePort();
  final _loi = ReceivePort();
  final _thoat = ReceivePort();
  final _sanSang = Completer<void>();
  final _daThoat = Completer<void>();
  final _cho = <int, Completer<AmNhanDang>>{};
  SendPort? _gui;
  var _ma = 0;
  var _daDong = false;

  static Future<Wav2vec2Native> mo(String thuMuc, {String? thuVien}) async {
    final bo = Wav2vec2Native._();
    bo._tin.listen(bo._xuLy);
    bo._loi.listen((loi) => bo._hong(StateError('Isolate wav2vec2: $loi')));
    bo._thoat.listen((_) {
      bo._hong(StateError('Bộ kiểm âm đã dừng'));
      bo._tin.close();
      bo._loi.close();
      bo._thoat.close();
      if (!bo._daThoat.isCompleted) bo._daThoat.complete();
    });
    // Gắn người nhận lỗi trước khi spawn: thư viện thiếu có thể báo lỗi ngay.
    final sanSang = bo._sanSang.future;
    try {
      await Isolate.spawn(
        _nhanNen,
        (bo._tin.sendPort, thuMuc, thuVien),
        onError: bo._loi.sendPort,
        onExit: bo._thoat.sendPort,
        errorsAreFatal: true,
        debugName: 'kiem-am-wav2vec2',
      );
    } catch (loi) {
      bo._hong(loi);
      bo._tin.close();
      bo._loi.close();
      bo._thoat.close();
      if (!bo._daThoat.isCompleted) bo._daThoat.complete();
    }
    await sanSang;
    return bo;
  }

  void _xuLy(dynamic tin) {
    if (tin is SendPort) {
      _gui = tin;
      if (!_sanSang.isCompleted) _sanSang.complete();
    } else if (tin is String) {
      _hong(StateError(tin));
    } else if (tin is (int, Map<String, dynamic>)) {
      final (ma, ket) = tin;
      final cho = _cho.remove(ma);
      if (cho == null) return;
      if (ket['loi'] != null) {
        cho.completeError(StateError(ket['loi'] as String));
      } else {
        try {
          cho.complete(
            AmNhanDang(
              ket['soAm'] as int,
              (ket['amVi'] as List).cast<String>().join(' '),
            ),
          );
        } catch (loi) {
          cho.completeError(loi);
        }
      }
    }
  }

  void _hong(Object loi) {
    _daDong = true;
    if (!_sanSang.isCompleted) _sanSang.completeError(loi);
    for (final cho in _cho.values) {
      cho.completeError(loi);
    }
    _cho.clear();
  }

  Future<AmNhanDang> nhan(String wav, {double nhipCaoDo = 1}) {
    if (_daDong) return Future.error(StateError('Bộ kiểm âm đã đóng'));
    final ma = _ma++;
    final cho = Completer<AmNhanDang>();
    _cho[ma] = cho;
    _gui!.send((ma, wav, nhipCaoDo));
    return cho.future;
  }

  Future<void> dong() async {
    if (!_daDong) {
      _daDong = true;
      _gui?.send(null);
    }
    await _daThoat.future;
  }
}
