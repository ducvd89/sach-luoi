/// Nút chuyển sắc: chữ bên trái, biểu tượng nằm trong vòng tròn bên phải.
///
/// Lấy ý từ bộ nút mẫu: viên thuốc bo tròn hết cỡ, nền chuyển sắc, và cái vòng
/// tròn ở đầu bên phải làm chỗ đặt biểu tượng. Vòng tròn ấy mới là thứ khiến nút
/// dễ nhận ra từ xa — nhìn hình biết việc, khỏi phải đọc chữ.
///
/// Có hai kiểu: nền đặc cho việc chính của màn hình, và viền rỗng cho việc phụ.
/// Một màn hình chỉ nên có MỘT nút nền đặc, không thì chẳng còn gì nổi bật.
library;

import 'package:flutter/material.dart';

import 'theme.dart';

class NutSac extends StatelessWidget {
  const NutSac({
    super.key,
    required this.nhan,
    required this.hinh,
    this.onNhan,
    this.sac = SacNut.chinh,
    this.vienRong = false,
    this.dangChay = false,
    this.rongHet = false,
    this.nho = false,
  });

  final String nhan;
  final IconData hinh;
  final VoidCallback? onNhan;

  /// Cặp màu chuyển sắc, xem [SacNut].
  final List<Color> sac;

  /// Viền rỗng thay vì nền đặc — dùng cho việc phụ.
  final bool vienRong;

  /// Đang chạy: thay biểu tượng bằng vòng quay và chặn bấm.
  final bool dangChay;

  /// Chiếm hết bề ngang chỗ đặt nó.
  final bool rongHet;

  /// Cỡ nhỏ, cho những chỗ chật như trong thẻ sách hay hàng nút phụ.
  final bool nho;

  static const double _cao = 52;
  static const double _caoNho = 40;

  @override
  Widget build(BuildContext context) {
    final cao = nho ? _caoNho : _cao;
    final tat = onNhan == null || dangChay;
    final toi = Theme.of(context).brightness == Brightness.dark;
    // Nút tắt vẫn giữ hình dáng, chỉ nhạt đi — đổi hẳn sang xám thì người dùng
    // không đoán được nó sẽ thành cái gì khi bật lại.
    final doDam = tat ? 0.38 : 1.0;

    final chuyenSac = LinearGradient(
      colors: [sac.first.withValues(alpha: doDam), sac.last.withValues(alpha: doDam)],
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
    );

    // Viền rỗng: một lớp chuyển sắc, khoét ruột bằng đúng màu nền. Rẻ hơn nhiều
    // so với tự vẽ viền chuyển sắc, mà nhìn không khác.
    final chuChinh = vienRong
        ? (toi ? Colors.white : const Color(0xFF2A2233))
        : Colors.white;

    Widget ruot = Row(
      mainAxisSize: rongHet ? MainAxisSize.max : MainAxisSize.min,
      children: [
        SizedBox(width: nho ? 15 : 22),
        // Chỉ bọc Flexible khi nút trải hết bề ngang. Nút tự co mà đặt trong một
        // Row khác thì ràng buộc bề ngang là vô hạn, mà flex gặp vô hạn là vỡ bố
        // cục — bản dựng phát hành không báo gì, nút chỉ lặng lẽ biến mất.
        _MaybeFlexible(
          flexible: rongHet,
          child: Text(
            nhan,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: nho ? 13 : 14.5,
              letterSpacing: nho ? 0.2 : 0.6,
              fontWeight: FontWeight.w600,
              color: chuChinh.withValues(alpha: doDam),
            ),
          ),
        ),
        SizedBox(width: nho ? 8 : 14),
        Padding(
          padding: EdgeInsets.all(nho ? 4 : 5),
          child: _VongTron(
            canh: cao - (nho ? 8 : 10),
            hinh: hinh,
            sac: sac,
            vienRong: vienRong,
            dangChay: dangChay,
            doDam: doDam,
          ),
        ),
      ],
    );

    if (vienRong) {
      ruot = Container(
        margin: const EdgeInsets.all(1.6),
        decoration: BoxDecoration(
          color: toi ? namNen : const Color(0xFFF7F5F0),
          borderRadius: BorderRadius.circular(cao),
        ),
        child: ruot,
      );
    }

    return Semantics(
      button: true,
      enabled: !tat,
      label: nhan,
      child: Container(
        height: cao,
        width: rongHet ? double.infinity : null,
        decoration: BoxDecoration(
          gradient: chuyenSac,
          borderRadius: BorderRadius.circular(cao),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: tat ? null : onNhan,
            child: ruot,
          ),
        ),
      ),
    );
  }
}

/// Vòng tròn đặt biểu tượng ở đầu bên phải.
class _VongTron extends StatelessWidget {
  const _VongTron({
    required this.canh,
    required this.hinh,
    required this.sac,
    required this.vienRong,
    required this.dangChay,
    required this.doDam,
  });

  final double canh;
  final IconData hinh;
  final List<Color> sac;
  final bool vienRong;
  final bool dangChay;
  final double doDam;

  @override
  Widget build(BuildContext context) {
    // Kiểu nền đặc: vòng tròn tối màu để hình nổi lên trên nền sáng của nút.
    // Kiểu viền rỗng: vòng tròn mang chính màu chuyển sắc, vì ruột nút trong suốt.
    return Container(
      width: canh,
      height: canh,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: vienRong ? null : Colors.black.withValues(alpha: 0.22 * doDam),
        gradient: vienRong
            ? LinearGradient(
                colors: [
                  sac.first.withValues(alpha: doDam),
                  sac.last.withValues(alpha: doDam),
                ],
              )
            : null,
      ),
      child: dangChay
          ? Padding(
              padding: EdgeInsets.all(canh * 0.28),
              child: const CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
            )
          : Icon(hinh, size: canh * 0.48, color: Colors.white.withValues(alpha: doDam)),
    );
  }
}

/// Nút tròn chuyển sắc — dùng cho nút phát ở giữa hàng điều khiển.
///
/// Cùng ngôn ngữ với [NutSac]: chính cái vòng tròn chuyển sắc là thứ nhận ra
/// được từ xa. Ở đây không có chữ nên vòng tròn tự đứng một mình.
class NutTron extends StatelessWidget {
  const NutTron({
    super.key,
    required this.hinh,
    this.onNhan,
    this.sac = SacNut.chinh,
    this.canh = 56,
    this.chuThich,
  });

  final IconData hinh;
  final VoidCallback? onNhan;
  final List<Color> sac;
  final double canh;
  final String? chuThich;

  @override
  Widget build(BuildContext context) {
    final tat = onNhan == null;
    final doDam = tat ? 0.38 : 1.0;
    final nut = Container(
      width: canh,
      height: canh,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [sac.first.withValues(alpha: doDam), sac.last.withValues(alpha: doDam)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onNhan,
          child: Icon(hinh, size: canh * 0.48, color: Colors.white.withValues(alpha: doDam)),
        ),
      ),
    );
    return chuThich == null ? nut : Tooltip(message: chuThich!, child: nut);
  }
}


/// Bọc [Flexible] khi và chỉ khi cần — xem chỗ gọi trong [NutSac].
class _MaybeFlexible extends StatelessWidget {
  const _MaybeFlexible({required this.flexible, required this.child});
  final bool flexible;
  final Widget child;

  @override
  Widget build(BuildContext context) => flexible ? Flexible(child: child) : child;
}

/// Vòng tròn chuyển sắc bọc một biểu tượng. Không bấm được — chỉ để đánh dấu.
///
/// Dùng cho mục đang chọn trên thanh điều hướng: cùng một dấu hiệu với vòng tròn
/// ở đầu các nút, nên nhìn là biết "chỗ này đang được chọn" mà không cần đọc chữ.
class HinhTronSac extends StatelessWidget {
  const HinhTronSac({
    super.key,
    required this.hinh,
    this.sac = SacNut.chinh,
    this.canh = 40,
  });

  final IconData hinh;
  final List<Color> sac;
  final double canh;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: canh,
      height: canh,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: sac,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(hinh, size: canh * 0.5, color: Colors.white),
    );
  }
}
