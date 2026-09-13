/// Một cửa kiểm âm dùng chung cho lúc nghe, đọc trước và xuất file.
///
/// Chỉ wav2vec2 được đếm âm thanh. Lỗi/thiếu mô hình trả «chưa kiểm» để không
/// bắt TTS đọc lại vì chính bộ kiểm bị hỏng; không quay lại thuật toán đỉnh sóng.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import '../../core/am_tiet_chu.dart';
import '../../core/kiem_am.dart';
import 'kho_wav2vec2.dart';
import 'wav2vec2_native.dart';

typedef NhanAm = Future<AmNhanDang> Function(File wav, double nhipCaoDo);

class BoKiemAm {
  BoKiemAm({KhoWav2vec2? kho, this._nhanAm, this.thuVien})
    : kho = kho ?? KhoWav2vec2();
  final KhoWav2vec2 kho;
  final NhanAm? _nhanAm;
  final String? thuVien;
  final thongBao = ValueNotifier<String>('Chưa chạy kiểm âm wav2vec2');
  Future<Wav2vec2Native>? _bo;
  Future<void> _hang = Future.value();
  bool _daDong = false;
  final _dem = <String, AmNhanDang>{};

  Future<KetQuaKiemAm> kiem({
    required String loi,
    required File wav,
    double nhipCaoDo = 1,
  }) {
    final cho = Completer<KetQuaKiemAm>();
    // Hàng đợi ở Dart: một phiên ONNX, tránh hai nơi cùng nạp mô hình và tranh RAM.
    _hang = _hang.then((_) async {
      try {
        cho.complete(await _kiem(loi, wav, nhipCaoDo));
      } catch (loi, vet) {
        cho.completeError(loi, vet);
      }
    });
    return cho.future;
  }

  Future<KetQuaKiemAm> _kiem(String loi, File wav, double nhip) async {
    final soTu = demAmChu(loi);
    try {
      if (_daDong) throw StateError('Bộ kiểm âm đã đóng');
      if (_nhanAm == null && !await kho.sanSang()) {
        throw StateError('Cần tải mô hình wav2vec2 trong Cài đặt → Kiểm âm');
      }
      // TtsManager chạm mtime mỗi lần nghe; băm nội dung để bản đọc trước
      // vẫn dùng lại được, và thay WAV tại cùng đường dẫn không lấy nhầm số âm.
      final khoa = '${await sha256.bind(wav.openRead()).first}|$nhip';
      var nhan = _dem.remove(khoa);
      if (nhan == null) {
        if (_nhanAm != null) {
          nhan = await _nhanAm(wav, nhip);
        } else {
          // Future giữ cả lỗi nạp, tránh thử nạp lại 122 MB ở mọi đoạn khi DLL hỏng.
          final bo = await (_bo ??= Wav2vec2Native.mo(
            kho.thuMuc.path,
            thuVien: thuVien,
          ));
          nhan = await bo.nhan(wav.path, nhipCaoDo: nhip);
        }
      }
      if (nhan.soAm < 0) throw StateError('Số âm nhận dạng không hợp lệ');
      _dem[khoa] = nhan;
      while (_dem.length > 32) {
        _dem.remove(_dem.keys.first);
      }
      final ket = KetQuaKiemAm(soTu: soTu, soAm: nhan.soAm, amVi: nhan.amVi);
      thongBao.value =
          'wav2vec2: $ket${ket.dat ? ' · đã khớp' : ' · lệch số âm'}';
      return ket;
    } catch (loi) {
      final lyDo = '$loi'.replaceFirst('Bad state: ', '');
      if (!_daDong) thongBao.value = 'Chưa kiểm âm: $lyDo';
      return KetQuaKiemAm(soTu: soTu, soAm: null, lyDoBoQua: lyDo);
    }
  }

  Future<void> napLai() async {
    await _hang;
    final bo = _bo;
    _bo = null;
    _dem.clear();
    if (bo != null) {
      try {
        await (await bo).dong();
      } catch (_) {
        /* Lỗi nạp cũ đã được báo. */
      }
    }
  }

  Future<void> dong() async {
    if (_daDong) return;
    _daDong = true;
    await napLai();
    thongBao.dispose();
  }
}
