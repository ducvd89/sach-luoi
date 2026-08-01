/// Giao diện chung cho các bộ tổng hợp giọng nói.
///
/// Ứng dụng không quan tâm giọng đến từ đâu — mô hình chạy trên máy hay dịch
/// vụ trên mạng — miễn là trả về MP3. Nhờ vậy đổi engine chỉ là đổi một dòng
/// trong Cài đặt, và sau này thêm engine mới không phải sửa phần còn lại.
library;

import 'dart:typed_data';

/// Một giọng đọc có thể chọn.
class TtsVoice {
  const TtsVoice({
    required this.id,
    required this.name,
    required this.gender,
    this.description = '',
    this.builtIn = true,
  });

  final String id;
  final String name;
  final String gender;
  final String description;

  /// False với giọng do người dùng tự thêm bằng mẫu ghi âm.
  final bool builtIn;

  factory TtsVoice.fromJson(Map<String, dynamic> json) => TtsVoice(
        id: json['id'] as String,
        name: json['name'] as String,
        gender: json['gender'] as String? ?? '',
        description: json['description'] as String? ?? '',
        builtIn: json['builtIn'] as bool? ?? true,
      );
}

/// Kết quả tổng hợp một đoạn.
class TtsResult {
  const TtsResult(this.audio, this.seconds, {this.duoi = const []});
  final Uint8List audio;
  final double seconds;

  /// Mã đuôi của đoạn vừa đọc, để truyền làm ngữ cảnh cho đoạn kế.
  ///
  /// Rỗng với engine không hỗ trợ nối ngữ cảnh — chỉ VieNeu có.
  final List<int> duoi;
}

class TtsException implements Exception {
  TtsException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Trạng thái sẵn sàng của một engine.
class EngineStatus {
  const EngineStatus({
    required this.ready,
    required this.message,
    this.device = '',
    this.loading = false,
  });

  final bool ready;
  final String message;

  /// "cuda:0 (RTX 5080)" hoặc "cpu" — chỉ engine cục bộ mới có.
  final String device;

  /// True khi đang nạp mô hình.
  final bool loading;
}

abstract class TtsEngine {
  /// Mã định danh dùng trong cài đặt và trong khoá cache.
  String get id;

  /// Tên hiển thị cho người dùng.
  String get displayName;

  /// True nếu engine chạy hoàn toàn trên máy (không cần mạng khi đọc).
  bool get isLocal;

  /// Một dòng mô tả điểm mạnh/điểm yếu, hiện dưới tên trong phần Cài đặt.
  String get description;

  /// Định dạng âm thanh engine trả về: 'mp3' hoặc 'wav'.
  ///
  /// Engine chạy trong ứng dụng sinh ra mẫu âm thô, nhúng bộ mã hoá MP3 vào
  /// Flutter thì nặng hơn cả mô hình giọng nói nên nó dùng WAV. Bộ nhớ đệm và
  /// phần xuất file nhìn vào đây để biết cách ghép các đoạn lại.
  String get audioFormat => 'mp3';

  /// Kiểm tra engine đã sẵn sàng chưa.
  Future<EngineStatus> status();

  /// Danh sách giọng đọc.
  Future<List<TtsVoice>> voices();

  /// Tổng hợp một đoạn văn bản thành MP3.
  ///
  /// [speed] là hệ số tốc độ (1.0 là chuẩn).
  /// [nguCanh] là mã đuôi của đoạn đọc ngay trước. Có nó thì giọng không nhảy ở
  /// chỗ chuyển đoạn; engine nào không hỗ trợ thì bỏ qua.
  Future<TtsResult> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
    List<int>? nguCanh,
  });

  /// Báo cho engine biết sắp có nhiều đoạn cần tổng hợp liên tiếp (xuất file).
  ///
  /// Engine nào tận dụng được thì mở thêm luồng chạy song song; engine không
  /// quan tâm thì bỏ qua. Nghe trực tiếp không bật cờ này: một luồng đã nhanh
  /// hơn tốc độ nghe, mở thêm chỉ tốn RAM và làm máy nóng vô ích.
  Future<void> setBulkMode(bool on) async {}
}
