/// Giao diện chung cho các bộ tổng hợp giọng nói.
///
/// Ứng dụng không quan tâm giọng đến từ đâu — mô hình đóng gói trong ứng dụng
/// hay giọng có sẵn của hệ điều hành — miễn là trả về WAV kèm thời lượng. Nhờ
/// vậy đổi engine chỉ là đổi một dòng trong Cài đặt, và sau này thêm engine mới
/// không phải sửa phần còn lại.
///
/// Vì sao chốt WAV chứ không để engine tự chọn định dạng: mọi engine đều sinh
/// ra mẫu âm thô rồi ứng dụng đóng gói WAV, và không engine nào có đường trả về
/// dữ liệu đã nén. VieNeu trả `*mut c_float` từ thư viện Rust; còn trên Android
/// thì không có lấy một bộ mã hoá MP3 nào (MediaCodec thiếu nó, libmp3lame bị
/// chặn khỏi bản Android trong `native/vieneu/Cargo.toml`). Việc nén sang
/// Opus/AAC/MP3 nằm ở bước xuất file, sau khi WAV đã hoàn chỉnh — xem
/// `services/audio_encoder.dart`.
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
    this.loading = false,
  });

  final bool ready;
  final String message;

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

  /// Kiểm tra engine đã sẵn sàng chưa.
  Future<EngineStatus> status();

  /// Danh sách giọng đọc.
  Future<List<TtsVoice>> voices();

  /// Đọc lại cùng một đoạn có ra âm thanh khác không.
  ///
  /// Mô hình sinh có lấy mẫu ngẫu nhiên thì đổi hạt giống là ra bản đọc khác —
  /// nhờ vậy lúc xuất file, đoạn đọc hỏng còn có cửa đọc lại (xem
  /// `export_service.dart`). Engine đọc theo luật (Piper, TTS hệ thống) thì lần
  /// nào cũng y hệt, đọc lại chỉ tốn thời gian vô ích.
  bool get docLaiRaKhac => false;

  /// Tổng hợp một đoạn văn bản thành WAV.
  ///
  /// [speed] là hệ số tốc độ (1.0 là chuẩn).
  /// [nguCanh] là mã đuôi của đoạn đọc ngay trước. Có nó thì giọng không nhảy ở
  /// chỗ chuyển đoạn; engine nào không hỗ trợ thì bỏ qua.
  /// [lanThu] là lần đọc thứ mấy của cùng đoạn ấy — 0 là lần đầu. Engine có
  /// [docLaiRaKhac] dùng nó để đổi hạt giống; engine khác bỏ qua.
  Future<TtsResult> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
    List<int>? nguCanh,
    int lanThu = 0,
  });

  /// Báo cho engine biết sắp có nhiều đoạn cần tổng hợp liên tiếp (xuất file).
  ///
  /// Engine nào tận dụng được thì mở thêm luồng chạy song song; engine không
  /// quan tâm thì bỏ qua. Nghe trực tiếp không bật cờ này: một luồng đã nhanh
  /// hơn tốc độ nghe, mở thêm chỉ tốn RAM và làm máy nóng vô ích.
  Future<void> setBulkMode(bool on) async {}
}
