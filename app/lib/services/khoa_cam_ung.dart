/// Khoá cảm ứng khi nghe: chắn mọi thao tác cho tới khi trượt để mở.
///
/// Sinh ra cho cảnh nghe sách lúc bỏ máy vào túi hay để cạnh gối — chạm nhầm
/// một cái là nhảy đoạn hoặc dừng phát. Khoá lại thì cả giao diện không nhận
/// thao tác nào ngoài chính động tác trượt mở.
///
/// Đi kèm hai việc mà phần Kotlin lo (xem `MainActivity.khoaManHinh`):
///
/// * **Hạ sáng còn 10%** — nghe thì không nhìn, mà màn hình sáng là thứ ngốn pin
///   nhiều nhất trên điện thoại.
/// * **Giữ màn hình không tắt** — nghe xong một đoạn còn muốn liếc xem đang tới
///   chương nào; để máy tự khoá thì mở lại phải qua vân tay, phiền hơn là trượt.
///
/// Chỉ có trên Android: hạ sáng cửa sổ là API của Android, còn trên máy tính thì
/// chạm nhầm cũng không phải vấn đề — xem [khoaCamUngDungDuoc].
library;

import 'dart:io';

import 'package:flutter/services.dart';

const _kenh = MethodChannel('sachnoi/khoa_cam_ung');

/// Nền tảng này dùng được khoá cảm ứng không.
bool get khoaCamUngDungDuoc => Platform.isAndroid;

/// Mức sáng lúc khoá, theo thang 0–1 của `WindowManager.LayoutParams`.
///
/// 10% chứ không phải 0: tắt hẳn thì nhìn như máy hỏng, người dùng tưởng treo
/// rồi bấm nút nguồn — mà đó đúng là thứ khoá cảm ứng sinh ra để tránh.
const _doSangKhiKhoa = 0.1;

/// Bật chế độ khoá: hạ sáng và giữ màn hình luôn bật.
Future<void> batKhoaManHinh() async {
  if (!khoaCamUngDungDuoc) return;
  try {
    await _kenh.invokeMethod<void>('bat', {'doSang': _doSangKhiKhoa});
  } on PlatformException {
    // Không hạ sáng được thì vẫn khoá cảm ứng như thường — lớp chắn nằm bên
    // Dart, không phụ thuộc việc này.
  }
}

/// Tắt chế độ khoá: trả độ sáng về mức hệ thống và thôi giữ màn hình.
Future<void> tatKhoaManHinh() async {
  if (!khoaCamUngDungDuoc) return;
  try {
    await _kenh.invokeMethod<void>('tat');
  } on PlatformException {
    // Bỏ qua: Android tự trả độ sáng khi ứng dụng rời tiền cảnh.
  }
}
