/// Tiến trình của một việc chạy lâu (nhập sách, xuất MP3).
///
/// Việc nặng chạy ở isolate nền, chỉ gửi về từng mốc để giao diện vẽ thanh tiến
/// trình. Nhờ vậy cửa sổ luôn phản hồi và Windows không báo "Not Responding".
library;

class WorkProgress {
  const WorkProgress(this.phase, {this.value});

  /// Đang làm gì — hiện ngay cạnh thanh tiến trình.
  final String phase;

  /// Từ 0 đến 1, hoặc null khi chưa biết tổng khối lượng (thanh chạy vô hạn).
  final double? value;

  int get percent => (((value ?? 0) * 100).round()).clamp(0, 100);
}
