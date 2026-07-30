/// Bỏ phần rác mà các trang đăng truyện chèn vào sách.
///
/// Sách tải trên mạng gần như luôn kèm thứ không phải nội dung: tên trang web ở
/// đầu mỗi chương, dòng ghi công người convert, lời kêu gọi ủng hộ ở cuối
/// chương, trang bìa liệt kê nguồn, và cả một chương mục lục dài dằng dặc. Đọc
/// lên thì rất khó chịu — riêng mục lục của một bộ truyện dài có thể ngốn hơn
/// một tiếng đồng hồ chỉ để nghe đọc tên chương.
///
/// Có hai cách nhận rác, bổ sung cho nhau:
///
/// * **Theo mẫu** — bắt các dấu hiệu quen thuộc: tên miền, "Nguồn:", "Converter:",
///   "Đọc truyện tại...", dòng trang trí toàn ký hiệu.
/// * **Theo tần suất** — dòng ngắn nào lặp lại ở rìa của phần lớn các chương thì
///   gần như chắc chắn là rác, bất kể nội dung. Cách này bắt được cả những trang
///   web chưa từng biết tên.
library;

import '../models/book.dart';

/// Kết quả dọn dẹp, kèm số liệu để báo lại cho người dùng.
class CleanupReport {
  const CleanupReport({
    required this.chapters,
    required this.removedChapters,
    required this.removedLines,
  });

  final List<RawChapter> chapters;

  /// Số chương bị bỏ hẳn (mục lục, trang bìa, trang giới thiệu trang web).
  final int removedChapters;

  /// Số dòng rác bị bỏ bên trong các chương còn lại.
  final int removedLines;

  bool get isEmpty => removedChapters == 0 && removedLines == 0;

  /// Câu tóm tắt cho giao diện, rỗng nếu không bỏ gì.
  String get summary {
    if (isEmpty) return '';
    final parts = <String>[];
    if (removedChapters > 0) parts.add('$removedChapters mục lục/trang giới thiệu');
    if (removedLines > 0) parts.add('$removedLines dòng quảng cáo');
    return 'đã bỏ ${parts.join(' và ')}';
  }
}

/// Số dòng ở đầu và ở cuối chương được coi là "rìa" — rác chỉ nằm ở đó.
///
/// Giữ hẹp để một câu văn giữa chương có nhắc tới tên miền không bị xoá oan.
const _edgeLines = 8;

/// Dòng dài hơn thế này là văn xuôi thật, không phải dòng ghi công.
const _maxJunkLength = 120;

/// Tên miền đứng một mình hoặc kèm chữ — dấu hiệu mạnh nhất của rác.
final _domain = RegExp(
  r'(https?://|www\.)\S+|\b[\w-]{2,}\.(com|vn|net|org|info|xyz|club|top|me|co|biz|site|online)\b',
  caseSensitive: false,
);

// `\b` của Dart chỉ coi [A-Za-z0-9_] là ký tự từ, nên nó không nhận ra ranh giới
// trước "ủng hộ" hay sau "mục lục". Phải tự định nghĩa ranh giới theo bảng chữ
// cái tiếng Việt, nếu không những mẫu bắt đầu bằng chữ có dấu sẽ không khớp.
const _wordStart = r'(?<![A-Za-zÀ-ỹ])';
const _wordEnd = r'(?![A-Za-zÀ-ỹ])';

/// Các kiểu ghi công và kêu gọi hay gặp trong truyện mạng tiếng Việt.
final _creditPatterns = [
  RegExp(r'^\s*(nguồn|nguồn truyện|nguồn convert)\s*[:：]', caseSensitive: false),
  RegExp(r'^\s*(dịch|dịch giả|người dịch|nhóm dịch|dịch thuật)\s*[:：]', caseSensitive: false),
  RegExp(r'^\s*(convert(er)?|converter|biên tập|biên dịch|beta|edit(or)?|hiệu đính)\s*[:：]',
      caseSensitive: false),
  RegExp(r'^\s*(sưu tầm|đăng bởi|post bởi|upload|người đăng|nguồn ebook|ebook)\s*[:：]',
      caseSensitive: false),
  RegExp(r'(đọc|xem|theo dõi)\s+(tiếp\s+)?(truyện|chương|full|bản đẹp)?\s*(mới nhất\s*)?tại\b',
      caseSensitive: false),
  RegExp(r'truyện\s+(này\s+)?(được\s+)?(đăng|post|copy|sao chép)\s+(tải|tại|từ|bởi)\b',
      caseSensitive: false),
  RegExp(
      '$_wordStart(vui lòng|xin|hãy|mong)$_wordEnd.{0,30}'
      '$_wordStart(ủng hộ|đánh giá|bình chọn|theo dõi|like|share|donate|góp đề cử)$_wordEnd',
      caseSensitive: false),
  RegExp(
      '$_wordStart(fanpage|facebook|telegram|discord|zalo|group|nhóm dịch|wattpad)$_wordEnd'
      '.{0,40}$_wordStart(truyện|đọc|ủng hộ|chương)$_wordEnd',
      caseSensitive: false),
  RegExp('$_wordStart(bản quyền|copyright|all rights reserved)$_wordEnd', caseSensitive: false),
];

/// Dòng chỉ gồm ký hiệu trang trí: "——— o O o ———", "☆ ☆ ☆", "***".
final _decorative = RegExp(r'^[\s\p{P}\p{S}oOxX0]{3,}$', unicode: true);

/// "Chương 12", "Chương 12:", "Quyển 3 Chương 12 - Tên chương".
final _chapterRef = RegExp(r'(chương|quyển|hồi|tập)\s+\d{1,4}', caseSensitive: false);

/// Dấu hiệu của trang bìa: liệt kê thông tin sách chứ không phải nội dung.
final _frontMatterMarkers = [
  RegExp(r'^\s*tác giả\s*[:：]', caseSensitive: false, multiLine: true),
  RegExp(r'^\s*thể loại\s*[:：]', caseSensitive: false, multiLine: true),
  RegExp(r'^\s*(nguồn|dịch|convert(er)?|số chương|tình trạng)\s*[:：]',
      caseSensitive: false, multiLine: true),
];

bool _looksLikeCredit(String line) {
  if (line.length > _maxJunkLength) return false;
  return _creditPatterns.any((re) => re.hasMatch(line));
}

/// Dòng chỉ có tên miền (kèm tối đa vài chữ) — "DTV-EBOOK.COM.VN", "Nguồn: abc.vn".
bool _isDomainLine(String line) {
  if (line.length > _maxJunkLength) return false;
  final match = _domain.firstMatch(line);
  if (match == null) return false;
  // Tên miền phải chiếm phần lớn dòng, để câu văn có nhắc web không bị xoá.
  final rest = line.replaceAll(_domain, '').replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');
  return rest.length <= 12;
}

/// Chương chỉ toàn tên chương khác — tức là mục lục.
bool _isTableOfContents(RawChapter chapter) {
  if (RegExp(r'mục\s*lục|table of contents', caseSensitive: false).hasMatch(chapter.title)) {
    return true;
  }
  final refs = _chapterRef.allMatches(chapter.text).length;
  if (refs < 15) return false;
  // Đo bằng khoảng cách giữa hai lần nhắc tên chương. Trong mục lục, mỗi mục
  // chỉ dài vài chục ký tự nên chúng nằm sát nhau; trong một chương thật, tên
  // chương hoạ hoằn mới xuất hiện nên khoảng cách lên tới hàng nghìn ký tự.
  return chapter.text.length / refs < 120;
}

/// Trang bìa/trang giới thiệu: ngắn, liệt kê thông tin sách và nguồn tải.
bool _isFrontMatter(RawChapter chapter) {
  if (chapter.text.length > 900) return false;
  final markers = _frontMatterMarkers.where((re) => re.hasMatch(chapter.text)).length;
  if (markers >= 2) return true;
  return markers >= 1 && _domain.hasMatch(chapter.text);
}

/// Một chương đã tách dòng, giữ nguyên vị trí để dựng lại đúng ranh giới đoạn.
class _Lines {
  _Lines(String text) : all = text.split('\n') {
    for (var i = 0; i < all.length; i++) {
      final trimmed = all[i].trim();
      if (trimmed.isEmpty) continue;
      indexes.add(i);
      texts.add(trimmed);
    }
  }

  final List<String> all;

  /// Vị trí trong [all] của các dòng có chữ.
  final List<int> indexes = [];

  /// Nội dung đã cắt khoảng trắng của các dòng có chữ.
  final List<String> texts = [];

  /// Các dòng có chữ nằm ở đầu hoặc cuối chương.
  Set<int> get edgePositions {
    final head = texts.length < _edgeLines ? texts.length : _edgeLines;
    final tailFrom = texts.length - _edgeLines < head ? head : texts.length - _edgeLines;
    return {
      for (var i = 0; i < head; i++) i,
      for (var i = tailFrom; i < texts.length; i++) i,
    };
  }

  Iterable<String> get edgeTexts => edgePositions.map((i) => texts[i]);
}

/// Tìm những dòng ngắn lặp lại ở rìa của phần lớn các chương.
Set<String> _repeatedEdgeLines(List<_Lines> chapters) {
  if (chapters.length < 4) return const {};

  final counts = <String, int>{};
  for (final chapter in chapters) {
    final seen = <String>{};
    for (final line in chapter.edgeTexts) {
      if (line.length <= _maxJunkLength) seen.add(line);
    }
    for (final line in seen) {
      counts[line] = (counts[line] ?? 0) + 1;
    }
  }

  // Ngưỡng 40%: đủ thấp để bắt được rác ở sách có vài chương không kèm rác,
  // đủ cao để một câu thoại hay lặp lại không bị coi là quảng cáo.
  final threshold = (chapters.length * 0.4).ceil().clamp(3, chapters.length);
  return counts.entries.where((e) => e.value >= threshold).map((e) => e.key).toSet();
}

/// Dọn rác khỏi danh sách chương vừa trích từ file sách.
CleanupReport stripBoilerplate(List<RawChapter> chapters) {
  if (chapters.isEmpty) {
    return CleanupReport(chapters: chapters, removedChapters: 0, removedLines: 0);
  }

  // Bước 1: bỏ hẳn mục lục và trang bìa.
  final kept = <RawChapter>[];
  var removedChapters = 0;
  for (final chapter in chapters) {
    if (_isTableOfContents(chapter) || _isFrontMatter(chapter)) {
      removedChapters++;
      continue;
    }
    kept.add(chapter);
  }
  // Bỏ hết thì chắc chắn nhận nhầm — thà đọc thừa còn hơn mất sách.
  if (kept.isEmpty) {
    kept.addAll(chapters);
    removedChapters = 0;
  }

  // Bước 2: tìm dòng lặp ở rìa các chương.
  final parsed = [for (final chapter in kept) _Lines(chapter.text)];
  final repeated = _repeatedEdgeLines(parsed);

  // Bước 3: bỏ dòng rác ở rìa từng chương.
  final cleaned = <RawChapter>[];
  var removedLines = 0;
  for (var i = 0; i < kept.length; i++) {
    final chapter = parsed[i];
    final edges = chapter.edgePositions;
    final drop = <int>{};

    for (var n = 0; n < chapter.texts.length; n++) {
      final line = chapter.texts[n];
      final atEdge = edges.contains(n);
      final junk = _isDomainLine(line) ||
          (atEdge && (repeated.contains(line) || _looksLikeCredit(line) || _decorative.hasMatch(line)));
      if (junk) drop.add(chapter.indexes[n]);
    }

    // Bỏ sạch cả chương thì chắc chắn nhận nhầm — giữ nguyên bản gốc.
    if (drop.isEmpty || drop.length == chapter.texts.length) {
      cleaned.add(kept[i]);
      continue;
    }

    // Giữ nguyên dòng trống để ranh giới đoạn văn không bị mất, rồi mới gộp
    // các dòng trống thừa lại — bộ cắt đoạn dựa vào đúng chỗ này.
    final out = <String>[];
    for (var n = 0; n < chapter.all.length; n++) {
      if (!drop.contains(n)) out.add(chapter.all[n]);
    }
    final text = out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();

    removedLines += drop.length;
    cleaned.add(RawChapter(kept[i].title, text));
  }

  return CleanupReport(
    chapters: cleaned,
    removedChapters: removedChapters,
    removedLines: removedLines,
  );
}
