/// Laya chạy bằng thư viện native của app: chọn người nói và đoán giới tính nhân vật.
///
/// Ranh giới Dart ↔ Rust của Laya nằm HẾT ở file này (như `vieneu_native.dart` với engine đọc).
/// Mô hình ONNX float16 645 MB nằm ngoài gói app, tải riêng (xem `ModelStore.layaDir`); phía Rust
/// là `native/vieneu/src/laya.rs` và `ffi_laya.rs`.
///
/// Mỗi lượt hỏi ~0,2–0,3 giây (đo bằng chính mã này trên chương Harry Potter 5: 4 luồng 46 giây,
/// 8 luồng 34 giây, 12 luồng 31 giây cho 90 câu thoại + 10 nhân vật mới), và một cuốn sách có hàng
/// nghìn câu thoại, nên phân tích chạy TRONG ISOLATE RIÊNG ([phanTichTrongNen]) chứ không bao giờ trên luồng giao diện. Một
/// handle chỉ được gọi từ một luồng tại một thời điểm (phía Rust lấy `&mut` mà không khoá): ở
/// đây mỗi isolate mở handle của riêng nó.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../core/nhan_vat.dart';

typedef _MoC = Pointer<Void> Function(Pointer<Utf8>, Int32, Pointer<Pointer<Utf8>>);
typedef _MoDart = Pointer<Void> Function(Pointer<Utf8>, int, Pointer<Pointer<Utf8>>);
typedef _HoiC = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _HoiDart = Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _LoiC = Pointer<Utf8> Function(Pointer<Void>);
typedef _DongC = Void Function(Pointer<Void>);
typedef _DongDart = void Function(Pointer<Void>);
typedef _TraC = Void Function(Pointer<Utf8>);
typedef _TraDart = void Function(Pointer<Utf8>);

/// Tên thư viện native theo nền tảng — cùng quy ước với `wav2vec2_native.dart`.
String tenThuVienNative() {
  if (Platform.isWindows) return 'sachnoi_vieneu.dll';
  if (Platform.isMacOS) return 'libsachnoi_vieneu.dylib';
  return 'libsachnoi_vieneu.so';
}

class LayaNative implements LayaKhach {
  LayaNative._(DynamicLibrary lib, this._handle)
      : _hoi = lib.lookupFunction<_HoiC, _HoiDart>('laya_predict'),
        _loi = lib.lookupFunction<_LoiC, _LoiC>('laya_last_error'),
        _dong = lib.lookupFunction<_DongC, _DongDart>('laya_close'),
        _tra = lib.lookupFunction<_TraC, _TraDart>('vieneu_string_free');

  Pointer<Void> _handle;
  final _HoiDart _hoi;
  final _LoiC _loi;
  final _DongDart _dong;
  final _TraDart _tra;

  /// Mở Laya từ [thuMuc] (có `laya.onnx`, `tokenizer.json`, `rl_agent_config.json`). Ném
  /// [StateError] kèm thông báo của phía Rust nếu hỏng — chủ yếu là thiếu hoặc hỏng mô hình.
  static LayaNative mo(String thuMuc, {String? thuVien, int soLuong = 8}) {
    final lib = DynamicLibrary.open(thuVien ?? tenThuVienNative());
    final mo = lib.lookupFunction<_MoC, _MoDart>('laya_open');
    final tra = lib.lookupFunction<_TraC, _TraDart>('vieneu_string_free');
    final duongDan = thuMuc.toNativeUtf8();
    final loi = calloc<Pointer<Utf8>>();
    try {
      final h = mo(duongDan, soLuong, loi);
      if (h == nullptr) {
        throw StateError(loi.value == nullptr ? 'Không nạp được Laya' : loi.value.toDartString());
      }
      return LayaNative._(lib, h);
    } finally {
      if (loi.value != nullptr) tra(loi.value);
      calloc.free(loi);
      calloc.free(duongDan);
    }
  }

  @override
  Future<List<double>> chon(
    String huongDan,
    String doan,
    String? thoai,
    List<(String, String)> luaChon,
  ) async {
    if (_handle == nullptr) throw StateError('Laya đã đóng');
    final json = jsonEncode([
      for (final (nhan, moTa) in luaChon) {'nhan': nhan, 'mo_ta': moTa},
    ]);
    final pDoan = doan.toNativeUtf8();
    final pThoai = thoai == null ? nullptr.cast<Utf8>() : thoai.toNativeUtf8();
    final pHuongDan = huongDan.toNativeUtf8();
    final pLua = json.toNativeUtf8();
    try {
      final ra = _hoi(_handle, pDoan, pThoai, pHuongDan, pLua);
      if (ra == nullptr) {
        final e = _loi(_handle);
        final tin = e == nullptr ? 'Laya không trả kết quả' : e.toDartString();
        if (e != nullptr) _tra(e);
        throw StateError(tin);
      }
      try {
        final j = jsonDecode(ra.toDartString()) as Map<String, dynamic>;
        return [for (final v in j['xac_suat'] as List) (v as num).toDouble()];
      } finally {
        _tra(ra);
      }
    } finally {
      calloc.free(pDoan);
      if (pThoai != nullptr) calloc.free(pThoai);
      calloc.free(pHuongDan);
      calloc.free(pLua);
    }
  }

  void dong() {
    if (_handle != nullptr) {
      _dong(_handle);
      _handle = nullptr;
    }
  }
}

class _YeuCau {
  const _YeuCau(this.cong, this.doanVan, this.thuMuc, this.thuVien, this.chuong, this.gioiDaBiet);
  final SendPort cong;
  final List<List<String>> doanVan;
  final String thuMuc;
  final String? thuVien;
  final Set<int>? chuong;
  final Map<String, String> gioiDaBiet;
}

void _chayPhanTich(_YeuCau y) {
  LayaNative? laya;
  try {
    laya = LayaNative.mo(y.thuMuc, thuVien: y.thuVien);
    phanTichNhanVat(
      y.doanVan,
      laya,
      chuong: y.chuong,
      gioiDaBiet: y.gioiDaBiet,
      tienDo: (xong, tong) => y.cong.send((xong, tong)),
    ).then((kq) {
      laya?.dong();
      y.cong.send(jsonEncode(kq.toJson()));
    }).catchError((Object e) {
      laya?.dong();
      y.cong.send('LOI:$e');
    });
  } catch (e) {
    laya?.dong();
    y.cong.send('LOI:$e');
  }
}

/// Phân tích nhân vật trong isolate riêng. [doanVan] là `doanVanCuaChuong` của TẤT CẢ các chương;
/// [chuong] là các chương cần hỏi Laya (null là cả cuốn). [tienDo] nhận (đã hỏi, tổng số câu thoại).
Future<KetQuaNhanVat> phanTichTrongNen({
  required List<List<String>> doanVan,
  required String thuMucLaya,
  String? thuVien,
  Set<int>? chuong,
  Map<String, String> gioiDaBiet = const {},
  void Function(int xong, int tong)? tienDo,
}) async {
  final nhan = ReceivePort();
  final xong = Completer<KetQuaNhanVat>();
  final nghe = nhan.listen((tin) {
    if (tin is (int, int)) {
      tienDo?.call(tin.$1, tin.$2);
    } else if (tin is String && tin.startsWith('LOI:')) {
      if (!xong.isCompleted) xong.completeError(StateError(tin.substring(4)));
    } else if (tin is String) {
      if (!xong.isCompleted) {
        xong.complete(KetQuaNhanVat.fromJson(jsonDecode(tin) as Map<String, dynamic>));
      }
    } else if (tin == null && !xong.isCompleted) {
      xong.completeError(StateError('Việc phân tích nhân vật dừng giữa chừng'));
    }
  });
  try {
    await Isolate.spawn(
      _chayPhanTich,
      _YeuCau(nhan.sendPort, doanVan, thuMucLaya, thuVien, chuong, gioiDaBiet),
      onExit: nhan.sendPort,
      errorsAreFatal: true,
      debugName: 'phan-tich-nhan-vat',
    );
    return await xong.future;
  } finally {
    await nghe.cancel();
    nhan.close();
  }
}
