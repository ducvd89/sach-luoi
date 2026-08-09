/// Thư mục xuất file do người dùng tự chọn — chỉ Android.
///
/// Trên máy tính thì `outputDir` của job là một đường dẫn thật và mọi thứ ghi
/// thẳng bằng dart:io. Android không cho như vậy: từ Android 10 không ghi được
/// vào bộ nhớ chung bằng File API, còn thư mục riêng của app thì từ Android 11
/// chính người dùng cũng không mở ra xem được.
///
/// Nên trên Android có hai đường tới đích, cùng đi qua kênh `sachnoi/ma_hoa`:
///
///   * mặc định — MediaStore đưa file vào `Music/Sách lười/<tên sách>`;
///   * người dùng chọn thư mục — Storage Access Framework trả về một "tree URI",
///     app xin quyền giữ lại được rồi ghi vào đúng cây thư mục đó.
///
/// Cả hai đường đều chỉ chạy ở bước cuối, sau khi file đã ghi và nén xong trong
/// vùng riêng của app.
library;

import 'package:flutter/services.dart';

const _kenh = MethodChannel('sachnoi/ma_hoa');

/// Mở màn hình chọn thư mục của hệ thống.
///
/// Trả về tree URI đã xin được quyền ghi lâu dài, hoặc null nếu người dùng bấm
/// quay lại. Ném [ThuMucException] nếu máy không mở được trình chọn.
Future<String?> chonThuMuc() async {
  try {
    return await _kenh.invokeMethod<String>('chonThuMuc');
  } on PlatformException catch (err) {
    throw ThuMucException(err.message ?? '$err');
  } on MissingPluginException {
    throw const ThuMucException('Bản này chưa nối phần chọn thư mục');
  }
}

/// Tên thư mục để hiện lên giao diện.
Future<String> tenThuMuc(String cay) async {
  try {
    final ra = await _kenh.invokeMethod<String>('tenThuMuc', {'cay': cay});
    return (ra == null || ra.isEmpty) ? 'thư mục đã chọn' : ra;
  } catch (_) {
    return 'thư mục đã chọn';
  }
}

/// Quyền ghi vào [cay] còn không.
///
/// Người dùng rút quyền được trong Cài đặt của máy, và gỡ app thì mất — hỏi
/// trước khi bắt đầu xuất, đừng để chạy nửa tiếng rồi mới vỡ.
Future<bool> conQuyenThuMuc(String cay) async {
  try {
    return await _kenh.invokeMethod<bool>('conQuyenThuMuc', {'cay': cay}) ?? false;
  } catch (_) {
    return false;
  }
}

/// Chép [nguon] vào `[cay]/[thuMucCon]/[tenFile]`, xoá bản gốc.
///
/// Trả về đường dẫn để hiện cho người dùng.
Future<String> chepVaoThuMuc({
  required String nguon,
  required String cay,
  required String thuMucCon,
  required String tenFile,
}) async {
  try {
    final ra = await _kenh.invokeMethod<String>('chepVaoThuMuc', {
      'nguon': nguon,
      'cay': cay,
      'thuMucCon': thuMucCon,
      'tenFile': tenFile,
    });
    if (ra == null || ra.isEmpty) throw const ThuMucException('Không nhận được đường dẫn đích');
    return ra;
  } on PlatformException catch (err) {
    throw ThuMucException(err.message ?? '$err');
  } on MissingPluginException {
    throw const ThuMucException('Bản này chưa nối phần chọn thư mục');
  }
}

class ThuMucException implements Exception {
  const ThuMucException(this.message);
  final String message;

  @override
  String toString() => message;
}
