/// Cắt sách thành các đoạn nhỏ để tổng hợp giọng nói.
///
/// Mỗi đoạn là đơn vị của mọi thứ trong ứng dụng: đơn vị phát, đơn vị cache,
/// đơn vị lưu tiến trình và đơn vị ghép file khi xuất. Đoạn luôn kết thúc ở
/// ranh giới câu.
///
/// Đoạn văn gốc (ngăn bởi dòng trống) là mốc ưu tiên để chốt một chunk — hết
/// một đoạn văn mà đã đủ dài thì chốt luôn ở đó thay vì kéo sang đoạn kế, để
/// chỗ ngắt tác giả đặt ra không bị xoá mất. Nhưng nhiều đoạn văn gốc quá ngắn
/// (nhiều truyện convert từ web bọc MỖI CÂU vào một đoạn/thẻ `<p>` riêng — xem
/// `epub_parser.dart`, mỗi câu thoại một `<p>`) thì phải gộp lại với đoạn kế
/// cho tới khi đủ dài, không thì chunk vỡ vụn thành từng câu một.
library;

import '../models/book.dart';
import 'text_normalizer.dart';

/// Độ dài đoạn mục tiêu, tính bằng ký tự — KHÔNG phải mốc tuỳ ý, mà là trần
/// thật của mô hình sinh âm.
///
/// Từng thử đổi sang đơn vị từ và nhắm ~200 từ (~1300 ký tự) để chunk bám theo
/// đoạn văn thật xa hơn — sập ngay: mô hình tự hồi quy VieNeu không "biết dừng
/// đúng lúc" với đoạn dài cỡ đó, đọc vội và ra tiếng vô nghĩa (đo được: một
/// đoạn ~200 từ không dừng nổi trong nhiều phút dù đã nới `max_new_frames` lên
/// 3500).
///
/// Hạ từ 400 xuống đúng 256 — con số ghi trong README về thư viện VieNeu gốc:
/// nó tự cắt câu thành mảnh ≤256 ký tự trước khi đưa vào mô hình. Đo thực
/// nghiệm thì 256 và 400 cho tỉ lệ lặp chữ giống nhau (không phải nguyên nhân
/// chính), nhưng 256 là đúng con số nguyên bản nên không có lý do giữ 400.
///
/// Đây là MỤC TIÊU chứ không phải trần cứng: hết câu/hết đoạn văn luôn được ưu
/// tiên hơn bám sát con số này — xem [chunkMaxChars] và nhánh chốt-cuối-đoạn
/// trong [buildChunks].
const int chunkTargetChars = 256;

/// Trần cứng cho một mẩu câu bị chia nhỏ.
///
/// Chỉ áp dụng khi MỘT câu (không có dấu chấm câu nào giữa chừng) tự nó đã dài
/// hơn mức này — cắt tại dấu phẩy trước, tại khoảng trắng nếu vẫn không đủ.
/// Câu bình thường không bao giờ chạm tới đây.
const int chunkMaxChars = 440;

/// Buffer dưới ngưỡng này (tính bằng ký tự) thì coi là "còn quá ngắn" — chưa
/// đủ để đứng thành một chunk riêng, phải gộp tiếp với câu/đoạn kế dù có vượt
/// [chunkTargetChars]. Dùng chung cho cả hai chỗ: cuối một đoạn văn (đừng chốt
/// non khi mới có vài chục ký tự) và mẩu cuối khi một đoạn quá dài bị chia nhỏ.
const int chunkMergeUnderChars = 100;

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
  int mergeUnderChars = chunkMergeUnderChars,
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

      // Xử lý đoạn văn này trên một buffer cục bộ, bắt đầu từ đúng chỗ buffer
      // đang mang theo (để đoạn ngắn nối được với đoạn ngắn liền trước). Mẩu
      // nào tràn quá targetChars thì chốt luôn vào [pieces]; phần còn dư sau
      // khi xử lý hết đoạn văn thì giữ lại trong buffer cục bộ.
      final pieces = <String>[];
      var local = buffer;
      buffer = '';

      for (final sentence in splitSentences(clean)) {
        for (final piece in _splitLongSentence(sentence, maxChars)) {
          // Buffer cục bộ còn quá ngắn thì đừng chốt oan thành một chunk tí
          // hon chỉ vì piece kế đẩy tổng vượt targetChars — cứ gộp xuống.
          final ngan = local.length < mergeUnderChars;
          if (local.isNotEmpty && !ngan && local.length + piece.length + 1 > targetChars) {
            pieces.add(local);
            local = '';
          }
          local = local.isEmpty ? piece : '$local $piece';
        }
      }

      // Đoạn văn này đã phải tách thành >=1 mẩu hoàn chỉnh (pieces không
      // rỗng) mà phần dư lại quá ngắn — thay vì để dư ra một mẩu tí hon riêng,
      // gộp nó vào mẩu hoàn chỉnh liền trước, vẫn trong cùng đoạn văn.
      if (pieces.isNotEmpty && local.length < mergeUnderChars) {
        pieces[pieces.length - 1] = '${pieces.last} $local';
        local = '';
      }

      for (final piece in pieces) {
        push(piece, false);
      }

      buffer = local;

      // Hết đoạn văn gốc thì chốt luôn nếu đã đủ dài — ưu tiên khoảng nghỉ tự
      // nhiên ở ranh giới đoạn văn thật, thay vì kéo sang đoạn kế chỉ vì chưa
      // chạm mốc targetChars.
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
