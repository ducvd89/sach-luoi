/// Chuẩn hoá văn bản trước khi tổng hợp giọng nói.
///
/// Máy đọc hay vấp ở chuỗi số dài, ngày tháng, đơn vị đo, viết tắt và dấu câu
/// lạ. Chuẩn hoá sẵn giúp giọng đọc mượt và đúng ngữ điệu hơn hẳn. Có thể tắt
/// trong phần Cài đặt.
library;

import 'vi_number.dart';

typedef _Rule = (RegExp, String);

/// Viết tắt phổ biến trong sách tiếng Việt.
final List<_Rule> _abbreviations = [
  (RegExp(r'\bTP\.?\s*HCM\b', caseSensitive: false), 'Thành phố Hồ Chí Minh'),
  (RegExp(r'\bTP\.\s*', caseSensitive: false), 'Thành phố '),
  (RegExp(r'\bTX\.\s*', caseSensitive: false), 'Thị xã '),
  (RegExp(r'\bQ\.(?=\s*\d)', caseSensitive: false), 'Quận '),
  (RegExp(r'\bP\.(?=\s*\d)', caseSensitive: false), 'Phường '),
  (RegExp(r'\bĐT\.\s*', caseSensitive: false), 'Điện thoại '),
  (RegExp(r'\bPGS\.?TS\.?', caseSensitive: false), 'Phó giáo sư tiến sĩ'),
  (RegExp(r'\bGS\.?TS\.?', caseSensitive: false), 'Giáo sư tiến sĩ'),
  (RegExp(r'\bPGS\.?'), 'Phó giáo sư'),
  (RegExp(r'\bGS\.(?=\s)'), 'Giáo sư'),
  (RegExp(r'\bTS\.(?=\s)'), 'Tiến sĩ'),
  (RegExp(r'\bThS\.?(?=\s)', caseSensitive: false), 'Thạc sĩ'),
  (RegExp(r'\bBS\.(?=\s)'), 'Bác sĩ'),
  (RegExp(r'\bKS\.(?=\s)'), 'Kỹ sư'),
  (RegExp(r'\bNXB\b\.?', caseSensitive: false), 'Nhà xuất bản'),
  (RegExp(r'\bv\.v\.{0,3}', caseSensitive: false), 'vân vân.'),
  (RegExp(r'\bTk\.\s*', caseSensitive: false), 'Thế kỷ '),
  (RegExp(r'\bTNHH\b'), 'trách nhiệm hữu hạn'),
  (RegExp(r'\bCTCP\b'), 'công ty cổ phần'),
  (RegExp(r'\bUBND\b'), 'Ủy ban nhân dân'),
  (RegExp(r'\bHĐND\b'), 'Hội đồng nhân dân'),
  (RegExp(r'\b[Tt]r\.(?=\s*\d)'), 'trang '),
  (RegExp(r'\bMr\.\s*'), 'ông '),
  (RegExp(r'\bMrs\.\s*'), 'bà '),
  (RegExp(r'\bMs\.\s*'), 'cô '),
  (RegExp(r'\bDr\.\s*'), 'tiến sĩ '),
  (RegExp(r'\bSt\.\s*'), 'thánh '),
  (RegExp(r'\betc\.\s*', caseSensitive: false), 'vân vân. '),
  (RegExp(r'\bTCN\b'), 'trước Công nguyên'),
  (RegExp(r'\bSCN\b'), 'sau Công nguyên'),
];

/// Ký hiệu và đơn vị đo.
final List<_Rule> _symbols = [
  (RegExp(r'(\d)\s*°\s*C\b'), r'$1 độ C'),
  (RegExp(r'(\d)\s*°\s*F\b'), r'$1 độ F'),
  (RegExp(r'(\d)\s*°'), r'$1 độ'),
  (RegExp(r'(\d)\s*%'), r'$1 phần trăm'),
  (RegExp(r'(\d)\s*km²', caseSensitive: false), r'$1 ki lô mét vuông'),
  (RegExp(r'(\d)\s*m²', caseSensitive: false), r'$1 mét vuông'),
  (RegExp(r'(\d)\s*cm²', caseSensitive: false), r'$1 xen ti mét vuông'),
  (RegExp(r'(\d)\s*km/h', caseSensitive: false), r'$1 ki lô mét trên giờ'),
  (RegExp(r'(\d)\s*m/s', caseSensitive: false), r'$1 mét trên giây'),
  (RegExp(r'(\d)\s*kg\b'), r'$1 ki lô gam'),
  (RegExp(r'(\d)\s*km\b'), r'$1 ki lô mét'),
  (RegExp(r'(\d)\s*cm\b'), r'$1 xen ti mét'),
  (RegExp(r'(\d)\s*mm\b'), r'$1 mi li mét'),
  (RegExp(r'(\d)\s*ml\b'), r'$1 mi li lít'),
  (RegExp(r'(\d)\s*kW\b'), r'$1 ki lô oát'),
  (RegExp(r'(\d)\s*USD\b'), r'$1 đô la Mỹ'),
  // Dùng lookahead thay cho \b: "đ"/"Đ" không phải ký tự \w nên \b không chạy.
  (RegExp(r'(\d)\s*VN[ĐD](?![A-Za-zÀ-ỹ])', caseSensitive: false), r'$1 đồng'),
  (RegExp(r'(\d)\s*đ(?![A-Za-zÀ-ỹ])'), r'$1 đồng'),
  (RegExp(r'\$\s*(\d[\d.,]*)'), r'$1 đô la'),
  (RegExp(r'&'), ' và '),
  (RegExp(r'(\d)\s*=\s*(\d)'), r'$1 bằng $2'),
];

/// Số mục La Mã kiểu "VI." — luôn có dấu chấm ngay sau và đứng ở vị trí đánh
/// mục (đầu đoạn, đầu dòng, sau dấu kết câu hoặc sau ngoặc mở). Nhóm 1 là phần
/// đứng trước cần giữ lại, nhóm 2 là số La Mã.
///
/// Ràng buộc vị trí là thứ giữ cho "đĩa CD.", "cô ấy là MC." không bị đọc thành
/// số: chúng đứng sau một chữ thường giữa câu chứ không mở đầu một mục.
final _romanItem = RegExp(r'(^|[\n\r]\s*|[.!?;:]\s+|[("\[]\s*)([IVXLCDM]{2,8})\.(?=\s|$)');

/// Một chữ cái thì mơ hồ hơn nhiều ("C. Mác", "V. Hugo"), nên chỉ nhận I, V, X
/// khi mở đầu dòng và phía sau không phải chữ cái viết tắt tiếp theo của tên
/// người ("V. I. Lênin").
final _romanItemSingle = RegExp(r'(^|[\n\r]\s*)([IVX])\.(?=\s|$)(?!\s+[A-ZĐÀ-Ỹ]\.)');

/// Số mục lớn nhất còn hợp lý. Vượt ngưỡng này gần như chắc chắn là chữ viết
/// tắt trùng ký tự La Mã ("CD." = 400, "MC." = 1100) chứ không phải đánh mục.
const _maxRomanItem = 40;

/// Đọc cụm La Mã thành số thứ tự mục, trả về null nếu trông không giống số mục.
String? _romanItemNumber(String roman) {
  if (!isRomanNumeral(roman)) return null;
  final n = romanToNumber(roman);
  return (n == null || n > _maxRomanItem) ? null : '$n';
}

final _invisible = RegExp(r'[­​-‏⁠﻿]');
final _numberToken = RegExp(r'\d[\d.,]*\d|\d');
final _thousandsVi = RegExp(r'^\d{1,3}(\.\d{3})+$');
final _thousandsEn = RegExp(r'^\d{1,3}(,\d{3})+$');
final _decimal = RegExp(r'^(\d+)[.,](\d+)$');
final _integer = RegExp(r'^\d+$');

/// Chuẩn hoá văn bản để đọc lên.
String normalizeForSpeech(String text, {bool expandNumbers = true}) {
  var out = text;

  // 1. Dọn ký tự vô hình và dấu câu lạ.
  out = out
      .replaceAll(_invisible, '')
      .replaceAll(' ', ' ')
      .replaceAll(RegExp(r'[“”„«»]'), '"')
      .replaceAll(RegExp(r"[‘’‚‹›]"), "'")
      .replaceAll('…', '.')
      .replaceAll(RegExp(r'[–—―]'), '-')
      .replaceAll(RegExp(r'\*+'), '')
      .replaceAll(RegExp(r'_{2,}'), '')
      .replaceAll(RegExp(r'={3,}'), '')
      .replaceAll(RegExp(r'-{3,}'), '.')
      .replaceAll(RegExp(r'\.{3,}'), '.');

  // 2. Bỏ dấu chú thích kiểu [12] và URL — đọc lên chỉ gây rối.
  out = out
      .replaceAll(RegExp(r'\[\s*\d{1,3}\s*\]'), '')
      .replaceAll(RegExp(r'https?://\S+', caseSensitive: false), '')
      .replaceAll(RegExp(r'\bwww\.\S+', caseSensitive: false), '');

  // 3. Viết tắt — làm trước để dấu chấm trong "TS." không bị hiểu là hết câu.
  for (final (pattern, replacement) in _abbreviations) {
    out = out.replaceAll(pattern, replacement);
  }

  if (expandNumbers) {
    // 4a. Thời gian: 10:30 và 10h30 -> "10 giờ 30".
    out = out.replaceAllMapped(RegExp(r'\b(\d{1,2})\s*[:h]\s*(\d{2})\b(?!\s*[:h]?\d)'), (m) {
      final h = int.parse(m[1]!);
      final mi = int.parse(m[2]!);
      if (h >= 24 || mi >= 60) return m[0]!;
      return mi == 0 ? '$h giờ' : '$h giờ ${m[2]}';
    });

    // 4b. Ngày tháng. Lookbehind tránh đọc thành "ngày ngày 20...".
    out = out.replaceAllMapped(RegExp(r'([Nn]gày\s+)?\b(\d{1,2})/(\d{1,2})/(\d{4})\b'), (m) {
      final d = int.parse(m[2]!);
      final mo = int.parse(m[3]!);
      if (d > 31 || mo > 12) return m[0]!;
      return 'ngày ${m[2]} tháng ${m[3]} năm ${m[4]}';
    });
    out = out.replaceAllMapped(RegExp(r'([Tt]háng\s+)?\b(\d{1,2})/(\d{4})\b'), (m) {
      final mo = int.parse(m[2]!);
      if (mo > 12) return m[0]!;
      return 'tháng ${m[2]} năm ${m[3]}';
    });

    // 4c. Khoảng số: "1945-1954" -> "1945 đến 1954".
    out = out.replaceAllMapped(RegExp(r'(\d)\s*-\s*(\d)'), (m) => '${m[1]} đến ${m[2]}');
  }

  // 5. Ký hiệu, đơn vị.
  for (final (pattern, replacement) in _symbols) {
    out = out.replaceAllMapped(pattern, (m) {
      var result = replacement;
      for (var g = m.groupCount; g >= 1; g--) {
        result = result.replaceAll('\$$g', m[g] ?? '');
      }
      return result;
    });
  }

  // 6. Số La Mã trong tiêu đề: "Chương IV" -> "Chương 4".
  out = out.replaceAllMapped(
    RegExp(r'\b(Chương|chương|Phần|phần|Quyển|quyển|Tập|tập|Hồi|hồi|Mục|mục|[Tt]hế kỷ|[Tt]hế kỉ)\s+([IVXLCDM]{1,8})\b'),
    (m) {
      final n = romanToNumber(m[2]!);
      return n == null ? m[0]! : '${m[1]} $n';
    },
  );

  // 6b. Số mục La Mã đứng riêng: "VI. Kết luận" -> "6. Kết luận" (đọc "sáu").
  // Dấu chấm là điều kiện bắt buộc — "VI" trần vẫn đọc là "vi" như thường.
  String replaceItem(Match m) {
    final n = _romanItemNumber(m[2]!);
    return n == null ? m[0]! : '${m[1]}$n.';
  }

  out = out.replaceAllMapped(_romanItem, replaceItem);
  out = out.replaceAllMapped(_romanItemSingle, replaceItem);

  if (expandNumbers) {
    // 7. Chuyển số sang chữ.
    out = out.replaceAllMapped(_numberToken, (m) {
      var s = m[0]!;
      // Dấu phân cách nghìn kiểu Việt (1.234.567) hoặc kiểu Anh (1,234,567).
      if (_thousandsVi.hasMatch(s)) {
        s = s.replaceAll('.', '');
      } else if (_thousandsEn.hasMatch(s)) {
        s = s.replaceAll(',', '');
      }

      final dec = _decimal.firstMatch(s);
      if (dec != null) return readDecimal(dec[1]!, dec[2]!);
      if (_integer.hasMatch(s)) return readInteger(s);
      return m[0]!;
    });
  }

  // 8. Dọn khoảng trắng và dấu câu thừa.
  out = out
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAllMapped(RegExp(r'\s+([,.;:!?])'), (m) => m[1]!)
      .replaceAllMapped(RegExp(r'([,.;:!?])\1{1,}'), (m) => m[1]!)
      .replaceAll(RegExp(r'\(\s*\)'), '')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  return out;
}

/// Chuẩn hoá nhẹ để hiển thị trên màn hình đọc: giữ nguyên chữ số và dấu câu.
String normalizeForDisplay(String text) {
  return text
      .replaceAll(_invisible, '')
      .replaceAll(' ', ' ')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}
