/// Đối chiếu số âm từ wav2vec2 với số âm tiết mà văn bản đáng lẽ đọc ra.
///
/// Nhận dạng chạy ở isolate riêng (services/kiem_am), còn phép so ở đây là
/// thuần dữ liệu. Chưa nhận dạng được KHÔNG có nghĩa là đạt; bên nghe/xuất có
/// thể tiếp tục dùng âm thanh nhưng phải giữ trạng thái «chưa kiểm».
library;

const double tiLeAmToiThieu = 1.0;
const double tiLeAmToiDa = 1.1;

class KetQuaKiemAm {
  const KetQuaKiemAm({
    required this.soTu,
    required this.soAm,
    this.amVi = '',
    this.lyDoBoQua,
  });

  /// Tên cũ giữ lại vì đã được lưu trong job.json; đây là số ÂM TIẾT văn bản.
  final int soTu;
  final int? soAm;
  final String amVi;
  final String? lyDoBoQua;
  bool get daKiem => soAm != null;
  double get tiLe => soTu == 0 ? (soAm == 0 ? 1 : 0) : (soAm ?? 0) / soTu;
  double get lech => daKiem ? (tiLe - 1).abs() : double.infinity;

  /// Chỉ đạt khi nhận đủ 100–110% số âm dự kiến, kể cả câu ngắn.
  /// Số dự kiến đã bao gồm âm tiết tiếng Anh do demAmChu ước lượng.
  /// Âm thanh trắng không đạt với bất kỳ câu có tiếng nào, kể cả câu một từ.
  bool get dat {
    final am = soAm;
    if (am == null) return false;
    if (soTu == 0) return am == 0;
    if (am == 0) return false;
    return tiLe >= tiLeAmToiThieu && tiLe <= tiLeAmToiDa;
  }

  @override
  String toString() => daKiem
      ? '$soAm/$soTu âm (${(tiLe * 100).round()}%)'
      : 'Chưa kiểm âm: $lyDoBoQua';
}
