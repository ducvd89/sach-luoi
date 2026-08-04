/// Công việc xuất sách nói ra file MP3.
///
/// Toàn bộ trạng thái nằm trong job.json để có thể dừng giữa chừng, tắt ứng
/// dụng rồi mở lại chạy tiếp mà không mất công đã làm.
library;

import 'settings.dart';

enum JobStatus {
  queued('queued', 'Đang chờ'),
  running('running', 'Đang xuất'),
  paused('paused', 'Tạm dừng'),
  done('done', 'Hoàn tất'),
  error('error', 'Lỗi'),
  canceled('canceled', 'Đã huỷ');

  const JobStatus(this.id, this.label);
  final String id;
  final String label;

  static JobStatus fromId(String? id) =>
      JobStatus.values.firstWhere((s) => s.id == id, orElse: () => JobStatus.queued);
}

/// Một file MP3 đã xuất xong.
class ExportPart {
  const ExportPart({
    required this.index,
    required this.fileName,
    required this.title,
    required this.seconds,
    required this.bytes,
    required this.chunkFrom,
    required this.chunkTo,
    this.localPlayPath,
  });

  final int index;
  final String fileName;
  final String title;
  final double seconds;
  final int bytes;
  final int chunkFrom;
  final int chunkTo;

  /// Đường dẫn bản riêng của ứng dụng để phát lại phần này ngay trong ứng
  /// dụng — null trên máy tính (không cần, file thật đã nằm sẵn trong
  /// outputDir) hoặc trên Android nếu chép hụt. Xem [ExportService.playablePath].
  final String? localPlayPath;

  Map<String, dynamic> toJson() => {
        'index': index,
        'fileName': fileName,
        'title': title,
        'seconds': seconds,
        'bytes': bytes,
        'chunkFrom': chunkFrom,
        'chunkTo': chunkTo,
        if (localPlayPath != null) 'localPlayPath': localPlayPath,
      };

  factory ExportPart.fromJson(Map<String, dynamic> json) => ExportPart(
        index: json['index'] as int,
        fileName: json['fileName'] as String,
        title: json['title'] as String? ?? '',
        seconds: (json['seconds'] as num).toDouble(),
        bytes: json['bytes'] as int,
        chunkFrom: json['chunkFrom'] as int,
        chunkTo: json['chunkTo'] as int,
        localPlayPath: json['localPlayPath'] as String?,
      );
}

/// Phần đang ghi dở — cần để chạy tiếp đúng chỗ sau khi tạm dừng hoặc mất điện.
class PartInProgress {
  PartInProgress({
    required this.index,
    required this.chunkFrom,
    required this.seconds,
    required this.bytes,
    required this.chapterTitle,
  });

  int index;
  int chunkFrom;
  double seconds;

  /// Số byte đã ghi nhận. Khi chạy lại, file .part được cắt về đúng mốc này để
  /// không lặp âm thanh nếu lần trước bị tắt đột ngột.
  int bytes;
  String chapterTitle;

  Map<String, dynamic> toJson() => {
        'index': index,
        'chunkFrom': chunkFrom,
        'seconds': seconds,
        'bytes': bytes,
        'chapterTitle': chapterTitle,
      };

  factory PartInProgress.fromJson(Map<String, dynamic> json) => PartInProgress(
        index: json['index'] as int,
        chunkFrom: json['chunkFrom'] as int,
        seconds: (json['seconds'] as num).toDouble(),
        bytes: json['bytes'] as int,
        chapterTitle: json['chapterTitle'] as String? ?? '',
      );
}

/// Một dòng nhật ký soi âm: đoạn nào đọc ra không khớp văn bản, đã đọc lại mấy
/// lần và kết cục thế nào.
///
/// Chỉ những đoạn có vấn đề mới được ghi — đoạn đọc trúng ngay lần đầu (gần như
/// tất cả) mà cũng ghi thì nhật ký thành một bức tường vô nghĩa.
class MucNhatKy {
  MucNhatKy({
    required this.doan,
    required this.soTu,
    required this.soAm,
    this.soLan = 1,
    this.xong = false,
    this.dat = false,
  });

  /// Chỉ số đoạn trong sách, đếm từ 0.
  final int doan;

  /// Số từ trong văn bản của đoạn.
  final int soTu;

  /// Số âm nghe được ở bản đọc đang xét — bản cuối lúc còn đang đọc lại, bản
  /// được chọn khi đã [xong].
  int soAm;

  /// Đã đọc cả thảy mấy lượt.
  int soLan;

  /// Đã chốt xong đoạn này chưa. False nghĩa là đang đọc lại.
  bool xong;

  /// Chốt ở bản đạt, hay đành lấy bản gần đúng nhất.
  bool dat;

  double get tiLe => soTu == 0 ? 1 : soAm / soTu;

  Map<String, dynamic> toJson() => {
        'doan': doan,
        'soTu': soTu,
        'soAm': soAm,
        'soLan': soLan,
        'xong': xong,
        'dat': dat,
      };

  factory MucNhatKy.fromJson(Map<String, dynamic> json) => MucNhatKy(
        doan: json['doan'] as int? ?? 0,
        soTu: json['soTu'] as int? ?? 0,
        soAm: json['soAm'] as int? ?? 0,
        soLan: json['soLan'] as int? ?? 1,
        // Ghi lại từ đĩa thì chắc chắn không còn lượt đọc nào đang chạy dở.
        xong: json['xong'] as bool? ?? true,
        dat: json['dat'] as bool? ?? false,
      );
}

/// Giữ bao nhiêu dòng nhật ký gần nhất.
///
/// Sách dày mà mô hình đang có ngày xấu thì hàng trăm đoạn phải đọc lại; giữ
/// hết thì job.json phình ra vì một thứ chỉ để liếc qua. Vài chục dòng gần nhất
/// là đủ để biết máy đang vật lộn ở chỗ nào.
const int _toiDaNhatKy = 50;

class ExportJob {
  ExportJob({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    required this.author,
    required this.createdAt,
    required this.engineId,
    required this.voiceId,
    required this.voiceName,
    required this.speed,
    required this.pauseMs,
    this.formatId = 'wav',
    required this.splitMode,
    required this.partMinutes,
    required this.alignChapter,
    required this.fromChunk,
    required this.toChunk,
    required this.outputDir,
    this.treeUri = '',
    this.nguCanh = NguCanh.loLon,
    this.status = JobStatus.queued,
    int? cursor,
    this.doneChunks = 0,
    this.doanDocLai = 0,
    this.doanChuaDat = 0,
    this.secondsDone = 0,
    List<ExportPart>? parts,
    List<MucNhatKy>? nhatKy,
    this.current,
    this.error,
  })  : cursor = cursor ?? fromChunk,
        parts = parts ?? [],
        nhatKy = nhatKy ?? [];

  final String id;
  final String bookId;
  final String bookTitle;
  final String author;
  final DateTime createdAt;

  final String engineId;
  final String voiceId;
  final String voiceName;
  final double speed;

  /// Khoảng nghỉ chèn giữa các đoạn, ghi lại theo job để chạy tiếp giữ đúng nhịp
  /// dù người dùng đã đổi cài đặt.
  final int pauseMs;

  /// Định dạng chốt lúc tạo job — đổi cài đặt giữa lúc đang xuất thì job đang
  /// chạy vẫn ra đúng loại file mà nó đã bắt đầu.
  final String formatId;
  final SplitMode splitMode;
  final int partMinutes;
  final bool alignChapter;
  final int fromChunk;
  final int toChunk;

  /// Thư mục người dùng chọn để lưu file MP3.
  final String outputDir;

  /// Android: thư mục người dùng chọn, dạng tree URI. Chép lại vào job lúc tạo
  /// chứ không đọc từ cài đặt lúc ghi — đổi cài đặt giữa chừng thì job đang chạy
  /// vẫn cất file đúng chỗ nó đã hứa.
  final String treeUri;

  /// Cách nối ngữ cảnh giữa các đoạn.
  ///
  /// Không đổi được khi job đang chạy — giao diện khoá lựa chọn lại. Muốn đổi
  /// thì tạm dừng, đổi, rồi chạy tiếp: lúc ấy job lấy theo mức mới. Phần đã xuất
  /// giữ nguyên, chỉ phần còn lại đọc theo cách mới.
  NguCanh nguCanh;

  JobStatus status;

  /// Đoạn tiếp theo cần xử lý.
  int cursor;
  int doneChunks;

  /// Số đoạn phải đọc lại vì số âm không khớp số từ — xem `kiem_am.dart`.
  int doanDocLai;

  /// Trong số ấy, số đoạn đọc lại hết lượt mà vẫn lệch; những đoạn này lấy bản
  /// gần đúng nhất, có thể nghe ra thừa hoặc thiếu chữ.
  int doanChuaDat;

  double secondsDone;
  List<ExportPart> parts;

  /// Nhật ký soi âm, cũ ở đầu và mới ở cuối.
  List<MucNhatKy> nhatKy;

  PartInProgress? current;
  String? error;

  /// Ghi thêm một dòng nhật ký, bỏ dòng cũ nhất khi đã quá dài.
  void ghiNhatKy(MucNhatKy muc) {
    nhatKy.add(muc);
    if (nhatKy.length > _toiDaNhatKy) nhatKy.removeRange(0, nhatKy.length - _toiDaNhatKy);
  }

  /// Đang nén phần vừa tổng hợp xong sang Opus/MP3 — chỉ có ý nghĩa lúc job
  /// thật sự đang chạy trong bộ nhớ, KHÔNG ghi xuống job.json: đọc lại job từ
  /// đĩa (mở app lại, hay job đang tạm dừng) thì lúc đó chắc chắn không có
  /// việc nén nào đang chạy cả.
  bool dangNen = false;

  /// Phần đã nén xong (0..1) trong lúc [dangNen], null nếu chưa có số.
  ///
  /// Chỉ Android báo được — MediaCodec chạy trên luồng nền của Kotlin, đẩy %
  /// qua EventChannel (xem audio_encoder.dart). Máy tính nén xong trong vài
  /// giây bằng thư viện Rust, gọi đồng bộ nên không có gì để báo giữa chừng;
  /// giao diện dùng thanh chạy vô định cho trường hợp null.
  double? nenPhan;

  int get totalChunks => toChunk - fromChunk + 1;
  double get progress => totalChunks == 0 ? 0 : (doneChunks / totalChunks).clamp(0.0, 1.0);
  bool get isActive => status == JobStatus.running || status == JobStatus.queued;
  bool get canResume =>
      status == JobStatus.paused || status == JobStatus.error || status == JobStatus.canceled;

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'bookTitle': bookTitle,
        'author': author,
        'createdAt': createdAt.toIso8601String(),
        'engineId': engineId,
        'voiceId': voiceId,
        'voiceName': voiceName,
        'speed': speed,
        'pauseMs': pauseMs,
        'formatId': formatId,
        'splitMode': splitMode.id,
        'partMinutes': partMinutes,
        'alignChapter': alignChapter,
        'fromChunk': fromChunk,
        'toChunk': toChunk,
        'outputDir': outputDir,
        'treeUri': treeUri,
        'nguCanh': nguCanh.id,
        'status': status.id,
        'cursor': cursor,
        'doneChunks': doneChunks,
        'doanDocLai': doanDocLai,
        'doanChuaDat': doanChuaDat,
        'secondsDone': secondsDone,
        'parts': parts.map((p) => p.toJson()).toList(),
        'nhatKy': nhatKy.map((m) => m.toJson()).toList(),
        'current': current?.toJson(),
        'error': error,
      };

  factory ExportJob.fromJson(Map<String, dynamic> json) => ExportJob(
        id: json['id'] as String,
        bookId: json['bookId'] as String,
        bookTitle: json['bookTitle'] as String,
        author: json['author'] as String? ?? '',
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
        engineId: migrateEngineId(json['engineId'] as String? ?? 'vieneu'),
        voiceId: json['voiceId'] as String,
        voiceName: json['voiceName'] as String? ?? '',
        speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
        // Job tạo trước khi có khoảng nghỉ thì giữ nguyên cách ghép cũ, nếu
        // không phần chạy tiếp sẽ lệch nhịp so với phần đã xuất.
        pauseMs: (json['pauseMs'] as num?)?.toInt() ?? 0,
        formatId: json['formatId'] as String? ?? 'wav',
        splitMode: SplitMode.fromId(json['splitMode'] as String?),
        partMinutes: (json['partMinutes'] as num?)?.toInt() ?? 30,
        alignChapter: json['alignChapter'] as bool? ?? true,
        fromChunk: json['fromChunk'] as int,
        toChunk: json['toChunk'] as int,
        outputDir: json['outputDir'] as String? ?? '',
        treeUri: json['treeUri'] as String? ?? '',
        nguCanh: NguCanh.fromId(json['nguCanh'] as String?),
        status: JobStatus.fromId(json['status'] as String?),
        cursor: json['cursor'] as int?,
        doneChunks: json['doneChunks'] as int? ?? 0,
        doanDocLai: json['doanDocLai'] as int? ?? 0,
        doanChuaDat: json['doanChuaDat'] as int? ?? 0,
        secondsDone: (json['secondsDone'] as num?)?.toDouble() ?? 0,
        parts: (json['parts'] as List<dynamic>? ?? [])
            .map((p) => ExportPart.fromJson(p as Map<String, dynamic>))
            .toList(),
        nhatKy: (json['nhatKy'] as List<dynamic>? ?? [])
            .map((m) => MucNhatKy.fromJson(m as Map<String, dynamic>))
            .toList(),
        current: json['current'] == null ? null : PartInProgress.fromJson(json['current'] as Map<String, dynamic>),
        error: json['error'] as String?,
      );
}
