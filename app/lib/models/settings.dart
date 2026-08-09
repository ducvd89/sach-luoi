/// Cài đặt của người dùng, lưu thành một file JSON duy nhất.
library;

import 'dart:io';

/// Engine mặc định cho bản cài mới. Android/iOS có sẵn giọng tiếng Việt hệ
/// thống nên chọn TTS hệ thống cho nhẹ máy ngay từ đầu; nền tảng khác (trước
/// hết là Windows, chưa có giọng Việt hệ thống) vẫn mặc định VieNeu.
String get defaultEngineId => (Platform.isAndroid || Platform.isIOS) ? 'system' : 'vieneu';

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

/// Engine cũ đã gỡ -> engine thay thế, để cài đặt và các lần xuất file cũ của
/// người dùng không bị hỏng sau khi cập nhật.
const _renamedEngines = {'kani': 'vieneu'};

String migrateEngineId(String id) => _renamedEngines[id] ?? id;

/// Khoảng nghỉ mặc định giữa hai đoạn (mili giây).
///
/// Đo trên một file xuất ra thật (930 câu): nhịp nghỉ mà mô hình tự sinh ra
/// giữa hai câu có trung vị 0,23 s, phân vị 90 là 0,45 s và **dài nhất 0,50 s**.
///
/// Bản đầu đặt 550 ms — chỉ hơn cái nghỉ dài nhất giữa hai câu đúng 0,05 s, nên
/// tai không phân biệt được hết câu với hết đoạn và nghe như bị dính vào nhau.
/// Muốn ranh giới đoạn nghe ra là ranh giới đoạn thì nó phải vượt hẳn khỏi dải
/// nghỉ tự nhiên, chứ không phải nhích hơn một chút.
const int defaultChunkPauseMs = 900;

/// Giá trị mặc định của bản trước. Ai chưa từng kéo thanh trượt thì được nâng
/// lên mức mới; ai đã tự chọn 550 thì giữ nguyên ý họ.
const int _chunkPauseMsCu = 550;

/// Các mức tốc độ đọc cho người dùng chọn. Dùng chung cho cả trang Nghe lẫn
/// trang Xuất file, để hai nơi không lệch danh sách nhau.
const tocDoChon = <double>[0.4, 0.5, 0.6, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0];

/// "1.0×", "1.25×" — bỏ số lẻ thừa cho các mức tròn.
String nhanTocDo(double toc) =>
    '${toc.toStringAsFixed(toc == toc.roundToDouble() ? 1 : 2)}×';

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

/// Định dạng file xuất ra.
///
/// WAV không nén nên nặng gấp khoảng 30 lần Opus ở cùng thời lượng. Đo trên một
/// file thật 29,9 phút: WAV 164 MB, Opus 32k 6,8 MB, Opus 64k 14 MB, MP3 128k
/// 27 MB. Opus nhỏ hơn hẳn ở cùng chất lượng vì nó được thiết kế cho dải bitrate
/// thấp, còn MP3 giữ lại vì đầu đĩa và dàn xe hơi cũ chỉ đọc được nó.
///
/// AAC thêm sau: bộ mã hoá thuần Rust trên máy tính (không cần thư viện C nào),
/// và trên Android là chính bộ mã hoá hệ điều hành dùng sẵn — máy nào cũng phát
/// được như MP3, nhưng nhẹ hơn nhiều ở cùng chất lượng, gần với Opus.
enum ExportFormat {
  opus32('opus32', 'Opus 32 kbps — nhỏ nhất', 'opus', 32000),
  opus64('opus64', 'Opus 64 kbps — chất lượng cao hơn', 'opus', 64000),
  aac64('aac_64', 'AAC 64 kbps — nhẹ mà máy nào cũng phát được', 'aac', 64000),
  mp3_128('mp3_128', 'MP3 128 kbps — máy nào cũng đọc được', 'mp3', 128),
  wav('wav', 'WAV — không nén, nặng nhất', 'wav', 0);

  const ExportFormat(this.id, this.label, this.extension, this.bitrate);
  final String id;
  final String label;
  final String extension;

  /// Opus và AAC tính theo bit/s, MP3 theo kbps — đúng như thư viện native nhận.
  final int bitrate;

  bool get isWav => this == ExportFormat.wav;

  static ExportFormat fromId(String? id) =>
      ExportFormat.values.firstWhere((f) => f.id == id, orElse: () => ExportFormat.opus32);
}

/// Dùng phần đuôi đoạn trước làm ngữ cảnh cho đoạn sau hay không.
///
/// Mô hình đọc từng đoạn rời nhau, mỗi đoạn tự đoán lại ngữ điệu từ mẫu giọng —
/// nên độ cao giọng nhảy ở chỗ chuyển đoạn. Đưa 8 giây cuối của đoạn trước vào
/// thay cho mã tham chiếu của mẫu thì hết nhảy. Đo trên 12 đoạn liên tiếp:
/// lệch chuẩn cao độ 9,2 Hz xuống 4,8 Hz, độ giống đoạn liền trước 0,794 lên
/// 0,828, mà giọng không trôi khỏi mẫu gốc.
///
/// Cái giá: đoạn sau phải chờ đoạn trước xong nên không chạy song song được
/// nữa. Vì thế mới có ba mức, và nghe với xuất file đặt riêng — lúc nghe thì
/// vốn đã tuần tự sẵn, còn lúc xuất thì chạy song song đang cho 8,94× thời gian
/// thực.
enum NguCanh {
  khong('khong', 'Không dùng', 'Nhanh nhất. Giọng có thể hơi khác nhau giữa các đoạn.'),
  loLon('lo', 'Theo đoạn', 'Nối trong từng lô đoạn liền nhau. Gần như giữ nguyên tốc độ, chỉ còn ít chỗ chuyển giọng.'),
  tuanTu('tuan-tu', 'Tuần hoàn', 'Mượt nhất. Xuất file chậm hơn khoảng ba lần vì không chạy song song được.');

  const NguCanh(this.id, this.label, this.description);
  final String id;
  final String label;
  final String description;

  static NguCanh fromId(String? id) =>
      NguCanh.values.firstWhere((v) => v.id == id, orElse: () => NguCanh.loLon);
}

class AppSettings {
  AppSettings({
    this.engineId = 'vieneu',
    this.voiceNghe = '',
    this.voiceXuat = '',
    this.speed = 1.0,
    this.speedXuat = 1.0,
    this.chunkPauseMs = defaultChunkPauseMs,
    this.cacheLimitMb = defaultCacheLimitMb,
    this.exportFormat = ExportFormat.opus32,
    this.expandNumbers = true,
    this.removeBoilerplate = true,
    this.splitMode = SplitMode.duration,
    this.partMinutes = 30,
    this.alignChapter = true,
    this.exportTreeUri = '',
    this.nguCanhNghe = NguCanh.tuanTu,
    this.nguCanhXuat = NguCanh.loLon,
    this.darkMode,
  });

  /// 'vieneu', 'piper' (hai mô hình chạy trong ứng dụng) hoặc 'system'
  /// (giọng có sẵn của hệ điều hành).
  String engineId;

  /// Giọng dùng khi nghe. Rỗng nghĩa là chưa chọn — ứng dụng lấy giọng đầu tiên.
  ///
  /// Tách khỏi giọng xuất file: nghe thử bằng giọng này rồi xuất bằng giọng khác
  /// là chuyện thường, mà mỗi trang cũng khoá riêng khi đang chạy.
  String voiceNghe;

  /// Giọng dùng khi xuất file, độc lập với [voiceNghe].
  String voiceXuat;

  /// Hệ số tốc độ khi NGHE, 1.0 là chuẩn.
  ///
  /// Chỉ áp vào lúc phát chứ không tổng hợp lại, nên kéo là nghe khác ngay và
  /// bộ nhớ đệm vẫn dùng được.
  double speed;

  /// Hệ số tốc độ khi XUẤT FILE, độc lập với [speed].
  ///
  /// Phải tách ra vì hai con số này khác hẳn nhau về bản chất: tốc độ nghe chỉ
  /// là nhịp phát lại, còn tốc độ xuất được NƯỚNG THẲNG vào file bằng phép lấy
  /// mẫu lại (xem `vieneu_engine.dart`) — đổi nó là phải tổng hợp lại từ đầu,
  /// và cao độ giọng cũng đổi theo.
  ///
  /// Dùng chung một biến thì kéo thanh tốc độ lúc đang nghe sẽ âm thầm đổi luôn
  /// tốc độ của mọi file xuất về sau, mà không có gì trên màn hình báo cả.
  double speedXuat;

  /// Khoảng nghỉ chèn thêm giữa hai đoạn, tính bằng mili giây.
  ///
  /// Không nằm trong âm thanh đã tổng hợp mà được chèn lúc phát và lúc ghép file,
  /// nên đổi là nghe thấy ngay và không phải đọc lại cả cuốn sách.
  int chunkPauseMs;

  /// Trần dung lượng bộ nhớ đệm âm thanh, tính bằng MB. 0 nghĩa là không hạn.
  int cacheLimitMb;

  /// Định dạng file xuất ra.
  ExportFormat exportFormat;

  /// Trần tính theo byte, 0 nghĩa là không hạn.
  int get cacheLimitBytes => cacheLimitMb <= 0 ? 0 : cacheLimitMb * 1024 * 1024;

  bool expandNumbers;

  /// Bỏ tên trang web, dòng ghi công người dịch, mục lục và lời quảng cáo mà
  /// sách tải trên mạng hay kèm theo.
  bool removeBoilerplate;

  SplitMode splitMode;
  int partMinutes;
  bool alignChapter;

  /// Nối ngữ cảnh khi nghe. Mặc định tuần tự: lúc nghe vốn đã đọc lần lượt nên
  /// không mất gì, mà được chỗ chuyển đoạn mượt nhất.
  NguCanh nguCanhNghe;

  /// Nối ngữ cảnh khi xuất file. Mặc định theo lô: giữ được tốc độ chạy song
  /// song mà vẫn bỏ được phần lớn chỗ chuyển giọng.
  NguCanh nguCanhXuat;

  /// Android: thư mục người dùng đã chọn để cất file xuất ra, dạng "tree URI"
  /// của Storage Access Framework. Rỗng nghĩa là dùng mặc định — MediaStore đưa
  /// file vào Music/Sách lười. Không phải đường dẫn thật, đừng ghép vào File().
  String exportTreeUri;

  /// null = theo hệ thống.
  bool? darkMode;

  Map<String, dynamic> toJson() => {
        'engineId': engineId,
        'voiceNghe': voiceNghe,
        'voiceXuat': voiceXuat,
        'speed': speed,
        'speedXuat': speedXuat,
        'chunkPauseMs': chunkPauseMs,
        'cacheLimitMb': cacheLimitMb,
        'exportFormat': exportFormat.id,
        'expandNumbers': expandNumbers,
        'removeBoilerplate': removeBoilerplate,
        'splitMode': splitMode.id,
        'partMinutes': partMinutes,
        'alignChapter': alignChapter,
        'exportTreeUri': exportTreeUri,
        'nguCanhNghe': nguCanhNghe.id,
        'nguCanhXuat': nguCanhXuat.id,
        'darkMode': darkMode,
      };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final savedEngine = json['engineId'] as String? ?? 'vieneu';
    final engineId = migrateEngineId(savedEngine);
    return AppSettings(
        engineId: engineId,
        // Giọng của engine cũ không còn tồn tại; để trống cho ứng dụng tự chọn.
        // 'voiceId' là tên cũ hồi hai trang còn dùng chung một giọng.
        voiceNghe: engineId == savedEngine
            ? (json['voiceNghe'] as String? ?? json['voiceId'] as String? ?? '')
            : '',
        voiceXuat: engineId == savedEngine
            ? (json['voiceXuat'] as String? ?? json['voiceId'] as String? ?? '')
            : '',
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        // Bản trước dùng chung một con số. Ai đã quen xuất file ở tốc độ nào
        // thì giữ đúng tốc độ ấy, đừng lặng lẽ kéo họ về 1.0.
        speedXuat: (json['speedXuat'] as num?)?.toDouble() ??
            (json['speed'] as num?)?.toDouble() ??
            1.0,
        chunkPauseMs: _napKhoangNghi(json['chunkPauseMs']),
        cacheLimitMb: (json['cacheLimitMb'] as num?)?.toInt() ?? defaultCacheLimitMb,
        exportFormat: ExportFormat.fromId(json['exportFormat'] as String?),
        expandNumbers: json['expandNumbers'] as bool? ?? true,
        removeBoilerplate: json['removeBoilerplate'] as bool? ?? true,
        splitMode: SplitMode.fromId(json['splitMode'] as String?),
        partMinutes: (json['partMinutes'] as num?)?.toInt() ?? 30,
        alignChapter: json['alignChapter'] as bool? ?? true,
        exportTreeUri: json['exportTreeUri'] as String? ?? '',
        nguCanhNghe: NguCanh.fromId(json['nguCanhNghe'] as String? ?? 'tuan-tu'),
        nguCanhXuat: NguCanh.fromId(json['nguCanhXuat'] as String?),
        darkMode: json['darkMode'] as bool?,
    );
  }
}

/// Đọc khoảng nghỉ đã lưu, nâng mức mặc định cũ lên mức mới.
int _napKhoangNghi(Object? luu) {
  final so = (luu as num?)?.toInt();
  if (so == null) return defaultChunkPauseMs;
  // Đúng bằng mặc định cũ nghĩa là người dùng chưa từng đụng vào thanh trượt —
  // họ nhận cái mặc định chứ không chọn con số đó.
  if (so == _chunkPauseMsCu) return defaultChunkPauseMs;
  return so.clamp(0, 3000);
}
