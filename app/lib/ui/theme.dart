/// Bảng màu, kiểu chữ và ngưỡng bố cục dùng chung.
///
/// Chế độ sáng giữ tông giấy cũ và cam trầm, dịu mắt khi đọc lâu. Chế độ tối
/// chuyển sang nền tím thẫm cùng các cặp màu chuyển sắc — dùng cho nút và những
/// chỗ cần bắt mắt, chứ không phủ lên vùng chữ đang đọc.
library;

import 'package:flutter/material.dart';

const _seed = Color(0xFFC8752A);

/// Nền tối: tím thẫm chứ không phải xám xanh, cho các dải chuyển sắc nổi lên.
const namNen = Color(0xFF221A2E);
const namMat = Color(0xFF2C2340);

/// Các cặp màu chuyển sắc dùng cho nút.
///
/// Đặt tên theo việc chứ không theo màu: đổi màu sau này thì chỗ gọi khỏi sửa.
abstract final class SacNut {
  /// Việc chính của màn hình đang mở — đọc, xuất, tải.
  static const chinh = [Color(0xFFF7B267), Color(0xFFF25F5C)];

  /// Việc phụ, ít rủi ro — tìm, mở, xem.
  static const phu = [Color(0xFF5BE3B0), Color(0xFF54A0F5)];

  /// Việc mang tính thêm mới.
  static const them = [Color(0xFF8ED8F8), Color(0xFFC9A7F5)];

  /// Việc phá đi: xoá, huỷ.
  static const nguyHiem = [Color(0xFFF9738C), Color(0xFFD64550)];
}

/// Ngưỡng đổi bố cục, tính bằng dp.
///
/// Máy gập là lý do có chỗ này. Bản trước chặn ở 900 dp nên màn trong của Galaxy
/// Z Fold (khoảng 690 dp bề ngang) không bao giờ đạt — mở máy ra vẫn thấy giao
/// diện điện thoại. Màn ngoài của mấy máy đó chỉ khoảng 350-400 dp, nên 600 dp
/// tách được hai bên mà không cấn: gập lại là bố cục di động, mở ra là thanh
/// điều hướng dọc như bản máy tính.
bool manHinhRong(BuildContext context) => MediaQuery.sizeOf(context).width >= 600;

/// Đủ rộng để xếp hai cột: khung đọc bên trái, điều khiển bên phải.
///
/// Cao hơn [manHinhRong] vì hai cột cần chỗ thật. Màn trong máy gập lúc dựng
/// đứng (~690 dp) vẫn một cột, xoay ngang (~830 dp) thì tách đôi.
bool manHinhHaiCot(BuildContext context) => MediaQuery.sizeOf(context).width >= 720;

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final isDark = brightness == Brightness.dark;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? namNen : const Color(0xFFF7F5F0),
    fontFamily: 'Segoe UI',
    visualDensity: VisualDensity.comfortable,
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? namMat : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: isDark ? const Color(0xFF3B3252) : const Color(0xFFE5E0D6)),
      ),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? const Color(0xFF3B3252) : const Color(0xFFE5E0D6),
      space: 1,
      thickness: 1,
    ),
  );
}

/// Định dạng thời lượng thành 1:23:45 hoặc 4:05.
String formatTime(double seconds) {
  final total = seconds.isFinite && seconds > 0 ? seconds.round() : 0;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  String pad(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${pad(m)}:${pad(s)}' : '$m:${pad(s)}';
}
