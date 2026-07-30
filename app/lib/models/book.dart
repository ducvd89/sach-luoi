/// Các kiểu dữ liệu cốt lõi của sách và tiến trình nghe.
library;

/// Một chương thô vừa trích từ file, trước khi cắt đoạn.
class RawChapter {
  const RawChapter(this.title, this.text);
  final String title;
  final String text;
}

/// Kết quả đọc một file sách.
class ParsedBook {
  const ParsedBook({
    required this.title,
    required this.author,
    required this.language,
    required this.chapters,
  });

  final String title;
  final String author;
  final String language;
  final List<RawChapter> chapters;
}

/// Một đoạn — đơn vị phát, cache, lưu tiến trình và ghép file.
class Chunk {
  const Chunk({
    required this.index,
    required this.chapter,
    required this.display,
    required this.speech,
    required this.heading,
  });

  /// Thứ tự trong toàn bộ sách.
  final int index;

  /// Chỉ số chương chứa đoạn này.
  final int chapter;

  /// Văn bản hiển thị trên màn hình đọc.
  final String display;

  /// Văn bản đã chuẩn hoá để gửi đi tổng hợp.
  final String speech;

  /// True nếu đây là tiêu đề chương.
  final bool heading;

  Map<String, dynamic> toJson() => {
        'i': index,
        'c': chapter,
        'd': display,
        's': speech,
        if (heading) 'h': 1,
      };

  factory Chunk.fromJson(Map<String, dynamic> json) => Chunk(
        index: json['i'] as int,
        chapter: json['c'] as int,
        display: json['d'] as String,
        speech: json['s'] as String,
        heading: json['h'] == 1,
      );
}

class Chapter {
  const Chapter({
    required this.index,
    required this.title,
    required this.firstChunk,
    required this.chunkCount,
    required this.charCount,
  });

  final int index;
  final String title;
  final int firstChunk;
  final int chunkCount;
  final int charCount;

  int get lastChunk => firstChunk + chunkCount - 1;

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'firstChunk': firstChunk,
        'chunkCount': chunkCount,
        'charCount': charCount,
      };

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        index: json['index'] as int,
        title: json['title'] as String,
        firstChunk: json['firstChunk'] as int,
        chunkCount: json['chunkCount'] as int,
        charCount: json['charCount'] as int,
      );
}

/// Vị trí đang nghe của một cuốn sách.
class Progress {
  Progress({
    this.chunkIndex = 0,
    this.offsetSeconds = 0,
    this.listenedChunks = 0,
    this.finished = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  int chunkIndex;
  double offsetSeconds;

  /// Đoạn xa nhất từng nghe tới — dùng vẽ thanh tiến trình, không tụt khi tua lại.
  int listenedChunks;
  bool finished;
  DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'chunkIndex': chunkIndex,
        'offsetSeconds': offsetSeconds,
        'listenedChunks': listenedChunks,
        'finished': finished,
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Progress.fromJson(Map<String, dynamic> json) => Progress(
        chunkIndex: (json['chunkIndex'] as num?)?.toInt() ?? 0,
        offsetSeconds: (json['offsetSeconds'] as num?)?.toDouble() ?? 0,
        listenedChunks: (json['listenedChunks'] as num?)?.toInt() ?? 0,
        finished: json['finished'] as bool? ?? false,
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ?? DateTime.now(),
      );
}

/// Thông tin một cuốn sách trong thư viện.
class Book {
  Book({
    required this.id,
    required this.title,
    required this.author,
    required this.language,
    required this.sourceFile,
    required this.format,
    required this.addedAt,
    required this.chapters,
    required this.chunkCount,
    required this.charCount,
    required this.expandNumbers,
    Progress? progress,
  }) : progress = progress ?? Progress();

  final String id;
  final String title;
  final String author;
  final String language;
  final String sourceFile;
  final String format;
  final DateTime addedAt;
  final List<Chapter> chapters;
  final int chunkCount;
  final int charCount;
  final bool expandNumbers;
  Progress progress;

  /// Thời lượng ước lượng của cả sách ở tốc độ chuẩn.
  Duration get estimatedDuration => Duration(seconds: (charCount / 14.5).round());

  double get percentListened => chunkCount == 0 ? 0 : (progress.listenedChunks / chunkCount).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'language': language,
        'sourceFile': sourceFile,
        'format': format,
        'addedAt': addedAt.toIso8601String(),
        'chapters': chapters.map((c) => c.toJson()).toList(),
        'chunkCount': chunkCount,
        'charCount': charCount,
        'expandNumbers': expandNumbers,
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'] as String,
        title: json['title'] as String,
        author: json['author'] as String? ?? '',
        language: json['language'] as String? ?? 'vi',
        sourceFile: json['sourceFile'] as String? ?? '',
        format: json['format'] as String? ?? 'txt',
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? '') ?? DateTime.now(),
        chapters: (json['chapters'] as List<dynamic>).map((c) => Chapter.fromJson(c as Map<String, dynamic>)).toList(),
        chunkCount: json['chunkCount'] as int,
        charCount: json['charCount'] as int,
        expandNumbers: json['expandNumbers'] as bool? ?? true,
      );
}
