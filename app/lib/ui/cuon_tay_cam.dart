/// Cho cần phải của tay cầm cuộn một trang danh sách.
///
/// Khung chữ trong màn hình Nghe cuộn theo CHỈ SỐ đoạn — mỗi nhịp một đoạn, vì
/// đó vừa đúng một nhịp mắt đọc (xem `reading_pane.dart`). Mấy trang còn lại
/// chỉ là danh sách thường nên cuộn theo pixel.
///
/// Nghe thẳng dòng lệnh qua [LenhTayCamScope] chứ không chờ tiêu điểm: trang
/// đang cuộn thì tiêu điểm thường đang nằm ở một nút nào đó, mà cuộn để ĐỌC thì
/// không được đụng tới tiêu điểm.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/tay_cam.dart';
import 'dieu_khien_tay_cam.dart';

/// Mỗi nhịp cuộn bao nhiêu phần khung nhìn.
///
/// Hơn một phần ba: đủ để đi hết trang dài trong vài nhịp, mà vẫn còn chừa lại
/// phần chữ cũ trên màn hình nên mắt không mất chỗ.
const double _phanCuon = 0.35;

class CuonTayCam extends StatefulWidget {
  const CuonTayCam({super.key, required this.controller, required this.child});

  final ScrollController controller;
  final Widget child;

  @override
  State<CuonTayCam> createState() => _CuonTayCamState();
}

class _CuonTayCamState extends State<CuonTayCam> {
  StreamSubscription<LenhTayCam>? _dang;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dang?.cancel();
    _dang = LenhTayCamScope.cua(context)?.listen(_nhan);
  }

  @override
  void dispose() {
    _dang?.cancel();
    super.dispose();
  }

  void _nhan(LenhTayCam lenh) {
    final buoc = switch (lenh) {
      LenhTayCam.cuonLen => -1,
      LenhTayCam.cuonXuong => 1,
      _ => 0,
    };
    if (buoc == 0 || !mounted) return;

    final dieu = widget.controller;
    if (!dieu.hasClients) return;
    final vi = dieu.position;
    final dich = (dieu.offset + buoc * vi.viewportDimension * _phanCuon)
        .clamp(vi.minScrollExtent, vi.maxScrollExtent);
    if (dich == dieu.offset) return; // đã ở đầu hoặc cuối trang

    dieu.animateTo(dich,
        duration: const Duration(milliseconds: 140), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
