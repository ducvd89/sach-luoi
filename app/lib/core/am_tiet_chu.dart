/// Đoán số âm tiết mà một đoạn văn bản SẼ đọc ra thành.
///
/// Tách khỏi `kiem_am.dart` vì đây là bài toán chữ nghĩa thuần tuý, không dính
/// gì tới sóng âm: bên kia đếm âm NGHE THẤY, bên này đếm âm ĐÁNG LẼ PHẢI CÓ,
/// rồi `kiem_am.dart` so hai con số.
///
/// ## Vì sao không chỉ đếm từ
///
/// Bản đầu đếm đúng một âm cho mỗi từ cách nhau bằng khoảng trắng. Với tiếng
/// Việt thuần thì đúng gần như tuyệt đối — mỗi chữ là một âm tiết. Nhưng sách
/// dịch và sách kỹ thuật lẫn đầy tên riêng nước ngoài, mà một từ tiếng Anh
/// thường nhiều âm tiết:
///
/// | Câu | Đếm cũ | Đọc thật |
/// |---|---|---|
/// | `Harry Potter` | 2 | 4 (`hˈæɹi pˈɑːɾɚ`) |
/// | `Cắm USB vào máy` | 4 | 6 (`jˈuː ˈɛs bˈiː`) |
/// | `mở Windows lên` | 3 | 4 (`wˈɪndoʊz`) |
///
/// Đếm hụt thì tỉ lệ âm/từ vọt lên trên trần 115%, đoạn đọc hoàn toàn đúng vẫn
/// bị kết tội rồi đọc lại tới 5 lần — vừa chậm vừa vô ích, và lần nào cũng
/// trượt như nhau vì lỗi nằm ở phép đếm chứ không ở bản đọc. Đo trên bộ câu
/// trong `am_tiet_chu_test.dart`: lệch trung bình **24,3%** so với âm vị thật,
/// giờ còn **1,5%**.
///
/// ## Ba đường đi, chọn theo cấu trúc chứ không theo từ điển
///
/// Mọi con số dưới đây đo bằng chính sea-g2p mà engine dùng — nghĩa là so với
/// âm vị mô hình thật sự nhận, không phải với cách người ta nghĩ từ ấy đọc ra
/// sao. Cách dựng lại: `am_tiet_chu_test.dart` gọi thẳng g2p rồi đếm nhân âm,
/// hoặc soi từng câu bằng `native/vieneu/examples/soi_am_vi.rs`.
///
/// Thứ tự ba đường là một phần của thuật toán, đừng đảo:
///
/// 1. **Viết hoa toàn bộ → đánh vần từng chữ cái.** sea-g2p coi từ viết hoa
///    đứng giữa chữ thường là viết tắt (`USB → jˌuːˌɛsbˈiː`). Riêng `W` ba âm
///    ("đáp-bờ-liu" — `dˌʌbəljˌuː`). Phải xét TRƯỚC bước 2 — xem [_laVietTat].
/// 2. **Âm tiết tiếng Việt → 1.** Nhận diện bằng cấu trúc âm tiết (phụ âm đầu +
///    vần + phụ âm cuối), không bằng danh sách từ. Nhờ thế `can`, `ban`, `sang`,
///    `tin`, `do` — những từ không dấu mà sea-g2p vẫn đọc theo tiếng Việt
///    (`kˈaːn`, `bˈaːn`, `sˈaːŋ`) — được tính đúng 1 âm, còn `code`, `phone`,
///    `time` thì không lọt vào vì `de`, `ne`, `me` không phải phụ âm cuối tiếng
///    Việt.
/// 3. **Còn lại → đếm nhóm nguyên âm** theo lối quen thuộc của tiếng Anh, kèm
///    mấy luật chữa cháy cho `-e` câm, `-ed`, `-es` và vài chỗ hai nguyên âm
///    liền nhau lại tách thành hai âm.
///
/// ## Sai số còn lại, và vì sao chấp nhận được
///
/// Đường 3 là phép đoán: đúng 91/102 từ đo được, phần sai lệch ±1 âm ở những từ
/// dài bất quy tắc — `chocolate` đoán 3 thật ra 2, `business` đoán 3 thật ra 2,
/// `create` đoán 1 thật ra 2 (`Hermione` lệch 2). Đường 1 thủng ở từ viết tắt
/// đã nằm trong từ điển: `NASA` đánh vần thành 4 mà g2p đọc liền `nˈæsɐ` chỉ 2
/// âm. Đổi lại, chúng chỉ lệch **một** âm mỗi từ thay vì lệch
/// bằng cả số âm tiết của từ như trước, và lệch cả hai chiều nên bù trừ nhau
/// trong một đoạn dài. Dải chấp nhận của `kiem_am.dart` vốn đã rộng ±15% chính
/// là để nuốt đúng loại sai số này.
///
/// Đừng đổi phép đoán thành bảng tra tay: bảng nào cũng thủng ở tên riêng, mà
/// tên riêng mới là thứ dày đặc trong sách dịch.
library;

import 'vi_number.dart';

/// Số âm tiết mà văn bản đã chuẩn hoá [speech] sẽ đọc ra.
int demAmChu(String speech) {
  // Thẻ tiếng Anh là chỉ dẫn cho g2p, không phải chữ để đọc — bỏ trước khi đếm,
  // không thì `<en>iPhone</en>` trông như một từ dính liền chẳng ra tiếng gì.
  final chu = speech.replaceAll(_theEn, ' ');

  // Cả đoạn viết hoa thì không có tương phản để nhận ra từ viết tắt — sea-g2p
  // cũng đọc bình thường chứ không đánh vần. Xem `bangChuHoaTenRieng` trong
  // `chunker.dart`.
  //
  // So bằng toUpperCase chứ ĐỪNG dùng dải `[a-zà-ỹ]`: dải ấy tính theo mã ký
  // tự nên nuốt luôn cả chữ HOA có dấu nằm giữa (`Ă` là U+0102, lọt vào giữa
  // `à` và `ỹ`), thành ra "NGĂN CẢN" bị coi là có chữ thường.
  final coTuongPhan = chu.toUpperCase() != chu;

  var so = 0;
  for (final tu in chu.split(_khoangTrang)) {
    if (!_coChu.hasMatch(tu)) continue; // dấu câu đứng riêng, không đọc thành âm
    so += _amCuaTu(tu, coTuongPhan);
  }
  return so;
}

final _theEn = RegExp(r'</?en>');
final _khoangTrang = RegExp(r'\s+');
final _coChu = RegExp(r'[A-Za-zÀ-ỹ0-9]');
final _chuoiSo = RegExp(r'\d+');

/// Chỗ nối trong từ ghép: mỗi mảnh đọc riêng nên đếm riêng ("Jong-un", "e-mail").
final _gachNoi = RegExp(r'[-–—/_]+');

/// Bỏ hẳn khỏi từ chứ không tách: dấu lược không tạo ra âm mới ("don't", "O'Brien").
final _dauLuoc = RegExp(r"['’`]");

int _amCuaTu(String tu, bool coTuongPhan) {
  final so = _chuoiSo.allMatches(tu).toList();
  if (so.isEmpty) return _amMotManh(tu, coTuongPhan);

  // Người dùng có thể tắt phần đổi số thành chữ (xem `text_normalizer.dart`),
  // lúc ấy "1975" vẫn là một từ nhưng đọc ra bảy âm — không tính đúng chỗ này
  // thì mọi đoạn có số đều bị kết tội oan.
  var tong = 0;
  for (final m in so) {
    tong += readInteger(m[0]!).split(_khoangTrang).length;
  }
  // Phần chữ còn lại quanh các chữ số ("3km" -> "ba" + "km").
  for (final phan in tu.replaceAll(_chuoiSo, ' ').split(_khoangTrang)) {
    if (_coChu.hasMatch(phan)) tong += _amMotManh(phan, coTuongPhan);
  }
  return tong;
}

/// Một mảnh chữ không lẫn chữ số.
int _amMotManh(String tu, bool coTuongPhan) {
  final manh = tu.split(_gachNoi).where((m) => _coChu.hasMatch(m)).toList();
  if (manh.length > 1) {
    return manh.fold(0, (t, m) => t + _amMotManh(m, coTuongPhan));
  }

  final chu = (manh.isEmpty ? tu : manh.first).replaceAll(_dauLuoc, '');
  final sach = chu.replaceAll(_khongPhaiChu, '');
  if (sach.isEmpty) return 0;

  if (_laVietTat(sach, coTuongPhan)) return _amDanhVan(sach);
  if (laAmTietViet(sach)) return 1;
  return demAmTiengAnh(sach);
}

final _khongPhaiChu = RegExp(r'[^A-Za-zÀ-ỹ]');

/// Từ này sẽ bị sea-g2p đánh vần từng chữ cái hay không.
///
/// Ba điều kiện, đo thẳng trên g2p bằng khung câu `ngôi nhà … đó`:
///
/// | Từ | Âm vị | |
/// |---|---|---|
/// | `USB` | `jˈuː ˈɛs bˈiː` | đánh vần |
/// | `ANH` | `ˈeɪ ˈɛn ˈeɪtʃ` | đánh vần — **cả từ tiếng Việt viết hoa cũng vậy** |
/// | `CHUONG` | sáu chữ cái | đánh vần |
/// | `MỘT` | `mˈo6t̪` | đọc như thường, vì có dấu tiếng Việt |
/// | `NGÔI NHÀ RIDDLE.` | bốn nhân âm | đọc như thường, cả câu hoa nên không có tương phản |
///
/// Nghĩa là **dấu tiếng Việt** mới là thứ cứu một từ khỏi bị đánh vần, chứ
/// không phải nó có phải tiếng Việt hay không — nên phép thử này phải chạy
/// TRƯỚC [laAmTietViet]. Trước đây làm ngược lại nên `AI`, `EM`, `BA` bị tính
/// một âm trong khi mô hình đọc thành hai.
///
/// Ngoại lệ duy nhất đo được là những từ viết tắt đã nằm sẵn trong từ điển:
/// `NASA → nˈæsɐ` đọc liền hai âm mà ở đây đếm thành bốn. Chấp nhận, vì đoán
/// ngược lại thì sai với cả nghìn từ viết tắt khác.
bool _laVietTat(String tu, bool coTuongPhan) {
  if (!coTuongPhan || tu.length < 2 || tu != tu.toUpperCase()) return false;
  // Có dấu tiếng Việt (chữ nào đó ngoài a–z sau khi hạ chữ) thì g2p đọc như
  // một từ chứ không đánh vần.
  return !_ngoaiAZ.hasMatch(tu.toLowerCase());
}

final _ngoaiAZ = RegExp(r'[^a-z]');

/// Số âm khi đánh vần từng chữ cái.
///
/// Chữ cái đọc một âm ("bê", "xê", "ca"), riêng `W` đọc "đáp-bờ-liu" ba âm —
/// đo được `WWW → dˌʌbəljˌuːdˌʌbəljˌuːdˈʌbəljˌuː`, chín nhân âm cho ba chữ cái.
int _amDanhVan(String tu) {
  var so = 0;
  for (final c in tu.split('')) {
    so += c == 'W' ? 3 : 1;
  }
  return so < 1 ? 1 : so;
}

// -- nhận diện âm tiết tiếng Việt --------------------------------------------

/// Chữ này có phải một âm tiết tiếng Việt hợp lệ không.
///
/// Dựng lại đúng cấu trúc âm tiết: **phụ âm đầu + vần + phụ âm cuối**, trong đó
/// vần là **âm đệm (o/u) + nguyên âm chính + âm cuối bán nguyên (i/y/u/o)**.
/// Sinh ra thay vì tra bảng, nên phủ hết cả những vần hiếm (`khuỷu`, `uyên`,
/// `xoong`, `ươu`) mà bảng viết tay hay sót.
///
/// Chặt tay là cố ý. Nhầm một từ tiếng Anh thành tiếng Việt thì đếm hụt đúng
/// bằng số âm tiết của nó — sai lớn; còn nhầm ngược lại thì phép đoán tiếng Anh
/// vẫn trả về 1 cho gần hết các từ một âm, nên gần như vô hại.
bool laAmTietViet(String tu) {
  final chu = _boDau(tu.toLowerCase());
  if (chu.isEmpty || !_chiChuViet.hasMatch(chu)) return false;

  for (final dau in _phuAmDau) {
    if (!chu.startsWith(dau)) continue;
    final con = chu.substring(dau.length);
    for (final cuoi in _phuAmCuoi) {
      if (!con.endsWith(cuoi) || con.length <= cuoi.length) continue;
      if (_laVan(con.substring(0, con.length - cuoi.length))) return true;
    }
  }
  return false;
}

/// Vần: âm đệm + nguyên âm chính + bán nguyên âm cuối.
bool _laVan(String van) {
  for (final dem in _amDem) {
    if (!van.startsWith(dem)) continue;
    final con = van.substring(dem.length);
    for (final chinh in _nguyenAmChinh) {
      if (!con.startsWith(chinh)) continue;
      final duoi = con.substring(chinh.length);
      if (duoi.isEmpty) return true;
      if (duoi.length == 1 && _banNguyenAm.contains(duoi)) return true;
    }
  }
  return false;
}

/// Xếp dài trước ngắn: `ngh` phải thử trước `ng`, không thì `nghe` gãy ở `ng`
/// rồi bỏ lại `he` không phải vần nào cả.
const _phuAmDau = [
  'ngh', 'ng', 'nh', 'ch', 'gh', 'gi', 'kh', 'ph', 'th', 'tr', 'qu', //
  'b', 'c', 'd', 'đ', 'g', 'h', 'k', 'l', 'm', 'n', 'p', 'r', 's', 't', 'v', 'x',
  '', // âm tiết mở đầu bằng nguyên âm: "ai", "uống", "êm"
];

const _phuAmCuoi = ['ngh', 'ng', 'nh', 'ch', 'c', 'm', 'n', 'p', 't', ''];

/// Âm đệm — chỉ `o` và `u` ("hoa", "tuấn"), hoặc không có.
const _amDem = ['o', 'u', ''];

/// Nguyên âm chính, nguyên âm đôi xếp trước để không bị nguyên âm đơn ăn mất
/// nửa đầu.
const _nguyenAmChinh = [
  'iê', 'yê', 'ia', 'ya', 'uô', 'ua', 'ươ', 'ưa', //
  'a', 'ă', 'â', 'e', 'ê', 'i', 'o', 'ô', 'ơ', 'u', 'ư', 'y',
];

const _banNguyenAm = ['i', 'y', 'u', 'o'];

/// Chỉ gồm chữ cái tiếng Việt — `f`, `j`, `w`, `z` là dấu hiệu chắc chắn không
/// phải tiếng Việt, chặn sớm cho rẻ.
final _chiChuViet = RegExp(r'^[a-eghiklm-vxyăâêôơưđ]+$');

/// Bỏ dấu thanh nhưng GIỮ dấu chữ: `ắ` về `ă` chứ không về `a`, vì `ă` và `a`
/// là hai nguyên âm khác nhau và vần hợp lệ của chúng cũng khác nhau.
String _boDau(String s) {
  final b = StringBuffer();
  for (final c in s.split('')) {
    b.write(_bangBoDau[c] ?? c);
  }
  return b.toString();
}

final Map<String, String> _bangBoDau = {
  for (final e in const {
    'a': 'àáảãạ',
    'ă': 'ằắẳẵặ',
    'â': 'ầấẩẫậ',
    'e': 'èéẻẽẹ',
    'ê': 'ềếểễệ',
    'i': 'ìíỉĩị',
    'o': 'òóỏõọ',
    'ô': 'ồốổỗộ',
    'ơ': 'ờớởỡợ',
    'u': 'ùúủũụ',
    'ư': 'ừứửữự',
    'y': 'ỳýỷỹỵ',
  }.entries)
    for (final c in e.value.split('')) c: e.key,
};

// -- đoán số âm tiết của một từ tiếng Anh ------------------------------------

/// Số âm tiết của một từ tiếng Anh, đoán theo nhóm nguyên âm.
///
/// Bốn luật chữa cháy, mỗi luật vá đúng một lỗi đo được:
///
/// | Luật | Ví dụ | Không có luật | Có luật |
/// |---|---|---|---|
/// | `-e` câm | `code`, `change` | 2 | 1 |
/// | trừ khi là `-le` | `table`, `little` | 1 | 2 |
/// | `-ed` sau phụ âm không phải `t`/`d` | `walked`, `passed` | 2 | 1 |
/// | `-es` sau âm không xuýt | `codes`, `names` | 2 | 1 |
/// | hai nguyên âm cuối tách đôi | `radio`, `media` | 2 | 3 |
int demAmTiengAnh(String tu) {
  // Bỏ dấu chứ không vứt chữ mang dấu: "Pokémon" mà rụng mất `é` thì còn
  // "pokmon", hụt hẳn một nhóm nguyên âm.
  final w = _boDau(tu.toLowerCase()).replaceAll(_khongPhaiAZ, '');
  if (w.isEmpty) return 1;

  var so = 0;
  var truocLaNguyenAm = false;
  for (final c in w.split('')) {
    final la = _nguyenAmAnh.contains(c);
    if (la && !truocLaNguyenAm) so++;
    truocLaNguyenAm = la;
  }
  if (so == 0) return 1; // "km", "tp" — đọc thế nào cũng ít nhất một âm

  final n = w.length;
  // `e` cuối đứng riêng một nhóm (chữ trước nó là phụ âm) thì gần như luôn câm.
  final eCam = n >= 2 && w.endsWith('e') && !_nguyenAmAnh.contains(w[n - 2]);
  if (eCam && so > 1) {
    // Trừ `-le` sau phụ âm: đó lại là một âm thật ("ta-ble", "lit-tle"). Sau
    // nguyên âm thì không ("while", "smile").
    final leThat = n >= 3 && w[n - 2] == 'l' && !_nguyenAmAnh.contains(w[n - 3]);
    if (!leThat) so--;
  }

  // `-ed` chỉ thành âm riêng sau `t` hoặc `d` ("want-ed", "need-ed"); còn lại
  // dính vào âm trước ("walked", "passed").
  if (so > 1 && n >= 3 && w.endsWith('ed') && !_nguyenAmAnh.contains(w[n - 3])) {
    if (w[n - 3] != 't' && w[n - 3] != 'd') so--;
  }

  // `-es` cũng vậy, trừ sau âm xuýt ("box-es", "watch-es", "pla-ces", "pa-ges"
  // — `c` và `g` đứng trước `e` luôn đọc mềm thành /s/, /dʒ/).
  if (so > 1 && n >= 3 && w.endsWith('es') && !_nguyenAmAnh.contains(w[n - 3])) {
    if (!_amXuyt.contains(w[n - 3]) && !(n >= 4 && _amXuyt2.contains(w.substring(n - 4, n - 2)))) {
      so--;
    }
  }

  // Đuôi `ia`/`io`/`eo`/`yo` là hai âm chứ không phải một nguyên âm đôi
  // ("ra-di-o", "me-di-a", "To-ky-o"). Trừ sau `t`/`s`/`c`/`x`, vì đó là
  // `-tion`, `-sia`, `-cious` — vẫn một âm ("Asia", "Russia").
  if (n >= 3 && _duoiTachDoi.contains(w.substring(n - 2)) && !_truocDuoiLien.contains(w[n - 3])) {
    so++;
  }
  return so;
}

final _khongPhaiAZ = RegExp(r'[^a-z]');
const _nguyenAmAnh = 'aeiouy';
const _amXuyt = 'szxcg';
const _amXuyt2 = ['ch', 'sh'];
const _duoiTachDoi = ['ia', 'io', 'eo', 'yo'];
const _truocDuoiLien = 'tscx';
