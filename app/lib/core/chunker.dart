/// Cắt sách thành các đoạn nhỏ để tổng hợp giọng nói.
///
/// Mỗi đoạn là đơn vị của mọi thứ trong ứng dụng: đơn vị phát, đơn vị cache,
/// đơn vị lưu tiến trình và đơn vị ghép file khi xuất. Đoạn luôn kết thúc ở
/// ranh giới câu để giọng đọc không bị cụt giữa chừng.
library;

import '../models/book.dart';
import 'text_normalizer.dart';

/// Độ dài đoạn, tính bằng ký tự.
///
/// Bị chặn bởi bộ nhớ, không phải bởi nhịp đọc. Bộ giải mã âm của VieNeu tự-chú-ý
/// trên toàn bộ khung của cả đoạn một lượt, nên RAM tỉ lệ với **bình phương** độ
/// dài. Đo thật trên một mô hình:
///
///   4,6 giây âm thanh   ->  0,2 GB
///  12,8 giây            ->  1,3 GB
///  25,0 giây            ->  4,9 GB
///  ~50 giây             ->  hết bộ nhớ, ONNX Runtime báo bad allocation
///
/// Bản đầu đặt 400/680 ký tự, tức khoảng 27 và 47 giây — mỗi đoạn thường ngốn
/// gần 5 GB, và nhân với số worker chạy song song lúc xuất file thì lên vài chục
/// GB rồi chết. Giờ chặn ở khoảng 14 và 22 giây.
///
/// Cách sửa gốc là giải mã theo cửa sổ có gối đầu thay vì cả đoạn một lượt; khi
/// nào làm xong thì mới nới lại được hai con số này.
const int chunkTargetChars = 200;
const int chunkMaxChars = 320;

/// Số ký tự đọc được trong một giây ở tốc độ chuẩn — đo thực tế với giọng vi-VN.
const double charsPerSecond = 14.5;

final _nonTerminal = RegExp(r'(?:^|\s)(?:[A-ZĐÀ-Ỹ]|TS|GS|Th|Ths|Mr|Mrs|Ms|Dr|St|vd|tr|Nxb|NXB|vv)$');

/// Tách một đoạn văn thành các câu.
List<String> splitSentences(String paragraph) {
  final sentences = <String>[];
  var start = 0;

  for (var i = 0; i < paragraph.length; i++) {
    final ch = paragraph[i];
    if (ch != '.' && ch != '!' && ch != '?' && ch != ';') continue;

    // Gom các dấu liền nhau (?!, ...) và dấu đóng ngoặc/nháy đi kèm.
    var end = i + 1;
    while (end < paragraph.length && '.!?;"\')]»'.contains(paragraph[end])) {
      end++;
    }

    if (end < paragraph.length) {
      final next = paragraph[end];
      if (next != ' ' && next != '\n') continue; // "3.5", "a.b" — không phải hết câu
    }
    if (ch == '.') {
      final before = paragraph.substring(i - 5 < 0 ? 0 : i - 5, i);
      if (_nonTerminal.hasMatch(before)) continue;
    }

    final sentence = paragraph.substring(start, end).trim();
    if (sentence.isNotEmpty) sentences.add(sentence);
    start = end;
  }

  final tail = paragraph.substring(start).trim();
  if (tail.isNotEmpty) sentences.add(tail);
  return sentences;
}

/// Cắt nhỏ câu quá dài tại dấu phẩy, nếu vẫn dài thì cắt tại khoảng trắng.
List<String> _splitLongSentence(String sentence, int maxChars) {
  if (sentence.length <= maxChars) return [sentence];

  final pieces = <String>[];
  var buffer = '';
  for (final part in sentence.split(RegExp(r'(?<=[,:–-])\s+'))) {
    if (buffer.isNotEmpty && buffer.length + part.length + 1 > maxChars) {
      pieces.add(buffer);
      buffer = part;
    } else {
      buffer = buffer.isEmpty ? part : '$buffer $part';
    }
  }
  if (buffer.isNotEmpty) pieces.add(buffer);

  final out = <String>[];
  for (final piece in pieces) {
    if (piece.length <= maxChars) {
      out.add(piece);
      continue;
    }
    var line = '';
    for (final word in piece.split(' ')) {
      if (line.isNotEmpty && line.length + word.length + 1 > maxChars) {
        out.add(line);
        line = word;
      } else {
        line = line.isEmpty ? word : '$line $word';
      }
    }
    if (line.isNotEmpty) out.add(line);
  }
  return out;
}

final _hasContent = RegExp(r'[A-Za-zÀ-ỹ0-9]');

final _titleKey = RegExp(r'[^A-Za-zÀ-ỹ0-9]');

/// Số dòng đầu chương được soi để tìm tiêu đề bị lặp.
const _titleSearchLines = 4;

/// Bỏ dòng lặp lại tiêu đề chương trong phần thân, trả về phần thân đã sửa.
String _dropRepeatedTitle(String body, String title) {
  String key(String s) => s.replaceAll(_titleKey, '').toLowerCase();
  final wanted = key(title);
  if (wanted.isEmpty) return body;

  final lines = body.split('\n');
  var seen = 0;
  for (var i = 0; i < lines.length && seen < _titleSearchLines; i++) {
    if (lines[i].trim().isEmpty) continue;
    seen++;
    if (key(lines[i]) != wanted) continue;
    lines.removeAt(i);
    return lines.join('\n').replaceAll(RegExp(r'^\s*\n'), '').trimLeft();
  }
  return body;
}

/// Kết quả cắt sách: danh sách đoạn và thông tin từng chương.
class ChunkResult {
  ChunkResult(this.chunks, this.chapters);
  final List<Chunk> chunks;
  final List<Chapter> chapters;
}

/// Cắt toàn bộ sách thành các đoạn.
///
/// [onChapter] để báo tiến trình: chuẩn hoá văn bản chạy trên từng đoạn nên với
/// sách dày đây là phần tốn thời gian nhất của việc nhập sách.
ChunkResult buildChunks(
  List<RawChapter> rawChapters, {
  bool expandNumbers = true,
  int targetChars = chunkTargetChars,
  void Function(int done, int total)? onChapter,
}) {
  final maxChars = targetChars + 120 > chunkMaxChars ? targetChars + 120 : chunkMaxChars;
  final chunks = <Chunk>[];
  final chapters = <Chapter>[];

  for (var chapterIndex = 0; chapterIndex < rawChapters.length; chapterIndex++) {
    onChapter?.call(chapterIndex + 1, rawChapters.length);
    final raw = rawChapters[chapterIndex];
    final firstChunk = chunks.length;
    var charCount = 0;

    void push(String display, bool heading) {
      final speech = normalizeForSpeech(display, expandNumbers: expandNumbers);
      if (!_hasContent.hasMatch(speech)) return; // không còn gì để đọc
      chunks.add(Chunk(
        index: chunks.length,
        chapter: chapterIndex,
        display: display,
        speech: speech,
        heading: heading,
      ));
      charCount += display.length;
    }

    // Tiêu đề chương thành một đoạn riêng: người nghe biết đang ở đâu, và khi
    // xuất file theo chương thì mốc cắt trùng đúng đầu chương.
    final title = normalizeForDisplay(raw.title);
    if (title.isNotEmpty) {
      push('${title.replaceAll(RegExp(r'[.:\s]+$'), '')}.', true);
    }

    var body = normalizeForDisplay(raw.text);

    // EPUB thường lặp lại tiêu đề ngay đầu nội dung (thẻ <h1>) — bỏ đi để
    // người nghe không phải nghe tên chương hai lần.
    //
    // Xét vài dòng đầu chứ không chỉ dòng thứ nhất: nhiều sách còn chèn "Quyển
    // 3" hay tên tác giả phía trên tiêu đề, đẩy nó xuống dưới.
    if (title.isNotEmpty) {
      body = _dropRepeatedTitle(body, title);
    }

    var buffer = '';
    void flush() {
      final trimmed = buffer.trim();
      if (trimmed.isNotEmpty) push(trimmed, false);
      buffer = '';
    }

    for (final paragraph in body.split(RegExp(r'\n{2,}'))) {
      final clean = paragraph.replaceAll('\n', ' ').trim();
      if (clean.isEmpty) continue;

      for (final sentence in splitSentences(clean)) {
        for (final piece in _splitLongSentence(sentence, maxChars)) {
          if (buffer.isNotEmpty && buffer.length + piece.length + 1 > targetChars) flush();
          buffer = buffer.isEmpty ? piece : '$buffer $piece';
        }
      }
      // Hết đoạn văn thì chốt luôn nếu đã đủ dài — giữ nhịp nghỉ tự nhiên.
      if (buffer.length >= targetChars * 0.6) flush();
    }
    flush();

    final count = chunks.length - firstChunk;
    if (count > 0) {
      chapters.add(Chapter(
        index: chapterIndex,
        title: raw.title.isEmpty ? 'Chương ${chapterIndex + 1}' : raw.title,
        firstChunk: firstChunk,
        chunkCount: count,
        charCount: charCount,
      ));
    }
  }

  return ChunkResult(chunks, chapters);
}

/// Ước lượng thời lượng đọc (giây) từ số ký tự.
double estimateSeconds(int charCount, {double rate = 1.0}) => charCount / charsPerSecond / rate;
