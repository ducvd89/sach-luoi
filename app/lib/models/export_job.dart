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
  });

  final int index;
  final String fileName;
  final String title;
  final double seconds;
  final int bytes;
  final int chunkFrom;
  final int chunkTo;

  Map<String, dynamic> toJson() => {
        'index': index,
        'fileName': fileName,
        'title': title,
        'seconds': seconds,
        'bytes': bytes,
        'chunkFrom': chunkFrom,
        'chunkTo': chunkTo,
      };

  factory ExportPart.fromJson(Map<String, dynamic> json) => ExportPart(
        index: json['index'] as int,
        fileName: json['fileName'] as String,
        title: json['title'] as String? ?? '',
        seconds: (json['seconds'] as num).toDouble(),
        bytes: json['bytes'] as int,
        chunkFrom: json['chunkFrom'] as int,
        chunkTo: json['chunkTo'] as int,
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
    required this.splitMode,
    required this.partMinutes,
    required this.alignChapter,
    required this.fromChunk,
    required this.toChunk,
    required this.outputDir,
    this.status = JobStatus.queued,
    int? cursor,
    this.doneChunks = 0,
    this.secondsDone = 0,
    List<ExportPart>? parts,
    this.current,
    this.error,
  })  : cursor = cursor ?? fromChunk,
        parts = parts ?? [];

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
  final SplitMode splitMode;
  final int partMinutes;
  final bool alignChapter;
  final int fromChunk;
  final int toChunk;

  /// Thư mục người dùng chọn để lưu file MP3.
  final String outputDir;

  JobStatus status;

  /// Đoạn tiếp theo cần xử lý.
  int cursor;
  int doneChunks;
  double secondsDone;
  List<ExportPart> parts;
  PartInProgress? current;
  String? error;

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
        'splitMode': splitMode.id,
        'partMinutes': partMinutes,
        'alignChapter': alignChapter,
        'fromChunk': fromChunk,
        'toChunk': toChunk,
        'outputDir': outputDir,
        'status': status.id,
        'cursor': cursor,
        'doneChunks': doneChunks,
        'secondsDone': secondsDone,
        'parts': parts.map((p) => p.toJson()).toList(),
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
        splitMode: SplitMode.fromId(json['splitMode'] as String?),
        partMinutes: (json['partMinutes'] as num?)?.toInt() ?? 30,
        alignChapter: json['alignChapter'] as bool? ?? true,
        fromChunk: json['fromChunk'] as int,
        toChunk: json['toChunk'] as int,
        outputDir: json['outputDir'] as String? ?? '',
        status: JobStatus.fromId(json['status'] as String?),
        cursor: json['cursor'] as int?,
        doneChunks: json['doneChunks'] as int? ?? 0,
        secondsDone: (json['secondsDone'] as num?)?.toDouble() ?? 0,
        parts: (json['parts'] as List<dynamic>? ?? [])
            .map((p) => ExportPart.fromJson(p as Map<String, dynamic>))
            .toList(),
        current: json['current'] == null ? null : PartInProgress.fromJson(json['current'] as Map<String, dynamic>),
        error: json['error'] as String?,
      );
}
