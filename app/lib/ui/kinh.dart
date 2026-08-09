/// Vật liệu kính — nền mờ nhìn xuyên qua, viền sáng ở mép.
///
/// Lấy ý từ Liquid Glass: tấm kính lấy màu từ thứ nằm sau nó, và mép bắt sáng
/// nên nổi lên khỏi nền mà không cần đổ bóng. Nói cho đúng thì đây là kính mờ
/// cộng viền chói, chưa có phần bẻ cong ánh sáng ở rìa — cái đó phải viết shader
/// lấy mẫu nền, tốn thêm một lượt dựng ảnh nữa nên để sau khi đo xong cái này.
///
/// Hai điều kiện để nó ra dáng kính, thiếu một là công cốc:
///
///  * Phải có thứ gì đó CHUYỂN ĐỘNG phía sau. Kính đặt trên nền phẳng một màu
///    thì nhìn y hệt một mảng xám. Vì vậy thanh điều hướng và thanh phát được
///    cho nổi lên trên nội dung thay vì nằm cạnh nó.
///  * Đừng chồng lớp. Mỗi [Kinh] bắt engine dựng lại vùng nền phía sau vào một
///    lớp riêng; lồng hai ba lớp vào nhau là nhân chi phí lên. Máy đang chạy mô
///    hình đọc bằng cả bốn luồng CPU, không dư sức cho việc đó.
library;

import 'dart:ui';

import 'package:flutter/material.dart';

/// Tấm kính bo góc.
class Kinh extends StatelessWidget {
  const Kinh({
    super.key,
    required this.child,
    this.bo = 18,
    this.mo = 18,
    this.dam,
    this.vien = true,
    this.padding,
  });

  final Widget child;

  /// Bán kính bo góc.
  final double bo;

  /// Độ mờ của nền phía sau.
  final double mo;

  /// Độ đậm của lớp phủ. Null thì lấy theo nền sáng hay tối.
  final double? dam;

  final bool vien;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final toi = Theme.of(context).brightness == Brightness.dark;
    // Cả hai nền đều phủ TRẮNG — kính bắt sáng chứ không đổ bóng. Khác nhau ở
    // độ đậm: nền tối chỉ cần một lớp mỏng, nền sáng phải dày hơn mới thấy.
    const sac = Colors.white;
    final d = dam ?? (toi ? 0.10 : 0.55);
    final r = BorderRadius.circular(bo);

    return ClipRRect(
      borderRadius: r,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: mo, sigmaY: mo),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: r,
            // Dốc từ trên trái xuống dưới phải: mắt đọc ra ngay là một mặt cong
            // đang hứng sáng, chứ không phải một ô chữ nhật phẳng.
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [sac.withValues(alpha: d + 0.06), sac.withValues(alpha: d * 0.55)],
            ),
            border: vien
                ? Border.all(color: sac.withValues(alpha: toi ? 0.18 : 0.65), width: 1)
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Tấm kính tròn, cho nút bấm.
class KinhTron extends StatelessWidget {
  const KinhTron({super.key, required this.child, this.canh = 44, this.mo = 16, this.dam});

  final Widget child;
  final double canh;
  final double mo;
  final double? dam;

  @override
  Widget build(BuildContext context) {
    final toi = Theme.of(context).brightness == Brightness.dark;
    final d = dam ?? (toi ? 0.12 : 0.55);
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: mo, sigmaY: mo),
        child: Container(
          width: canh,
          height: canh,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Colors.white.withValues(alpha: d + 0.08), Colors.white.withValues(alpha: d * 0.5)],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: toi ? 0.20 : 0.65), width: 1),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Thanh tiến trình bằng kính: rãnh trong mờ, phần đã chạy là dải chuyển sắc.
class ThanhKinh extends StatelessWidget {
  const ThanhKinh({
    super.key,
    required this.phan,
    required this.sac,
    this.cao = 7,
    this.mo = 10,
  });

  /// Phần đã chạy, từ 0 tới 1.
  final double phan;
  final List<Color> sac;
  final double cao;
  final double mo;

  @override
  Widget build(BuildContext context) {
    final toi = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(cao),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: mo, sigmaY: mo),
        child: Container(
          height: cao,
          // Phải nói rõ trải hết bề ngang: trong Stack hay Column, ô chỉ đặt
          // chiều cao sẽ nhận ràng buộc lỏng rồi co về bề rộng 0 — thanh biến mất.
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(cao),
            color: Colors.white.withValues(alpha: toi ? 0.12 : 0.45),
            border: Border.all(color: Colors.white.withValues(alpha: toi ? 0.16 : 0.6), width: 0.8),
          ),
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: phan.clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(cao),
                gradient: LinearGradient(colors: sac),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
