/// Đọc tay cầm trên Windows bằng XInput.
///
/// XInput là API sẵn có của Windows từ bản 8, không phải cài thêm gì: gọi
/// `XInputGetState` với số khe (0-3) là nhận về trạng thái nút và cần gạt. Bản
/// binding nằm sẵn trong gói `win32` mà ứng dụng đã dùng cho việc khác.
///
/// Đây là đường DUY NHẤT trên Windows — tay cầm không gửi phím, nên không hỏi
/// thì không biết gì cả. Android thì ngược lại, xem `tay_cam.dart`.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'tay_cam.dart';

/// Mã lỗi khi khe ấy chưa cắm tay cầm nào.
const _khongCoThietBi = 1167; // ERROR_DEVICE_NOT_CONNECTED

/// Vùng chết do Microsoft đề nghị cho cần trái, trên thang 32767.
///
/// Chỉ dùng để cắt phần rung của cần khi thả tay; ngưỡng thật để tính là đã
/// nghiêng hay chưa nằm ở [BoDichTayCam], cao hơn nhiều.
const _vungChet = 7849;

/// Cò bấm sâu hơn mức này (thang 0-255) thì tính là đã bấm.
///
/// Đúng con số XINPUT_GAMEPAD_TRIGGER_THRESHOLD của Microsoft.
const _nguongCo = 30;

/// Mặt nạ nút trong `XINPUT_GAMEPAD.wButtons`.
const _nutA = 0x1000;
const _nutB = 0x2000;
const _nutX = 0x4000;
const _nutY = 0x8000;
const _dpadLen = 0x0001;
const _dpadXuong = 0x0002;
const _dpadTrai = 0x0004;
const _dpadPhai = 0x0008;
const _vaiTrai = 0x0100; // L1
const _vaiPhai = 0x0200; // R1

class NguonXInput implements NguonTayCam {
  Pointer<XINPUT_STATE>? _o;

  /// Khe đang có tay cầm. null nghĩa là chưa thấy khe nào.
  int? _khe;

  /// Còn bao nhiêu lượt hỏi nữa mới quét lại các khe khác.
  ///
  /// Quét cả bốn khe mỗi lượt là điều tài liệu XInput dặn đừng làm: hỏi vào khe
  /// trống tốn hơn hẳn khe có máy. Đã có tay cầm thì chỉ hỏi đúng khe của nó.
  var _demQuet = 0;

  @override
  bool get coTayCam => _khe != null;

  @override
  Future<void> mo(void Function() danhThuc) async {
    // XInput không đẩy tin, chỉ hỏi mới biết — không dùng tới danhThuc.
    if (!Platform.isWindows) return;
    _o ??= calloc<XINPUT_STATE>();
  }

  @override
  Future<void> dong() async {
    final o = _o;
    _o = null;
    if (o != null) calloc.free(o);
  }

  @override
  TrangThaiTayCam doc() {
    final o = _o;
    if (o == null || !Platform.isWindows) return TrangThaiTayCam.khong;

    final khe = _khe;
    if (khe != null) {
      final t = _docKhe(o, khe);
      if (t != null) return t;
      _khe = null; // vừa rút ra
    }

    // Chưa có tay cầm: mỗi lượt chỉ ngó một khe, xoay vòng.
    final thu = _demQuet % 4;
    _demQuet++;
    final t = _docKhe(o, thu);
    if (t != null) {
      _khe = thu;
      return t;
    }
    return TrangThaiTayCam.khong;
  }

  /// Trạng thái của một khe, null nếu khe ấy trống hoặc gọi lỗi.
  TrangThaiTayCam? _docKhe(Pointer<XINPUT_STATE> o, int khe) {
    final int ma;
    try {
      ma = XInputGetState(khe, o);
    } catch (_) {
      // Máy không có xinput1_4.dll (Windows quá cũ, hoặc bản dựng gọn) — coi
      // như không có tay cầm, ứng dụng vẫn chạy bình thường bằng chuột.
      return null;
    }
    if (ma == _khongCoThietBi || ma != NO_ERROR) return null;

    final pad = o.ref.Gamepad;
    final nut = pad.wButtons;

    // Phím mũi tên trên tay cầm quy về cùng một trục với cần gạt: bên trên chỉ
    // cần biết "đang nghiêng về đâu", không cần biết nghiêng bằng cái gì.
    var x = _truc(pad.sThumbLX);
    var y = _truc(pad.sThumbLY);
    if (nut & _dpadTrai != 0) x = -1;
    if (nut & _dpadPhai != 0) x = 1;
    if (nut & _dpadXuong != 0) y = -1;
    if (nut & _dpadLen != 0) y = 1;

    return TrangThaiTayCam(
      x: x,
      y: y,
      xPhai: _truc(pad.sThumbRX),
      yPhai: _truc(pad.sThumbRY),
      chon: nut & _nutA != 0,
      quayLai: nut & _nutB != 0,
      phatDung: nut & _nutY != 0,
      moChuong: nut & _nutX != 0,
      // L1 và L2 làm cùng một việc nên gộp luôn từ đây.
      vaiTrai: nut & _vaiTrai != 0 || pad.bLeftTrigger > _nguongCo,
      vaiPhai: nut & _vaiPhai != 0 || pad.bRightTrigger > _nguongCo,
    );
  }

  /// Số nguyên 16 bit của XInput -> -1..1, đã cắt vùng chết.
  double _truc(int tho) {
    if (tho.abs() < _vungChet) return 0;
    return (tho / 32767).clamp(-1.0, 1.0);
  }
}
