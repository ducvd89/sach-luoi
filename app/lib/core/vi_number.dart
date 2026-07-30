/// Đọc số thành chữ tiếng Việt.
///
/// Máy đọc phát âm tự nhiên hơn nhiều khi không phải tự đoán "1975" là năm hay
/// số lượng, nên ta chuyển sẵn sang chữ trước khi gửi đi tổng hợp. Có xử lý các
/// biến thể chuẩn: "mốt", "tư", "lăm", "linh".
library;

const _digits = ['không', 'một', 'hai', 'ba', 'bốn', 'năm', 'sáu', 'bảy', 'tám', 'chín'];
const _scales = ['', ' nghìn', ' triệu', ' tỷ'];

/// Đọc một nhóm 3 chữ số.
///
/// [full] là true khi phía trước còn nhóm khác, khi đó phải đọc đủ "không trăm".
String _readGroup(int n, bool full) {
  final hundreds = n ~/ 100;
  final tens = (n % 100) ~/ 10;
  final units = n % 10;
  final parts = <String>[];

  if (hundreds > 0 || full) parts.add('${_digits[hundreds]} trăm');

  if (tens == 0) {
    if (units > 0 && (hundreds > 0 || full)) {
      parts.addAll(['linh', _digits[units]]);
    } else if (units > 0) {
      parts.add(_digits[units]);
    }
  } else if (tens == 1) {
    parts.add('mười');
    if (units == 5) {
      parts.add('lăm');
    } else if (units > 0) {
      parts.add(_digits[units]);
    }
  } else {
    parts.add('${_digits[tens]} mươi');
    if (units == 1) {
      parts.add('mốt');
    } else if (units == 4) {
      parts.add('tư');
    } else if (units == 5) {
      parts.add('lăm');
    } else if (units > 0) {
      parts.add(_digits[units]);
    }
  }
  return parts.join(' ');
}

/// Đọc một số nguyên (có thể âm) thành chữ.
String readInteger(String value) {
  var s = value.trim();
  var sign = '';
  if (s.startsWith('-')) {
    sign = 'âm ';
    s = s.substring(1);
  }
  s = s.replaceFirst(RegExp(r'^0+(?=\d)'), '');
  if (!RegExp(r'^\d+$').hasMatch(s)) return value;
  if (s == '0') return '${sign}không';

  // Số quá dài (số điện thoại, mã số) thì đọc từng chữ số cho rõ.
  if (s.length > 12) {
    return sign + s.split('').map((d) => _digits[int.parse(d)]).join(' ');
  }

  final groups = <int>[];
  for (var i = s.length; i > 0; i -= 3) {
    groups.insert(0, int.parse(s.substring(i - 3 < 0 ? 0 : i - 3, i)));
  }

  final parts = <String>[];
  for (var i = 0; i < groups.length; i++) {
    if (groups[i] == 0) continue;
    final scaleIndex = groups.length - 1 - i;
    parts.add(_readGroup(groups[i], i > 0 && parts.isNotEmpty) + _scales[scaleIndex % 4]);
  }
  final body = parts.isEmpty ? 'không' : parts.join(' ');
  return sign + body;
}

/// Đọc phần thập phân: `3,25` -> "ba phẩy hai năm".
String readDecimal(String intPart, String fracPart) {
  final frac = fracPart.split('').map((d) {
    final n = int.tryParse(d);
    return n == null ? d : _digits[n];
  }).join(' ');
  return '${readInteger(intPart)} phẩy $frac';
}

const _romanValues = {'i': 1, 'v': 5, 'x': 10, 'l': 50, 'c': 100, 'd': 500, 'm': 1000};

final _canonicalRoman = RegExp(
  r'^M{0,3}(CM|CD|D?C{0,3})(XC|XL|L?X{0,3})(IX|IV|V?I{0,3})$',
  caseSensitive: false,
);

/// Kiểm tra chuỗi có phải số La Mã viết đúng chuẩn không.
///
/// Chặt hơn [romanToNumber]: "IV" hợp lệ còn "IIII" hay "DVD" thì không. Dùng
/// khi phải đoán xem một cụm chữ in hoa là số hay chỉ là chữ viết tắt.
bool isRomanNumeral(String text) => text.isNotEmpty && _canonicalRoman.hasMatch(text);

/// Chuyển số La Mã sang số thường, trả về null nếu không hợp lệ.
int? romanToNumber(String text) {
  final s = text.toLowerCase();
  if (s.isEmpty || !RegExp(r'^[ivxlcdm]+$').hasMatch(s)) return null;
  var total = 0;
  var prev = 0;
  for (var i = s.length - 1; i >= 0; i--) {
    final v = _romanValues[s[i]]!;
    if (v < prev) {
      total -= v;
    } else {
      total += v;
      prev = v;
    }
  }
  return (total > 0 && total < 4000) ? total : null;
}
