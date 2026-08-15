/// Lớp phủ khoá cảm ứng: chắn mọi thao tác cho tới khi trượt để mở.
///
/// Bọc NGOÀI Navigator gốc (xem `main.dart`) nên nó che cả hộp thoại và bảng mở
/// từ dưới lên — cùng lý do với `DieuKhienTayCam`. Đặt trong từng trang thì mở
/// một hộp thoại là lọt ra ngoài lớp khoá.
library;

import 'package:flutter/material.dart';

import 'app_scope.dart';
import 'theme.dart';

/// Trượt qua bao nhiêu phần của rãnh thì coi là mở.
///
/// 0,75 chứ không phải chạm đáy: kéo hết cỡ đòi ngón tay đi đúng tới mép, mà
/// người đang nằm nghe sách thì cầm máy một tay. Ba phần tư đã đủ xa để không
/// ai vô tình quệt trúng.
const double nguongMoKhoa = 0.75;

/// Đổi toạ độ ngón tay trên rãnh thành tiến độ 0–1.
///
/// Tách ra thành hàm thuần để kiểm được: tính sai chỗ này là núm trôi lệch khỏi
/// ngón, người dùng phải kéo xa hơn hẳn chỗ nhìn thấy — đúng lỗi của bản trước,
/// mà nhìn code thì không thấy gì bất thường.
///
/// [x] tính từ mép trái rãnh. Núm rộng [duongKinh] và tâm nó phải trùng ngón,
/// nên quãng chạy thật chỉ là phần còn lại sau khi trừ núm và hai bên lề.
double tienDoTuToaDo(double x, {
  required double rong,
  required double duongKinh,
  required double le,
}) {
  final quangDuong = rong - duongKinh - le * 2;
  if (quangDuong <= 0) return 0;
  return ((x - duongKinh / 2 - le) / quangDuong).clamp(0.0, 1.0);
}

class KhoaManHinh extends StatelessWidget {
  const KhoaManHinh({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final khoa = state.khoaCamUng;

    return Stack(
      children: [
        // AbsorbPointer chứ không chỉ đặt lớp phủ lên trên: lớp phủ chặn được
        // chạm ở chỗ nó vẽ, nhưng cử chỉ cuộn có thể vẫn tới được danh sách bên
        // dưới. Chặn thẳng ở đây thì không còn đường nào lọt.
        AbsorbPointer(absorbing: khoa, child: child),
        if (khoa)
          Positioned.fill(
            child: _LopKhoa(onMo: () => AppScope.read(context).moKhoaCamUng()),
          ),
      ],
    );
  }
}

class _LopKhoa extends StatefulWidget {
  const _LopKhoa({required this.onMo});
  final VoidCallback onMo;

  @override
  State<_LopKhoa> createState() => _LopKhoaState();
}

class _LopKhoaState extends State<_LopKhoa> {
  /// Đã kéo được bao nhiêu phần rãnh, 0–1.
  double _keo = 0;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      child: SafeArea(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.lock_outline, size: 46, color: Colors.white.withValues(alpha: 0.85)),
            const SizedBox(height: 14),
            Text(
              'Đã khoá cảm ứng',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Đang nghe vẫn chạy bình thường',
              style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.6)),
            ),
            const SizedBox(height: 34),
            _Ranh(
              keo: _keo,
              onKeo: (v) => setState(() => _keo = v),
              onMo: widget.onMo,
            ),
          ],
        ),
      ),
    );
  }
}

/// Rãnh trượt để mở.
class _Ranh extends StatelessWidget {
  const _Ranh({required this.keo, required this.onKeo, required this.onMo});

  final double keo;
  final ValueChanged<double> onKeo;
  final VoidCallback onMo;

  static const double _cao = 62;
  static const double _le = 5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, khung) {
        final rong = khung.maxWidth.clamp(0.0, 340.0);
        final duongKinh = _cao - _le * 2;
        final quangDuong = rong - duongKinh - _le * 2;

        // Bám theo VỊ TRÍ ngón tay trên rãnh, không cộng dồn delta.
        //
        // Bản trước cộng `delta.dx` rồi chia cho quãng đường giả định, nên núm
        // trôi lệch dần khỏi ngón và phải kéo xa hơn hẳn chỗ nhìn thấy. Quy
        // thẳng từ toạ độ thì núm luôn nằm đúng dưới ngón — không còn chỗ nào
        // để lệch.
        double tuToaDo(double x) =>
            tienDoTuToaDo(x, rong: rong, duongKinh: duongKinh, le: _le);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Bắt cả rãnh chứ không riêng cái núm: đặt ngón vào giữa rãnh rồi kéo
          // cũng chạy, khỏi phải chạm trúng núm mới bắt đầu được.
          onHorizontalDragStart: (d) => onKeo(tuToaDo(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) {
            if (quangDuong <= 0) return;
            onKeo(tuToaDo(d.localPosition.dx));
          },
          onHorizontalDragEnd: (_) {
            if (keo >= nguongMoKhoa) {
              onMo();
            } else {
              // Chưa đủ xa thì trả núm về chỗ cũ, đừng để nó đứng lửng giữa
              // rãnh trông như bị kẹt.
              onKeo(0);
            }
          },
          child: SizedBox(
            width: rong,
            height: _cao,
            child: Stack(
              children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(_cao),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                ),
                alignment: Alignment.center,
                child: Padding(
                  // Chừa chỗ cho núm để chữ không bị nó đè lên.
                  padding: EdgeInsets.only(left: duongKinh),
                  child: Opacity(
                    // Kéo càng xa thì chữ càng mờ đi — phản hồi liên tục, người
                    // dùng biết mình đang đi đúng hướng.
                    opacity: (1 - keo * 1.4).clamp(0.0, 1.0),
                    child: Text(
                      'Trượt để mở khoá',
                      style: TextStyle(
                        fontSize: 14.5,
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ),
              ),
              // Núm giờ chỉ là hình vẽ — cử chỉ do cả rãnh bắt, nên không còn
              // chuyện phải chạm trúng núm mới kéo được.
              Positioned(
                left: _le + quangDuong * keo,
                top: _le,
                child: Container(
                  width: duongKinh,
                  height: duongKinh,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: SacNut.nguyHiem),
                  ),
                  child: Icon(
                    keo >= nguongMoKhoa ? Icons.lock_open : Icons.lock_outline,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),
              ],
            ),
          ),
        );
      },
    );
  }
}
