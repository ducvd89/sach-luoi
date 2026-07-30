/// Bảng màu và kiểu chữ dùng chung.
///
/// Tông màu giấy cũ và cam trầm, dịu mắt khi đọc lâu, dùng chung cho cả chế độ
/// sáng lẫn tối.
library;

import 'package:flutter/material.dart';

const _seed = Color(0xFFC8752A);

ThemeData buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  final isDark = brightness == Brightness.dark;

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: isDark ? const Color(0xFF14171E) : const Color(0xFFF7F5F0),
    fontFamily: 'Segoe UI',
    visualDensity: VisualDensity.comfortable,
    cardTheme: CardThemeData(
      elevation: 0,
      color: isDark ? const Color(0xFF1C212C) : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: isDark ? const Color(0xFF2B3242) : const Color(0xFFE5E0D6)),
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
      color: isDark ? const Color(0xFF2B3242) : const Color(0xFFE5E0D6),
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
