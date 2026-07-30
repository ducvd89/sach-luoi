/// Cài đặt của người dùng, lưu thành một file JSON duy nhất.
library;

/// Cách chia file khi xuất.
enum SplitMode {
  duration('duration', 'Theo độ dài'),
  chapter('chapter', 'Mỗi chương một file'),
  single('single', 'Tất cả trong một file');

  const SplitMode(this.id, this.label);
  final String id;
  final String label;

  static SplitMode fromId(String? id) =>
      SplitMode.values.firstWhere((m) => m.id == id, orElse: () => SplitMode.duration);
}

/// Địa chỉ máy chạy các dịch vụ giọng nói. Cổng do từng engine tự biết.
const defaultServiceHost = 'http://127.0.0.1';

/// Engine cũ đã gỡ -> engine thay thế, để cài đặt và các lần xuất file cũ của
/// người dùng không bị hỏng sau khi cập nhật.
const _renamedEngines = {'kani': 'vieneu'};

String migrateEngineId(String id) => _renamedEngines[id] ?? id;

/// Khoảng nghỉ mặc định giữa hai đoạn (mili giây).
///
/// Mô hình đã ngắt sẵn ở dấu chấm, nhưng ranh giới đoạn thì cần dài hơn thế một
/// chút thì nghe mới xuôi tai — đọc liền một mạch gây cảm giác hụt hơi.
const int defaultChunkPauseMs = 550;

/// Các mức bộ nhớ đệm cho người dùng chọn, tính bằng MB. 0 nghĩa là không hạn.
const cacheLimitChoices = <int>[100, 200, 500, 1024, 0];

/// Mặc định 500 MB — đủ cho vài chục giờ sách nói, mà không âm thầm ngốn hết đĩa.
const int defaultCacheLimitMb = 500;

/// Hết một tiêu đề thì nghỉ lâu hơn, cho người nghe kịp định vị chương mới.
const double headingPauseFactor = 1.8;

/// Khoảng nghỉ nên chèn sau một đoạn.
///
/// Dùng chung cho lúc phát và lúc xuất file: nghe thử trong ứng dụng ra sao thì
/// file MP3 mở bằng máy khác phải đúng như vậy.
Duration pauseAfterChunk({required bool heading, required int pauseMs}) {
  if (pauseMs <= 0) return Duration.zero;
  return Duration(milliseconds: (pauseMs * (heading ? headingPauseFactor : 1.0)).round());
}

class AppSettings {
  AppSettings({
    this.engineId = 'vieneu',
    this.voiceId = '',
    this.speed = 1.0,
    this.chunkPauseMs = defaultChunkPauseMs,
    this.cacheLimitMb = defaultCacheLimitMb,
    this.expandNumbers = true,
    this.removeBoilerplate = true,
    this.splitMode = SplitMode.duration,
    this.partMinutes = 30,
    this.alignChapter = true,
    this.serviceUrl = defaultServiceHost,
    this.autoStartService = true,
    this.darkMode,
  });

  /// 'vieneu', 'piper' (mô hình trên máy) hoặc 'edge' (giọng qua mạng).
  String engineId;

  /// Rỗng nghĩa là chưa chọn — ứng dụng lấy giọng đầu tiên của engine.
  String voiceId;

  /// Hệ số tốc độ đọc, 1.0 là chuẩn.
  double speed;

  /// Khoảng nghỉ chèn thêm giữa hai đoạn, tính bằng mili giây.
  ///
  /// Không nằm trong âm thanh đã tổng hợp mà được chèn lúc phát và lúc ghép file,
  /// nên đổi là nghe thấy ngay và không phải đọc lại cả cuốn sách.
  int chunkPauseMs;

  /// Trần dung lượng bộ nhớ đệm âm thanh, tính bằng MB. 0 nghĩa là không hạn.
  int cacheLimitMb;

  /// Trần tính theo byte, 0 nghĩa là không hạn.
  int get cacheLimitBytes => cacheLimitMb <= 0 ? 0 : cacheLimitMb * 1024 * 1024;

  bool expandNumbers;

  /// Bỏ tên trang web, dòng ghi công người dịch, mục lục và lời quảng cáo mà
  /// sách tải trên mạng hay kèm theo.
  bool removeBoilerplate;

  SplitMode splitMode;
  int partMinutes;
  bool alignChapter;

  /// Địa chỉ dịch vụ giọng nói. Trên điện thoại có thể trỏ sang máy ở nhà.
  String serviceUrl;

  bool autoStartService;

  /// null = theo hệ thống.
  bool? darkMode;

  Map<String, dynamic> toJson() => {
        'engineId': engineId,
        'voiceId': voiceId,
        'speed': speed,
        'chunkPauseMs': chunkPauseMs,
        'cacheLimitMb': cacheLimitMb,
        'expandNumbers': expandNumbers,
        'removeBoilerplate': removeBoilerplate,
        'splitMode': splitMode.id,
        'partMinutes': partMinutes,
        'alignChapter': alignChapter,
        'serviceUrl': serviceUrl,
        'autoStartService': autoStartService,
        'darkMode': darkMode,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final savedEngine = json['engineId'] as String? ?? 'vieneu';
    final engineId = migrateEngineId(savedEngine);
    return AppSettings(
        engineId: engineId,
        // Giọng của engine cũ không còn tồn tại; để trống cho ứng dụng tự chọn.
        voiceId: engineId == savedEngine ? (json['voiceId'] as String? ?? '') : '',
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        chunkPauseMs: ((json['chunkPauseMs'] as num?)?.toInt() ?? defaultChunkPauseMs).clamp(0, 3000),
        cacheLimitMb: (json['cacheLimitMb'] as num?)?.toInt() ?? defaultCacheLimitMb,
        expandNumbers: json['expandNumbers'] as bool? ?? true,
        removeBoilerplate: json['removeBoilerplate'] as bool? ?? true,
        splitMode: SplitMode.fromId(json['splitMode'] as String?),
        partMinutes: (json['partMinutes'] as num?)?.toInt() ?? 30,
        alignChapter: json['alignChapter'] as bool? ?? true,
        serviceUrl: json['serviceUrl'] as String? ?? defaultServiceHost,
        autoStartService: json['autoStartService'] as bool? ?? true,
        darkMode: json['darkMode'] as bool?,
    );
  }

  AppSettings copy() => AppSettings.fromJson(toJson());
}
