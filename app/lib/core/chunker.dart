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

/// Trần CỨNG cho một đoạn, tính cả sau khi đã gộp mẩu ngắn. Không đoạn nào được
/// vượt, kể cả khi phải cắt một câu ra làm đôi để giữ được nó.
///
/// Đây không phải con số chọn cho đẹp mà suy thẳng từ giới hạn của mô hình: nó
/// chỉ sinh tối đa `max_new_frames = 300` khung (xem `native/vieneu/src/model.rs`),
/// 12,5 khung cho mỗi giây âm thanh, tức **24 giây tiếng**. Ở nhịp
/// [charsPerSecond] (~14,5 ký tự mỗi giây) thì 24 giây là khoảng 348 ký tự.
///
/// Chạm trần thì mô hình không hỏng theo kiểu báo lỗi — nó chỉ đơn giản hết
/// lượt sinh giữa chừng, đoạn đọc mất đuôi. Bộ soi âm (`kiem_am.dart`) thấy
/// thiếu âm nên đọc lại, mà lần nào cũng chạm đúng cái trần ấy, nên đủ năm lượt
/// đều trượt rồi đành lấy bản cụt.
///
/// 280 chừa lại 20% cho những đoạn đọc chậm hơn trung bình — 348 là mức KHÔNG
/// còn biên nào cả, không được lấy làm trần.
///
/// Bản trước để 440, lại còn cho phép gộp thêm mẩu ngắn lên trên nó, nên đoạn
/// dài nhất thực tế chạm ~540 ký tự ≈ 465 khung: gấp rưỡi mức mô hình làm nổi.
const int chunkMaxChars = 280;

/// Buffer dưới ngưỡng này (tính bằng ký tự) thì coi là "còn quá ngắn" — chưa
/// đủ để đứng thành một chunk riêng, phải gộp tiếp với câu/đoạn kế dù có vượt
/// [chunkTargetChars]. Dùng chung cho cả hai chỗ: cuối một đoạn văn (đừng chốt
/// non khi mới có vài chục ký tự) và mẩu cuối khi một đoạn quá dài bị chia nhỏ.
const int chunkMergeUnderChars = 100;

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

/// Xếp các mảnh vào từng mẩu theo đúng thứ tự, mỗi mẩu không quá [tran] ký tự.
///
/// Mảnh nào tự nó đã dài hơn [tran] thì vẫn đứng riêng một mẩu — không cắt được
/// nữa thì thà để dài còn hơn vứt đi.
List<String> _xepMau(List<String> manh, int tran) {
  final ra = <String>[];
  var dang = '';
  for (final m in manh) {
    if (dang.isEmpty) {
      dang = m;
    } else if (dang.length + 1 + m.length <= tran) {
      dang = '$dang $m';
    } else {
      ra.add(dang);
      dang = m;
    }
  }
  if (dang.isNotEmpty) ra.add(dang);
  return ra;
}

/// Câu không có dấu phẩy nào mà vẫn quá dài — đành cắt tại khoảng trắng.
List<String> _tachTaiKhoangTrang(String text, int tran) {
  final ra = <String>[];
  var dong = '';
  for (final tu in text.split(' ')) {
    if (dong.isNotEmpty && dong.length + 1 + tu.length > tran) {
      ra.add(dong);
      dong = tu;
    } else {
      dong = dong.isEmpty ? tu : '$dong $tu';
    }
  }
  if (dong.isNotEmpty) ra.add(dong);
  return ra;
}

/// Chia [manh] thành ĐÚNG [soMau] mẩu liền mạch, độ dài các mẩu đều nhau nhất,
/// mỗi mẩu không quá [tran].
///
/// Quy hoạch động, phạt theo BÌNH PHƯƠNG độ lệch so với độ dài lý tưởng
/// (tổng chia [soMau]). Phạt bình phương nên nó ghét một mẩu lệch nhiều hơn là
/// vài mẩu lệch ít — đúng nghĩa "đều nhau".
///
/// Vì sao không dùng phép dò trần nhỏ nhất rồi xếp tham lam: cách ấy cho ra mẩu
/// dài nhất ngắn nhất thật, nhưng vẫn dồn hết phần dư vào mẩu CUỐI. Đo trên câu
/// 18 mảnh chia 4 mẩu: ra 5-5-5-3 (234/234/234/140) chứ không phải 5-5-4-4
/// (234/234/187/187).
///
/// [manh] chỉ vài chục phần tử nên O(soMau × n²) là rẻ.
List<String> _chiaDeu(List<String> manh, int soMau, int tran) {
  final n = manh.length;

  // cong[i] = độ dài chuỗi ghép manh[0..i-1] bằng dấu cách.
  final cong = List<int>.filled(n + 1, 0);
  for (var i = 0; i < n; i++) {
    cong[i + 1] = cong[i] + manh[i].length + (i == 0 ? 0 : 1);
  }
  int dai(int i, int j) => i == 0 ? cong[j] : cong[j] - cong[i] - 1;

  final lyTuong = dai(0, n) / soMau;
  const voCung = double.infinity;
  final chiPhi = List.generate(soMau + 1, (_) => List<double>.filled(n + 1, voCung));
  final tu = List.generate(soMau + 1, (_) => List<int>.filled(n + 1, -1));
  chiPhi[0][0] = 0;

  for (var p = 1; p <= soMau; p++) {
    for (var j = p; j <= n; j++) {
      for (var i = p - 1; i < j; i++) {
        if (chiPhi[p - 1][i] == voCung) continue;
        final d = dai(i, j);
        if (d > tran) continue;
        final lech = d - lyTuong;
        final gia = chiPhi[p - 1][i] + lech * lech;
        if (gia < chiPhi[p][j]) {
          chiPhi[p][j] = gia;
          tu[p][j] = i;
        }
      }
    }
  }

  // Không xếp nổi đúng soMau mẩu (mảnh nào đó tự nó đã quá trần) thì lùi về
  // cách xếp tham lam — thà dài còn hơn không có gì.
  if (chiPhi[soMau][n] == voCung) return _xepMau(manh, tran);

  final ra = <String>[];
  var j = n;
  for (var p = soMau; p >= 1; p--) {
    final i = tu[p][j];
    ra.insert(0, manh.sublist(i, j).join(' '));
    j = i;
  }
  return ra;
}

/// Cắt một câu quá dài thành **ít mẩu nhất có thể**, và các mẩu **đều nhau nhất
/// có thể**.
///
/// Vì sao phải đều: cách cũ xếp tham lam — nhồi đầy tới sát trần rồi mới sang
/// mẩu mới — nên một câu 300 ký tự ra một mẩu 280 và một mẩu 20. Mẩu sát trần
/// chính là mẩu dễ chạm giới hạn khung của mô hình nhất (xem [chunkMaxChars]),
/// còn mẩu tí hon thì đọc lên cụt lủn. Chia đều thì cả hai cùng nằm giữa vùng
/// an toàn, mà tổng số mẩu vẫn không tăng.
///
/// 1. Cắt tại dấu phẩy (và `:`, `–`, `-`) thành các mảnh. Mảnh nào tự nó vẫn
///    quá dài thì cắt tiếp tại khoảng trắng.
/// 2. Xếp tham lam ở trần [maxChars] cho ra ĐÚNG số mẩu ít nhất có thể — tham
///    lam là tối ưu cho riêng việc đếm số mẩu.
/// 3. Giữ nguyên con số ấy rồi chia lại cho đều — xem [_chiaDeu].
List<String> _splitLongSentence(String sentence, int maxChars) {
  if (sentence.length <= maxChars) return [sentence];

  final manh = <String>[];
  for (final m in sentence.split(RegExp(r'(?<=[,:–-])\s+'))) {
    if (m.length <= maxChars) {
      manh.add(m);
    } else {
      // Cả câu không có dấu ngắt nào — đành cắt giữa câu, tại khoảng trắng.
      manh.addAll(_tachTaiKhoangTrang(m, maxChars));
    }
  }
  return _chiaMoc(manh, maxChars);
}

/// Gom [moc] thành ít mẩu nhất có thể, các mẩu đều nhau nhất có thể.
///
/// [moc] là các đơn vị KHÔNG được xé lẻ thêm — câu, hoặc vế câu ngăn bởi dấu
/// phẩy. Xếp tham lam cho ra số mẩu ít nhất (tham lam là tối ưu cho riêng việc
/// đếm), rồi [_chiaDeu] chia lại đúng chừng ấy mẩu cho đều.
List<String> _chiaMoc(List<String> moc, int tran) {
  final soMau = _xepMau(moc, tran).length;
  if (soMau <= 1) return _xepMau(moc, tran);
  return _chiaDeu(moc, soMau, tran);
}

/// Chia một đoạn nhiều câu, **ưu tiên cắt ở cuối câu**.
///
/// Chỉ câu nào tự nó đã dài quá [tran] mới bị cắt bên trong, và khi ấy mới tới
/// lượt dấu phẩy rồi mới tới khoảng trắng — xem [_splitLongSentence]. Câu vừa
/// vặn thì luôn nguyên vẹn, dù có phải để một mẩu ngắn hơn hẳn các mẩu khác.
List<String> _chiaTheoCau(String text, int tran) {
  final moc = <String>[];
  for (final cau in splitSentences(text)) {
    if (cau.length <= tran) {
      moc.add(cau);
    } else {
      moc.addAll(_splitLongSentence(cau, tran));
    }
  }
  if (moc.isEmpty) return [text];
  return _chiaMoc(moc, tran);
}

final _terminalPunct = RegExp('[.!?;…]["\')\\]»]*\$');
final _trailingSoftPunct = RegExp(r'[,:–—-]+\s*$');

/// Đảm bảo văn bản kết thúc bằng dấu hết câu.
///
/// Mô hình sinh giọng dựa vào dấu câu để biết khi nào nên dừng hẳn — thiếu nó
/// là một phần lý do mô hình đôi khi lặp lại vài từ cuối trước khi dừng. Hai
/// trường hợp hay thiếu: đoạn văn gốc vốn không có dấu kết (lỗi cào từ web
/// thường gặp), và câu quá dài bị cắt tại dấu phẩy/hai chấm/gạch ngang (xem
/// [_splitLongSentence]) — mẩu đầu của nó kết thúc bằng dấu phẩy dở dang chứ
/// không phải dấu hết câu. Gặp trường hợp sau thì bỏ dấu dở dang rồi mới thêm
/// ".", kẻo ra "...này,." sai chính tả.
String _ensureTerminal(String text) {
  final trimmed = text.trimRight();
  if (trimmed.isEmpty || _terminalPunct.hasMatch(trimmed)) return trimmed;
  return '${trimmed.replaceFirst(_trailingSoftPunct, '')}.';
}

final _hasContent = RegExp(r'[A-Za-zÀ-ỹ0-9]');

final _titleKey = RegExp(r'[^A-Za-zÀ-ỹ0-9]');

/// Số dòng đầu chương được soi để tìm tiêu đề bị lặp.
const _titleSearchLines = 4;

/// Đoạn đánh số ở đầu tiêu đề chương: "Chương 01:", "CHƯƠNG MỘT", "Hồi thứ ba".
///
/// Nhận cả chữ số, số La Mã lẫn số viết bằng chữ, vì mục lục và thân bài của
/// cùng một cuốn sách thường không dùng chung kiểu.
final _soChuong = RegExp(
  r'^\s*(chương|phần|hồi|quyển|tập|mục|chapter)\b[\s:.\-]*'
  r'(thứ\b[\s:.\-]*)?'
  // Số viết bằng chữ phải đứng TRƯỚC số La Mã: chữ "m" và "l" nằm trong tập ký
  // tự La Mã, nên để [ivxlcdm]+ đi trước thì nó ăn mất chữ đầu của "một",
  // "mười", "lẻ" và bỏ lại phần đuôi cụt.
  r'((\d+|một|hai|ba|bốn|tư|năm|lăm|sáu|bảy|tám|chín|mười|mươi'
  r'|trăm|nghìn|ngàn|linh|lẻ|[ivxlcdm]+)\b[\s:.\-]*)*',
  caseSensitive: false,
);

/// Bỏ dòng lặp lại tiêu đề chương trong phần thân, trả về phần thân đã sửa.
String _dropRepeatedTitle(String body, String title) {
  String key(String s) => s.replaceAll(_titleKey, '').toLowerCase();

  /// Phần tên chương sau khi bỏ đoạn đánh số ở đầu.
  ///
  /// Mục lục và thân bài thường đánh số theo hai kiểu khác nhau — mục lục ghi
  /// "Chương 01:" còn thân bài ghi "CHƯƠNG MỘT" — nên so nguyên văn thì trượt và
  /// người nghe phải nghe tên chương hai lần. Bỏ phần số đi thì cả hai cùng còn
  /// lại "ngôi nhà riddle" và khớp.
  String phanTen(String s) =>
      key(s.toLowerCase().replaceFirst(_soChuong, ''));

  final wanted = key(title);
  if (wanted.isEmpty) return body;
  final wantedTen = phanTen(title);

  final lines = body.split('\n');
  var seen = 0;
  for (var i = 0; i < lines.length && seen < _titleSearchLines; i++) {
    if (lines[i].trim().isEmpty) continue;
    seen++;
    // Khớp nguyên văn, HOẶC khớp phần tên sau khi bỏ số. Đòi phần tên khác rỗng
    // ở cả hai phía: "Chương 1" và "Chương 2" đều rút về rỗng, khớp rỗng với
    // rỗng là xoá nhầm dòng mở đầu của một chương khác.
    final khop = key(lines[i]) == wanted ||
        (wantedTen.isNotEmpty && phanTen(lines[i]) == wantedTen);
    if (!khop) continue;
    lines.removeAt(i);
    return lines.join('\n').replaceAll(RegExp(r'^\s*\n'), '').trimLeft();
  }
  return body;
}

/// Một từ trong văn bản, gồm cả chữ có dấu tiếng Việt.
final _tuTrongSach = RegExp(r'[A-Za-zÀ-ỹ]{2,}');

/// Từ này viết hoa toàn bộ (và có chữ cái để mà xét).
bool _hoaToanBo(String tu) => tu == tu.toUpperCase() && tu != tu.toLowerCase();

/// Dựng bảng "dạng viết hoa toàn bộ → dạng thường gặp trong chính cuốn sách".
///
/// Sinh ra để chữa một lỗi rất khó chịu: sea-g2p coi **một từ viết hoa toàn bộ
/// đứng giữa chữ thường là từ viết tắt** và đánh vần từng chữ cái. Với "USB" hay
/// "HTML" thì đúng, nhưng sách convert từ web hay viết hoa cả tiêu đề, nên
/// "Ngôi nhà RIDDLE." bị đọc thành "Ngôi nhà R-I-D-D-L-E".
///
/// Không có cách nào phân biệt "USB" với "RIDDLE" nếu chỉ nhìn một từ. Nhưng
/// nhìn cả cuốn sách thì có: **RIDDLE cũng xuất hiện ở dạng "Riddle"**, còn USB
/// thì không bao giờ viết thành "Usb". Nên bảng này chỉ chứa những từ có bằng
/// chứng trong chính văn bản, và từ viết tắt thật không lọt vào.
///
/// Lấy dạng gặp NHIỀU NHẤT chứ không phải dạng gặp đầu tiên: một chỗ lỡ viết
/// "riddle" thường không thắng được hàng trăm chỗ viết "Riddle".
Map<String, String> bangChuHoaTenRieng(List<RawChapter> chapters) {
  final dem = <String, Map<String, int>>{};
  for (final ch in chapters) {
    for (final nguon in [ch.title, ch.text]) {
      for (final m in _tuTrongSach.allMatches(nguon)) {
        final tu = m[0]!;
        if (_hoaToanBo(tu)) continue;
        (dem[tu.toLowerCase()] ??= {}).update(tu, (n) => n + 1, ifAbsent: () => 1);
      }
    }
  }

  final bang = <String, String>{};
  dem.forEach((thuong, cacDang) {
    var tot = '';
    var nhieuNhat = 0;
    cacDang.forEach((dang, n) {
      if (n > nhieuNhat) {
        nhieuNhat = n;
        tot = dang;
      }
    });
    if (tot.isNotEmpty) bang[thuong] = tot;
  });
  return bang;
}

/// Đổi những từ viết hoa toàn bộ về dạng thường gặp, theo [bang].
///
/// Chỉ dùng cho văn bản ĐỌC LÊN. Màn hình đọc vẫn hiện đúng chữ trong sách —
/// người ta viết hoa để nhấn mạnh, xoá đi là sửa sách của người khác.
String suaChuHoaTenRieng(String text, Map<String, String> bang) {
  if (bang.isEmpty) return text;
  return text.replaceAllMapped(_tuTrongSach, (m) {
    final tu = m[0]!;
    if (!_hoaToanBo(tu)) return tu;
    return bang[tu.toLowerCase()] ?? tu;
  });
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
  // Trần đến từ mô hình nên KHÔNG được nới theo targetChars. Bản trước lấy
  // max(targetChars + 120, chunkMaxChars), tức là cứ nâng mục tiêu là trần tự
  // dâng theo — đúng cái khiến đoạn vượt quá sức mô hình mà không ai thấy.
  const maxChars = chunkMaxChars;
  final target = targetChars > maxChars ? maxChars : targetChars;
  final chunks = <Chunk>[];
  final chapters = <Chapter>[];

  // Quét cả sách một lượt trước khi cắt: cần biết từ nào từng xuất hiện ở dạng
  // viết thường thì mới phân biệt được tên riêng viết hoa với từ viết tắt thật.
  final bangChuHoa = bangChuHoaTenRieng(rawChapters);

  for (var chapterIndex = 0; chapterIndex < rawChapters.length; chapterIndex++) {
    onChapter?.call(chapterIndex + 1, rawChapters.length);
    final raw = rawChapters[chapterIndex];
    final firstChunk = chunks.length;
    var charCount = 0;

    void push(String rawDisplay, bool heading) {
      final display = _ensureTerminal(rawDisplay);
      // Sửa chữ hoa TRƯỚC khi chuẩn hoá, để bước gắn thẻ tiếng Anh nhìn thấy
      // đúng dạng chữ. Chỉ đụng vào phần đọc lên; [display] giữ nguyên chữ
      // trong sách.
      final speech = normalizeForSpeech(
        suaChuHoaTenRieng(display, bangChuHoa),
        expandNumbers: expandNumbers,
      );
      if (!_hasContent.hasMatch(speech)) return; // không còn gì để đọc

      // Trần ở trên áp cho phần HIỂN THỊ, nhưng thứ mô hình phải đọc là phần
      // speech đã chuẩn hoá — mà chuẩn hoá làm văn bản NỞ RA: "1.234.567" chín
      // ký tự thành hơn năm mươi. Một đoạn đầy số vì thế vẫn có thể vượt trần ở
      // phần đọc dù phần hiển thị vẫn gọn. Đo trên ba bộ truyện thật: đoạn dài
      // nhất sau chuẩn hoá là 344 ký tự trong khi trần là 280 — sát ngân sách
      // khung tới mức không còn biên nào.
      //
      // Chia tiếp theo ĐÚNG tỉ lệ nở của chính đoạn này rồi đẩy lại từng mẩu.
      // Mỗi mẩu ngắn hơn hẳn đoạn cha nên đệ quy chắc chắn dừng.
      //
      // Đi qua [_chiaTheoCau] chứ không cắt thẳng tại dấu phẩy: đoạn này có thể
      // gồm nhiều câu, mà ranh giới câu vẫn phải được ưu tiên trước.
      if (!heading && speech.length > maxChars) {
        final tranHienThi = display.length * maxChars ~/ speech.length;
        if (tranHienThi > 0) {
          final manh = _chiaTheoCau(display, tranHienThi);
          if (manh.length > 1) {
            for (final m in manh) {
              push(m, false);
            }
            return;
          }
        }
      }

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
          final tong = local.isEmpty ? piece.length : local.length + 1 + piece.length;
          // Buffer cục bộ còn quá ngắn thì đừng chốt oan thành một chunk tí
          // hon chỉ vì piece kế đẩy tổng vượt target — cứ gộp xuống. NHƯNG
          // quyền gộp ấy dừng lại ở trần cứng: thà một chunk tí hon còn hơn
          // một chunk mô hình đọc không hết.
          final ngan = local.length < mergeUnderChars;
          if (local.isNotEmpty && (tong > maxChars || (!ngan && tong > target))) {
            pieces.add(local);
            local = '';
          }
          local = local.isEmpty ? piece : '$local $piece';
        }
      }

      // Đoạn văn này đã phải tách thành >=1 mẩu hoàn chỉnh (pieces không
      // rỗng) mà phần dư lại quá ngắn — thay vì để dư ra một mẩu tí hon riêng,
      // gộp nó vào mẩu hoàn chỉnh liền trước, vẫn trong cùng đoạn văn. Chỉ gộp
      // khi còn chỗ dưới trần cứng, cùng lý do như vòng lặp phía trên.
      if (pieces.isNotEmpty &&
          local.isNotEmpty &&
          local.length < mergeUnderChars &&
          pieces.last.length + 1 + local.length <= maxChars) {
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
