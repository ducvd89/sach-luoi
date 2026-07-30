/// Thanh cuộn to, kéo được bằng ngón tay.
///
/// Thanh cuộn mặc định của Flutter trên điện thoại chỉ vài pixel và không nhận
/// thao tác kéo, nên muốn đi từ chương 1 đến chương 2000 phải vuốt hàng trăm
/// lần. Thanh này rộng 38 px, kéo được, và chạm chỗ nào là nhảy tới đó.
///
/// Nhảy theo **chỉ số phần tử** chứ không theo pixel: danh sách chương cao thấp
/// khác nhau nên tính theo pixel sẽ lệch, còn theo chỉ số thì luôn đúng.
library;

import 'package:flutter/material.dart';

class FastScrollBar extends StatefulWidget {
  const FastScrollBar({
    super.key,
    required this.count,
    required this.firstVisible,
    required this.onJump,
    this.labelBuilder,
  });

  final int count;

  /// Phần tử đầu tiên đang hiện trên màn hình — dùng để đặt vị trí con trượt.
  final int firstVisible;

  final void Function(int row) onJump;

  /// Nhãn hiện lúc đang kéo. Với danh sách dài thì con số thứ tự không đủ để
  /// biết mình đang ở đâu; trả về tên chương thì kéo mới có đích.
  final String Function(int row)? labelBuilder;

  @override
  State<FastScrollBar> createState() => _FastScrollBarState();
}

class _FastScrollBarState extends State<FastScrollBar> {
  static const _width = 38.0;
  static const _thumbHeight = 56.0;

  bool _dragging = false;

  void _jumpFromOffset(double dy, double height) {
    final usable = (height - _thumbHeight).clamp(1.0, double.infinity);
    final fraction = ((dy - _thumbHeight / 2) / usable).clamp(0.0, 1.0);
    widget.onJump((fraction * (widget.count - 1)).round());
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final fraction = widget.count <= 1 ? 0.0 : widget.firstVisible / (widget.count - 1);
        final top = fraction.clamp(0.0, 1.0) * (height - _thumbHeight);
        final label = widget.labelBuilder?.call(widget.firstVisible);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (d) {
            setState(() => _dragging = true);
            _jumpFromOffset(d.localPosition.dy, height);
          },
          onVerticalDragUpdate: (d) => _jumpFromOffset(d.localPosition.dy, height),
          onVerticalDragEnd: (_) => setState(() => _dragging = false),
          onVerticalDragCancel: () => setState(() => _dragging = false),
          // Chạm một chỗ bất kỳ trên thanh cũng nhảy tới đó.
          onTapDown: (d) => _jumpFromOffset(d.localPosition.dy, height),
          child: SizedBox(
            width: _width,
            height: height,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: top,
                  left: _dragging ? 4 : 12,
                  right: 6,
                  height: _thumbHeight,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    decoration: BoxDecoration(
                      color: _dragging ? scheme.primary : scheme.primary.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(99),
                    ),
                    child: _dragging
                        ? Center(
                            child: Text(
                              '${widget.firstVisible + 1}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: scheme.onPrimary,
                              ),
                            ),
                          )
                        : null,
                  ),
                ),
                // Nhãn nằm bên trái thanh, tràn ra ngoài khung thanh cuộn để đủ
                // chỗ cho tên chương dài.
                if (_dragging && label != null && label.isNotEmpty)
                  Positioned(
                    top: (top + _thumbHeight / 2 - 17).clamp(0.0, height - 34),
                    right: _width - 2,
                    child: Material(
                      elevation: 3,
                      color: scheme.inverseSurface,
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 210),
                          child: Text(
                            label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12.5, color: scheme.onInverseSurface),
                          ),
                        ),
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
