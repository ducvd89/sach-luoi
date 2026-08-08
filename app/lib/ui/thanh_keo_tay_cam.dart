/// Thanh kéo chỉnh được bằng tay cầm.
///
/// Vì sao phải có chế độ riêng: trái/phải bình thường là đi giữa các điểm chọn,
/// nên nếu thanh kéo cũng ăn trái/phải ngay khi được trỏ tới thì hoặc mất đường
/// đi tiếp, hoặc mất đường chỉnh. Cách quen thuộc của máy chơi game là bấm vào
/// rồi mới chỉnh:
///
///   A  vào chế độ chỉnh · trái/phải đổi giá trị · A chốt · B bỏ, trả về như cũ
///
/// Trong lúc chỉnh thì lên/xuống cũng bị giữ lại — không thì đẩy chệch một cái
/// là tiêu điểm bỏ đi mất, để lại một giá trị sửa dở không ai chốt.
library;

import 'package:flutter/material.dart';

import 'dieu_khien_tay_cam.dart';

class ThanhKeoTayCam extends StatefulWidget {
  const ThanhKeoTayCam({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.focusNode,
    this.autofocus = false,
  });

  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String? label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<ThanhKeoTayCam> createState() => _ThanhKeoTayCamState();
}

class _ThanhKeoTayCamState extends State<ThanhKeoTayCam> {
  var _dangChinh = false;

  /// Giá trị lúc vừa vào chế độ chỉnh, để nút B trả về đúng chỗ ấy.
  double? _giaTriCu;

  /// Một lần bấm trái/phải đi bao nhiêu.
  ///
  /// Có nấc thì đi đúng một nấc; không có nấc thì chia dải làm 20 bậc — đủ mịn
  /// mà vẫn đi hết dải trong một cái đẩy giữ.
  double get _buoc {
    final nac = widget.divisions;
    final dai = widget.max - widget.min;
    return nac != null && nac > 0 ? dai / nac : dai / 20;
  }

  /// A: chưa chỉnh thì vào chế độ chỉnh, đang chỉnh thì chốt và ra.
  bool _bamA() {
    if (_dangChinh) {
      widget.onChangeEnd?.call(widget.value);
      setState(() {
        _dangChinh = false;
        _giaTriCu = null;
      });
    } else {
      setState(() {
        _dangChinh = true;
        _giaTriCu = widget.value;
      });
    }
    return true;
  }

  /// B: bỏ, trả giá trị về như trước khi chỉnh.
  bool? _bamB() {
    if (!_dangChinh) return null; // để bên ngoài lo việc quay lại màn hình
    final cu = _giaTriCu;
    if (cu != null && cu != widget.value) {
      widget.onChanged(cu);
      widget.onChangeEnd?.call(cu);
    }
    setState(() {
      _dangChinh = false;
      _giaTriCu = null;
    });
    return true;
  }

  bool? _huong(TraversalDirection huong) {
    if (!_dangChinh) return null; // chưa vào chỉnh thì trái/phải vẫn là đi lại
    switch (huong) {
      case TraversalDirection.left:
        _doi(-_buoc);
      case TraversalDirection.right:
        _doi(_buoc);
      case TraversalDirection.up:
      case TraversalDirection.down:
        break; // giữ tiêu điểm ở đây tới khi chốt hoặc bỏ
    }
    return true;
  }

  void _doi(double them) {
    final moi = (widget.value + them).clamp(widget.min, widget.max);
    if (moi != widget.value) widget.onChanged(moi);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Actions(
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _bamA()),
        HuongTayCamIntent: CallbackAction<HuongTayCamIntent>(
          onInvoke: (intent) => _huong(intent.huong),
        ),
        ThoatTayCamIntent: CallbackAction<ThoatTayCamIntent>(onInvoke: (_) => _bamB()),
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Slider(
            value: widget.value.clamp(widget.min, widget.max),
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            label: widget.label,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            // Đang chỉnh bằng tay cầm thì tô đậm hơn cho thấy rõ nó đang "mở".
            activeColor: _dangChinh ? scheme.primary : null,
            thumbColor: _dangChinh ? scheme.primary : null,
            onChanged: widget.onChanged,
            onChangeEnd: widget.onChangeEnd,
          ),
          if (_dangChinh)
            Padding(
              padding: const EdgeInsets.only(left: 24, bottom: 2),
              child: Text(
                '◀ ▶ chỉnh · A xong · B bỏ',
                style: TextStyle(fontSize: 11.5, color: scheme.primary),
              ),
            ),
        ],
      ),
    );
  }
}
