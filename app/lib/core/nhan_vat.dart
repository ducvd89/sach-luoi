/// Tìm nhân vật trong sách và đoán ai nói câu thoại nào, giới tính từng người.
///
/// Laya là bộ phân loại CHỌN trong các lựa chọn cho sẵn chứ không tự nghĩ ra tên, nên việc có
/// hai bước: (1) dựng danh sách ứng viên bằng luật, (2) hỏi Laya chọn người nói cho từng câu
/// thoại. Đây là bản Dart của `thu-nghiem/laya/demo_nhieu_giong/danh_dau_tu_dong.py` bên repo
/// huấn luyện; số đo ở đó (HP chương 5, chương chưa từng đưa vào train): 84/90 câu đúng, hoàn
/// toàn tự động từ đầu đến cuối.
///
/// Những điều đã đo và đáng giữ:
///  - Đưa cho Laya **toàn bộ** nhân vật của chương (10 người) hay chỉ những tên đứng gần câu
///    thoại cộng 3 người nói nhiều nhất (~6 người) đều ra 84/90. Sách dài có hàng chục nhân vật
///    mà mô hình chỉ được luyện với ≤15 lựa chọn, nên dùng bản cửa sổ.
///  - Laya sai chủ yếu ở những câu nó không chắc: trong các lần đo, câu độ tin cậy ≥0,9 gần như
///    không sai. Dưới [nguongTinCay] thì để người dẫn đọc thay vì đoán sai giọng một nhân vật.
///  - Giới tính nhân vật nữ là điểm yếu: ~một nửa nhân vật nữ bị đoán nam (đo trên ba cuốn,
///    ngay cả bỏ phiếu nhiều đoạn cũng không sửa được). Chức danh Bà/Cô/Ông/Chú ghi đè kết
///    quả, và giao diện PHẢI cho người dùng sửa tay.
library;

import 'dart:math';

import '../models/book.dart';

/// Trần độ dài đoạn trích đưa cho Laya (ký tự). Trạng thái được cắt Ở ĐUÔI khi quá dài, mà câu thoại
/// cần xác định nằm SAU đoạn văn trong chuỗi — một đoạn kể dài trong cửa sổ là đủ để câu thoại bị
/// cắt mất mà Laya vẫn trả lời (với một đáp án chẳng dựa vào câu nào) và nhãn sai được lưu.
const toiDaKyTuDoanTrich = 900;

/// Đoạn trích quanh câu thoại thứ [i]: 3 đoạn văn trước, câu thoại, 1 đoạn sau — nhưng không quá
/// [toiDaKyTuDoanTrich]. Quá dài thì bỏ dần từ phía XA câu thoại nhất (đầu cửa sổ, rồi đoạn sau),
/// cuối cùng cắt đầu của đoạn dẫn ngay trước; câu thoại luôn còn nguyên.
String doanTrichQuanhThoai(List<String> ds, int i) {
  var truoc = ds.sublist(max(0, i - 3), i);
  var sau = i + 1 < ds.length ? <String>[ds[i + 1]] : <String>[];
  int dai() => truoc.fold(0, (a, d) => a + d.length + 1) + ds[i].length + sau.fold(0, (a, d) => a + d.length + 1);
  while (dai() > toiDaKyTuDoanTrich && truoc.length > 1) {
    truoc = truoc.sublist(1);
  }
  if (dai() > toiDaKyTuDoanTrich) sau = [];
  if (dai() > toiDaKyTuDoanTrich && truoc.isNotEmpty) {
    final con = max(0, toiDaKyTuDoanTrich - ds[i].length - 1);
    final dan = truoc.last;
    truoc = [dan.length > con ? dan.substring(dan.length - con) : dan];
  }
  return [...truoc, ds[i], ...sau].join('\n');
}

/// Hướng dẫn hỏi người nói — đúng chữ lúc huấn luyện, đổi một chữ là Laya trả lời khác.
const huongDanNguoiNoi = 'Which character speaks the `quote` in the `passage`?';

/// Dưới mức này thì bỏ phiếu trắng (người dẫn đọc) thay vì gán cho một nhân vật.
const nguongTinCay = 0.5;

/// Số lựa chọn tối đa đưa cho Laya cho một câu thoại (mô hình được luyện với ≤15).
const toiDaUngVien = 14;

/// Tên phải được nhắc làm chủ ngữ ở dòng dẫn thoại ít nhất chừng này lần mới tính là nhân vật.
const toiThieuLanDan = 2;

class NhanVat {
  NhanVat({required this.ten, required this.gioi, required this.soCau, this.giong = ''});

  final String ten;

  /// 'nam' hoặc 'nu'. Người dùng sửa được.
  String gioi;

  /// Số câu thoại Laya đã gán cho người này, tính trên các chương đã phân tích.
  int soCau;

  /// Mã giọng người dùng đã chọn; rỗng là chưa chọn (dùng giọng mặc định).
  String giong;

  Map<String, dynamic> toJson() => {'ten': ten, 'gioi': gioi, 'soCau': soCau, if (giong.isNotEmpty) 'giong': giong};

  factory NhanVat.fromJson(Map<String, dynamic> j) => NhanVat(
        ten: j['ten'] as String,
        gioi: j['gioi'] as String? ?? 'nam',
        soCau: (j['soCau'] as num?)?.toInt() ?? 0,
        giong: j['giong'] as String? ?? '',
      );
}

/// Kết quả phân tích một cuốn sách.
class KetQuaNhanVat {
  KetQuaNhanVat(this.nhanVat, this.nguoiNoi);

  final List<NhanVat> nhanVat;

  /// Khoá "chương:đoạn văn:câu thoại" -> tên người nói. Câu thoại không có trong bảng là người
  /// dẫn. `câu thoại` là chỉ số trong [cacCauThoai] của đoạn văn ấy.
  ///
  /// Bản 2.1.0 khoá theo "chương:đoạn văn" (cả đoạn văn một người); khoá cũ vẫn đọc được qua
  /// [nguoiCua] — nó áp cho mọi câu thoại của đoạn văn ấy.
  final Map<String, String> nguoiNoi;

  static String khoa(int chuong, int doanVan, int cau) => '$chuong:$doanVan:$cau';

  String nguoiCua(int chuong, int doanVan, int cau) => traNguoiNoi(nguoiNoi, chuong, doanVan, cau);

  Map<String, dynamic> toJson() => {
        'nhanVat': [for (final n in nhanVat) n.toJson()],
        'nguoiNoi': nguoiNoi,
      };

  factory KetQuaNhanVat.fromJson(Map<String, dynamic> j) => KetQuaNhanVat(
        [for (final n in (j['nhanVat'] as List? ?? const [])) NhanVat.fromJson(n as Map<String, dynamic>)],
        {for (final e in (j['nguoiNoi'] as Map? ?? const {}).entries) e.key as String: e.value as String},
      );
}

/// Dữ liệu nhân vật của MỘT cuốn sách, lưu cạnh sách (`nhanvat.json`).
///
/// Là DANH BẠ của cả cuốn, được bồi dần từng chương: phân tích cả cuốn một lượt mất quá lâu (mỗi
/// câu thoại ~0,1 giây, sách dày có hàng nghìn câu), nên người dùng phân tích chương đang nghe là
/// đủ. Nhân vật đã biết giữ nguyên giọng và giới tính khi gặp lại ở chương khác — đó là lý do mọi
/// thứ gắn theo TÊN ở đây chứ không theo chương.
class NhanVatSach {
  NhanVatSach({
    this.bat = false,
    this.donRac,
    List<NhanVat>? nhanVat,
    Map<String, String>? nguoiNoi,
    Set<int>? chuongDaPhanTich,
  })  : nhanVat = nhanVat ?? [],
        nguoiNoi = nguoiNoi ?? {},
        chuongDaPhanTich = chuongDaPhanTich ?? {};

  /// Các chương đã phân tích. Chương chưa có trong đây đọc bằng giọng người dẫn (cắt như thường)
  /// cho tới khi người dùng phân tích nó.
  final Set<int> chuongDaPhanTich;

  bool daPhanTich(int chuong) => chuongDaPhanTich.contains(chuong);

  /// Gộp kết quả phân tích của các chương [chuong] vào danh bạ.
  ///
  ///  - Phân tích lại một chương thì nhãn cũ của chương ấy bị THAY, không cộng dồn.
  ///  - Nhân vật đã có giữ nguyên giọng và giới tính (kể cả khi người dùng đã sửa tay); chỉ nhân
  ///    vật mới được thêm vào.
  ///  - Số câu thoại tính lại từ bảng người nói, không cộng dồn (cộng dồn sẽ đếm đôi khi phân
  ///    tích lại).
  void hopNhatChuong(KetQuaNhanVat kq, Set<int> chuong) {
    nguoiNoi.removeWhere((khoa, _) => chuong.contains(int.tryParse(khoa.split(':').first)));
    nguoiNoi.addAll(kq.nguoiNoi);
    for (final moi in kq.nhanVat) {
      if (tim(moi.ten) == null) nhanVat.add(NhanVat(ten: moi.ten, gioi: moi.gioi, soCau: 0));
    }
    chuongDaPhanTich.addAll(chuong);
    tinhLaiSoCau();
  }

  /// Đếm lại số câu của từng người từ bảng người nói; người không còn câu nào và chưa được chọn
  /// giọng thì bỏ khỏi danh bạ (chỉ còn là nhiễu), người đã có giọng thì giữ để khỏi mất lựa chọn.
  void tinhLaiSoCau() {
    final dem = <String, int>{};
    for (final ten in nguoiNoi.values) {
      dem[ten] = (dem[ten] ?? 0) + 1;
    }
    for (final n in nhanVat) {
      n.soCau = dem[n.ten] ?? 0;
    }
    nhanVat.removeWhere((n) => n.soCau == 0 && n.giong.isEmpty);
    nhanVat.sort((a, b) => b.soCau.compareTo(a.soCau));
  }

  /// Tên các nhân vật xuất hiện (có câu thoại) trong [chuong].
  Set<String> trongChuong(int chuong) => {
        for (final e in nguoiNoi.entries)
          if (e.key.startsWith('$chuong:')) e.value,
      };

  /// Đang đọc nhiều giọng. Tắt thì MỌI đoạn đọc bằng giọng người dẫn; bật thì đoạn lời nói đọc bằng
  /// giọng người nói của nó. Bật/tắt KHÔNG cắt lại sách: mỗi lời nói đã là một đoạn riêng từ lúc nhập.
  bool bat;

  /// Cài đặt "bỏ quảng cáo và mục lục" lúc phân tích. Nhãn người nói gắn theo (chương, đoạn
  /// văn) và bước dọn rác đổi số chương/đoạn, nên cắt lại sách phải dùng ĐÚNG cài đặt này —
  /// người dùng đổi cài đặt rồi bấm "dựng lại" mà nhãn lệch chỗ thì giọng sẽ gán nhầm người.
  final bool? donRac;

  final List<NhanVat> nhanVat;

  /// Khoá "chương:đoạn văn" -> tên người nói, dùng để cắt lại sách theo người nói.
  final Map<String, String> nguoiNoi;

  NhanVat? tim(String ten) {
    for (final n in nhanVat) {
      if (n.ten == ten) return n;
    }
    return null;
  }

  /// Mã giọng đã chọn cho người nói [ten]; rỗng khi là người dẫn hay chưa chọn giọng.
  String giongCua(String ten) => ten.isEmpty ? '' : (tim(ten)?.giong ?? '');

  Map<String, dynamic> toJson() => {
        'phienBan': 2,
        'bat': bat,
        if (donRac != null) 'donRac': donRac,
        'chuong': chuongDaPhanTich.toList()..sort(),
        'nhanVat': [for (final n in nhanVat) n.toJson()],
        'nguoiNoi': nguoiNoi,
      };

  factory NhanVatSach.fromJson(Map<String, dynamic> j) {
    final kq = KetQuaNhanVat.fromJson(j);
    // Bản 1 phân tích cả cuốn: không có danh sách chương, mà mọi chương có nhãn đều đã xong.
    // Khoá hỏng ("abc:1") bị bỏ qua chứ không ném lỗi: file nhanvat.json bị sửa tay hay hỏng một
    // dòng không được làm cả cuốn sách không mở được (nó được đọc ngay trong openBook).
    final chuong = j['chuong'] is List
        ? {for (final c in j['chuong'] as List) if (c is num) c.toInt()}
        : {
            for (final k in kq.nguoiNoi.keys)
              if (int.tryParse(k.split(':').first) != null) int.parse(k.split(':').first),
          };
    return NhanVatSach(
      bat: j['bat'] as bool? ?? false,
      donRac: j['donRac'] as bool?,
      nhanVat: kq.nhanVat,
      nguoiNoi: kq.nguoiNoi,
      chuongDaPhanTich: chuong,
    );
  }
}

/// Cổng tới Laya. Bản thật gọi thư viện native (`laya_native.dart`); kiểm thử dùng bản giả.
abstract class LayaKhach {
  /// Xác suất của từng lựa chọn, cộng lại bằng 1, theo đúng thứ tự [luaChon] (nhãn, mô tả).
  /// [thoai] null là câu hỏi không có "quote" (đoán giới tính).
  Future<List<double>> chon(
    String huongDan,
    String doan,
    String? thoai,
    List<(String, String)> luaChon,
  );
}

final _chuThuong = RegExp(r'\p{Ll}+', unicode: true);

/// Chức danh đứng trước tên. Giữ nguyên chữ (không viết hoa) vì có sách viết "bà Weasley".
const _dsChucDanh = '(?:bà|ông|cô|chú|lão|thầy|cụ|bác|giáo sư)';
final _chucDanhGiua = RegExp('(?<![\\p{L}])($_dsChucDanh)\\s+(\\p{Lu}\\p{Ll}+)', caseSensitive: false, unicode: true);

/// Tên nhiều âm tiết kiểu truyện dịch: viết hoa nối bằng gạch ("Dương-Qua", "Lý-mạc-Thu") hoặc bằng
/// cách ("Trình Anh", "Vi Tiểu Bảo", tối đa 4 âm tiết). Âm tiết của tên Hán-Việt cũng là từ thường
/// (trình, dương, quá, tỉnh), nên KHÔNG thể dùng luật "chưa từng viết thường" cho những tên này —
/// luật ấy chỉ đúng với tên phương Tây một âm tiết (Fred, Harry). Đã đo trên Thần Điêu Đại Hiệp:
/// luật cũ chỉ ra `Khưu`, `Doãn` và vài mảnh lỗi OCR, bỏ sót Lục Vô Song, Trình Anh, Dương-Qua.
// `(?!-)`: "Rồi Tỉnh-Quang" không được cắt thành "Rồi Tỉnh" + "-Quang" — âm tiết đứng ngay trước một
// gạch nối thuộc về cụm nối gạch, và cụm ấy tự nhận ở vị trí kế.
final _tenNhieuAm = RegExp(r'\p{Lu}\p{Ll}+(?:-\p{L}+)+|\p{Lu}\p{Ll}+(?: \p{Lu}\p{Ll}+(?!-)){1,3}', unicode: true);

/// Từ mở câu hay viết hoa ở đầu dòng dẫn và có thể dính vào tên ("Rồi Lục Vô Song nhảy dựng"). Cố ý
/// là DANH SÁCH CỐ ĐỊNH chứ không phải "từ có dạng viết thường trong sách": âm tiết của tên Hán-Việt
/// (Trình, Lý, Dương) cũng có dạng viết thường, bóc theo luật ấy sẽ cắt mất đầu tên "Trình Anh".
const _tuMoCau = {
  'rồi', 'thế', 'lúc', 'khi', 'nhưng', 'và', 'còn', 'đoạn', 'sau', 'trước', 'bỗng', 'chợt', 'bấy', 'giờ',
  'đột', 'nhiên', 'tức', 'thì', 'cả', 'mọi', 'hai', 'ba', 'bốn', 'năm', 'một', 'những', 'các', 'này',
  'ấy', 'nọ', 'kia', 'đó', 'vậy', 'nên', 'vì', 'nếu', 'dù', 'tuy', 'trong', 'ngoài', 'giữa', 'bên',
};
final _tenMotAm = RegExp(r'\p{Lu}\p{Ll}+', unicode: true);

const _dongTuNoi = '(?:nói|hỏi|đáp|kêu|la|gắt|quát|thì thầm|thưa|trả lời|reo|cười|lầm bầm|'
    'càu nhàu|thở dài|ngạc nhiên|cãi|thét|rên|rít|bảo|gọi|nạt|lên tiếng)';
// `(?![\p{L}])` sau động từ: không chặn thì "la" khớp trong "lau", "lang" — "Harry lau mồ hôi"
// sau câu thoại bị tính là Harry nói.
final _dongTuDauDong = RegExp('^\\s*\\p{Lu}.{0,80}?$_dongTuNoi(?![\\p{L}])', unicode: true);
final _tuNoiSauThoai = RegExp('[”"»]\\s*,?\\s*(.+?)\\s+$_dongTuNoi(?![\\p{L}])', unicode: true);

/// Đoạn văn mở đầu bằng dấu mở thoại: “ " « hoặc gạch đầu dòng kiểu truyện dịch cũ ("- Xin sư phụ"
/// và cả "-Kìa" dính liền, hay gặp ở bản scan). Gạch dính liền SỐ ("-5 độ") thì không phải thoại.
bool laDoanThoai(String doan) {
  final d = doan.trimLeft();
  if (d.isEmpty) return false;
  if ('“"«'.contains(d[0])) return true;
  return RegExp(r'^[—–-]\s*[\p{L}“"«]', unicode: true).hasMatch(d);
}

/// Một câu thoại trong đoạn văn: [dau]–[cuoi] là cả mẩu thuộc người nói (gồm dấu ngoặc và dấu câu
/// dính liền phía sau, như `”.` hay `”,`), [noiDau]–[noiCuoi] là phần trong ngoặc. Vị trí tính bằng
/// đơn vị mã UTF-16 như mọi chỉ số chuỗi của Dart.
typedef CauThoai = ({int dau, int cuoi, int noiDau, int noiCuoi});

/// Ngoặc mở tới ngoặc đóng; thiếu ngoặc đóng `”`/`»` thì tới hết đoạn văn (lời thoại dài nhiều đoạn
/// văn chỉ đóng ngoặc ở đoạn cuối). Ngoặc thẳng `"` phải có cặp, vì không phân biệt mở với đóng.
final _mauTrich = RegExp(r'“[^”]*”?|«[^»]*»?|"[^"]*"');
final _dauSauTrich = RegExp(r'[.,;:!?…]+');
final _gachDauThoai = RegExp(r'^[—–-]\s*[\p{L}“"«]', unicode: true);

/// Các câu thoại trong đoạn văn [doan], theo thứ tự. Đoạn văn gạch đầu dòng ("- Xin sư phụ") là MỘT
/// câu thoại cả đoạn.
///
/// Bản 2.1.0 chỉ nhận đoạn văn MỞ ĐẦU bằng ngoặc kép là thoại, và gán cả đoạn cho một người. Sách
/// viết thoại lẫn trong đoạn kể thì gần như không có câu thoại nào: Lộc Đỉnh Ký hồi 1 có 246 câu
/// trong ngoặc ở 107 đoạn văn, mà chỉ 2 đoạn mở đầu bằng ngoặc — Laya được hỏi đúng 2 câu.
///
/// Chỉ số câu thoại ([KetQuaNhanVat.khoa]) là vị trí trong danh sách này, nên bộ cắt
/// ([buildChunks]) và việc phân tích PHẢI cùng gọi hàm này trên cùng đoạn văn.
List<CauThoai> cacCauThoai(String doan) {
  if (_gachDauThoai.hasMatch(doan.trimLeft())) {
    final dau = doan.length - doan.trimLeft().length;
    return [(dau: dau, cuoi: doan.length, noiDau: dau, noiCuoi: doan.length)];
  }
  final ra = <CauThoai>[];
  for (final m in _mauTrich.allMatches(doan)) {
    final dong = m.end > m.start + 1 && '”»"'.contains(doan[m.end - 1]) && !(doan[m.start] == '"' && m.end - m.start < 2);
    var cuoi = m.end;
    final duoi = _dauSauTrich.matchAsPrefix(doan, cuoi);
    if (duoi != null) cuoi = duoi.end;
    ra.add((dau: m.start, cuoi: cuoi, noiDau: m.start + 1, noiCuoi: dong ? m.end - 1 : m.end));
  }
  return ra;
}

final _hetCauTrong = RegExp(r'[.!?…]["”»]?$');

/// Câu thoại thứ [q] có phải LỜI NÓI không — để không hỏi Laya về tiếng động (“bình” một tiếng), tên
/// chiêu thức hay tên sách trong ngoặc. Là lời nói khi: đứng đầu đoạn văn, hoặc ngay sau dấu hai
/// chấm ("Vi Tiểu Bảo nói: “…”"), hoặc tự kết bằng dấu câu.
///
/// Đo trên 1.042 câu trong ngoặc của Lộc Đỉnh Ký hồi 8, 10, 11 (nhãn Opus): giữ 939/960 lời nói thật,
/// bỏ 38/82 câu không phải lời nói; số lọt qua phần lớn là lời của đám đông hay người vô danh, mà
/// với chúng Laya thường không đủ chắc nên vẫn về người dẫn.
bool laLoiNoi(String doan, List<CauThoai> cau, int q) {
  final c = cau[q];
  final truoc = doan.substring(0, c.dau).trimRight();
  if (truoc.isEmpty || truoc.endsWith(':')) return true;
  return _hetCauTrong.hasMatch(doan.substring(c.noiDau, c.noiCuoi).trim());
}

/// Người nói của câu thoại [cau] (đoạn văn [doanVan], chương [chuong]) trong bảng [bang]: khoá ba
/// phần, rồi khoá hai phần của bản 2.1.0 (cả đoạn văn một người).
String traNguoiNoi(Map<String, String> bang, int chuong, int doanVan, int cau) =>
    bang['$chuong:$doanVan:$cau'] ?? bang['$chuong:$doanVan'] ?? '';

/// Người nói đoạn [c] theo bảng nhãn [nhan] ("chương:đoạn văn:câu"); rỗng là người dẫn. Đoạn cắt bằng
/// bản 2.1.0 không có [Chunk.cau] mà ghi thẳng người nói vào [Chunk.speaker] — vẫn đọc được.
String nguoiNoiCuaDoan(Map<String, String> nhan, Chunk c) {
  if (c.cau.isEmpty) return c.speaker;
  final k = c.cau.indexOf(':');
  if (k < 0) return '';
  return traNguoiNoi(nhan, c.chapter, int.tryParse(c.cau.substring(0, k)) ?? -1,
      int.tryParse(c.cau.substring(k + 1)) ?? -1);
}

/// Đoạn văn [doan] cắt thành các mẩu cho bộ cắt đoạn: mỗi LỜI NÓI ([laLoiNoi]) một mẩu riêng mang
/// chỉ số câu thoại của nó, phần còn lại (lời dẫn, câu trong ngoặc không phải lời nói) là mẩu lời
/// dẫn (chỉ số -1). Đoạn văn không có lời nói nào thì trả nguyên đoạn văn, nên sách không có thoại
/// cắt y như trước từng ký tự.
///
/// Cắt như vậy NGAY TỪ LÚC NHẬP, bất kể có đọc nhiều giọng hay không: mỗi lời nói đã là một đoạn
/// riêng, nên phân tích nhân vật hay bật/tắt nhiều giọng chỉ đổi GIỌNG đọc từng đoạn, không cắt lại
/// sách (bản 2.1.0 cắt lại cả cuốn mỗi lần bật/tắt, số thứ tự đoạn đổi theo — chỗ đang nghe, cache
/// và việc xuất file dở đều lệch).
List<(String, int)> manhCauThoai(String doan) {
  final cau = cacCauThoai(doan);
  final ra = <(String, int)>[];
  var tu = 0;
  void them(int den, int q) {
    final s = doan.substring(tu, den).trim();
    if (s.isNotEmpty) ra.add((s, q));
    tu = den;
  }
  for (var q = 0; q < cau.length; q++) {
    if (!laLoiNoi(doan, cau, q)) continue;
    them(cau[q].dau, -1);
    them(cau[q].cuoi, q);
  }
  if (ra.isEmpty) return [(doan, -1)];
  them(doan.length, -1);
  return ra;
}

/// Các lời nói trong đoạn văn [d] (chỉ số câu thoại) — những câu Laya phải gán người nói.
List<int> _cauHoi(String d) {
  final cau = cacCauThoai(d);
  return [for (var q = 0; q < cau.length; q++) if (laLoiNoi(d, cau, q)) q];
}

/// Mệnh đề dẫn ngay trước câu thoại thứ [q]: phần sau dấu kết câu cuối cùng, từ hết câu thoại trước
/// (hay đầu đoạn) tới ngoặc mở. "…sơ hở. Vi Tiểu Bảo nói:" → "Vi Tiểu Bảo nói:".
String _menhDeDan(String doan, List<CauThoai> cau, int q) {
  final tu = q == 0 ? 0 : cau[q - 1].cuoi;
  final s = doan.substring(tu, cau[q].dau);
  final cuoiCau = RegExp(r'[.!?…”»"]+\s+').allMatches(s).lastOrNull;
  return (cuoiCau == null ? s : s.substring(cuoiCau.end)).trim();
}

/// Đoạn trích quanh câu thoại NẰM TRONG đoạn kể: chữ của cả chương, từ 450 ký tự trước ngoặc mở tới
/// 200 ký tự sau ngoặc đóng — đúng cách dựng dữ liệu luyện Laya cho Lộc Đỉnh Ký (`gop.py`), khác cách
/// cho Harry Potter (theo dòng) vì bên ấy mỗi câu thoại là một dòng.
String doanTrichQuanhCau(List<String> ds, int i, CauThoai c) {
  var dauDoan = 0;
  for (var k = 0; k < i; k++) {
    dauDoan += ds[k].length + 1;
  }
  final van = ds.join('\n');
  return van.substring(max(0, dauDoan + c.dau - 450), min(van.length, dauDoan + c.noiCuoi + 1 + 200));
}

String _vietHoaChucDanh(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

/// Khoá để gộp các dạng viết của cùng một tên: "Dương-Qua", "Dương Qua", "dương qua" là một.
/// Cùng một nhân vật hay đổi giữa gạch nối và dấu cách ngay trong một cuốn (Thần Điêu Đại Hiệp
/// viết "Lý-mạc-Thu" ở hồi này, "Lý Mạc Thu" ở hồi khác).
String khoaTen(String ten) => ten.toLowerCase().replaceAll('-', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Tên ĐẦU TIÊN trong [dong] (theo vị trí), hoặc null. Chức danh + tên ("bà Weasley"), tên nhiều âm
/// tiết, hoặc một từ viết hoa chưa từng viết thường ("Fred" có; "Nó", "Rồi" thì không vì sách có
/// "nó", "rồi").
///
/// Tên ĐẦU TIÊN chứ không phải tên cuối: trong "Trình Anh bấm nhẹ vào vai Lục Vô Song bảo:" người
/// nói là chủ ngữ đứng trước, người bị bấm vai đứng sau. Và không chỉ ở đầu dòng: bản scan hay
/// ngắt dòng giữa câu rồi nối lại, ra "Trong lúc mọi người đang chú ý thì Lục Vô Song nhảy dựng
/// … nói:" — chủ ngữ nằm giữa câu.
///
/// [dauDong] chỉ nhận tên ở đầu dòng (cho phép đứng sau MỘT từ đệm như "Rồi", "Thế"): dùng cho
/// dòng nằm SAU câu thoại, nơi tên ở giữa dòng thường là người bị nhắc tới chứ không phải người nói.
String? _tenDauTien(String dong, Set<String> tuThuong, {bool dauDong = false}) {
  final ung = <(int, String)>[];
  for (final m in _chucDanhGiua.allMatches(dong)) {
    if (!tuThuong.contains(m.group(2)!.toLowerCase())) {
      ung.add((m.start, '${_vietHoaChucDanh(m.group(1)!.toLowerCase())} ${m.group(2)}'));
    }
  }
  for (final m in _tenNhieuAm.allMatches(dong)) {
    var ten = m.group(0)!;
    var batDau = m.start;
    if (!ten.contains('-')) {
      var am = ten.split(' ');
      while (am.length > 1 && _tuMoCau.contains(am.first.toLowerCase())) {
        batDau += am.first.length + 1;
        am = am.sublist(1);
      }
      if (am.length < 2) continue; // còn một âm tiết: để nhánh một-âm-tiết xét
      ten = am.join(' ');
    }
    ung.add((batDau, ten));
  }
  for (final m in _tenMotAm.allMatches(dong)) {
    if (!tuThuong.contains(m.group(0)!.toLowerCase())) ung.add((m.start, m.group(0)!));
  }
  if (ung.isEmpty) return null;
  // Gần đầu dòng nhất; cùng vị trí thì lấy dạng DÀI hơn ("Lục Vô Song" thắng "Lục").
  ung.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : b.$2.length.compareTo(a.$2.length));
  if (!dauDong) return ung.first.$2;
  // `unicode: true` là BẮT BUỘC: thiếu nó thì `\p{Lu}` khớp nguyên văn chữ "p{Lu}", tuDem luôn
  // null và luật "một từ đệm trước tên" ("Rồi Lục Vô Song nói") chưa bao giờ chạy (2.1.0).
  final tuDem = RegExp(r'^\s*\p{Lu}\p{Ll}*\s', unicode: true).firstMatch(dong);
  final choPhep = tuDem == null ? 0 : tuDem.end;
  for (final u in ung) {
    if (u.$1 == 0 || (u.$1 <= choPhep && tuThuong.contains(tuDem!.group(0)!.trim().toLowerCase()))) return u.$2;
  }
  return null;
}

/// Danh sách ứng viên nhân vật theo thứ tự nhắc nhiều nhất, kèm số lần.
///
/// Chỉ nhận tên làm chủ ngữ ở dòng dẫn thoại (dòng ngay trước kết thúc bằng ":", dòng ngay sau
/// mở đầu bằng tên + động từ nói, hoặc đoạn thoại có "…”, Fred hỏi"). Địa danh, đồ vật viết hoa
/// không đứng ở những chỗ ấy nên tự bị loại. Các dạng viết khác nhau của một tên (gạch nối, dấu
/// cách, hoa/thường) gộp làm một, lấy dạng gặp nhiều nhất làm tên hiện.
List<(String, int)> timUngVien(List<List<String>> doanVanTheoChuong, {Set<int>? chuong}) {
  final tuThuong = <String>{};
  for (final chuong in doanVanTheoChuong) {
    for (final d in chuong) {
      for (final m in _chuThuong.allMatches(d)) {
        tuThuong.add(m.group(0)!);
      }
    }
  }
  final theoKhoa = <String, Map<String, int>>{}; // khoá -> (dạng viết -> số lần)
  final trongChuong = <String, int>{}; // khoá -> số lần ở các chương được yêu cầu
  var cDangXet = 0;
  void them(String? ten) {
    if (ten == null) return;
    final k = khoaTen(ten);
    final dang = theoKhoa.putIfAbsent(k, () => {});
    dang[ten] = (dang[ten] ?? 0) + 1;
    if (chuong != null && chuong.contains(cDangXet)) trongChuong[k] = (trongChuong[k] ?? 0) + 1;
  }

  for (var c = 0; c < doanVanTheoChuong.length; c++) {
    final ds = doanVanTheoChuong[c];
    cDangXet = c;
    for (var i = 0; i < ds.length; i++) {
      if (!laDoanThoai(ds[i])) {
        // Lời nói nằm TRONG đoạn kể ("Đứa nhỏ hỏi: “Cha…”. Văn sĩ nói: “…”"): người nói là chủ ngữ
        // của mệnh đề dẫn ngay trước ngoặc mở, hoặc đứng sau ngoặc đóng ("…”, Fred hỏi").
        final cau = cacCauThoai(ds[i]);
        for (var q = 0; q < cau.length; q++) {
          if (!laLoiNoi(ds[i], cau, q)) continue;
          final dan = _menhDeDan(ds[i], cau, q);
          if (dan.endsWith(':')) them(_tenDauTien(dan, tuThuong));
          final sau = ds[i].substring(cau[q].dau, q + 1 < cau.length ? cau[q + 1].dau : ds[i].length);
          final m = _tuNoiSauThoai.firstMatch(sau);
          if (m != null) them(_tenDauTien(m.group(1)!, tuThuong, dauDong: true));
        }
        continue;
      }
      if (i > 0 && ds[i - 1].trimRight().endsWith(':')) {
        them(_tenDauTien(ds[i - 1], tuThuong));
      }
      if (i + 1 < ds.length && _dongTuDauDong.hasMatch(ds[i + 1])) {
        them(_tenDauTien(ds[i + 1], tuThuong, dauDong: true));
      }
      final m = _tuNoiSauThoai.firstMatch(ds[i]);
      if (m != null) them(_tenDauTien(m.group(1)!, tuThuong, dauDong: true));
    }
  }
  final tong = <String, int>{
    for (final e in theoKhoa.entries) e.key: e.value.values.fold(0, (a, b) => a + b),
  };
  final nhieuNhat = tong.values.fold(0, max);
  // Dưới 1% của tên đứng đầu là nhiễu (mảnh vỡ do OCR, từ viết hoa lẻ) — chỉ có nghĩa với sách dày
  // vài chục chương; sách ngắn thì ngưỡng cố định.
  final nguong = max(toiThieuLanDan, (nhieuNhat * 0.01).ceil());
  // Ngoại lệ: tên đứng làm chủ ngữ dòng dẫn từ [toiThieuLanDan] lần trở lên ngay trong CHƯƠNG đang
  // phân tích thì nhận, dù cả cuốn hiếm khi nhắc. Nhân vật chỉ xuất hiện ở một hồi (Tỉnh-Quang ở
  // Thần Điêu Đại Hiệp hồi 11) luôn dưới 1% của Dương Qua mà lại là người nói chính của hồi ấy.
  // Mảnh vỡ OCR rải rác khắp sách nên hiếm khi tụ đủ hai lần trong một chương.
  var ds = [
    for (final e in tong.entries)
      if (e.value >= nguong || (trongChuong[e.key] ?? 0) >= toiThieuLanDan)
        (
          (theoKhoa[e.key]!.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key,
          e.value,
        ),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  // Họ trần ("Weasley") là họ của "Bà Weasley"/"Ông Weasley": bỏ nếu đã có dạng có chức danh.
  final ten = ds.map((e) => e.$1).toList();
  ds = ds.where((e) => e.$1.contains(' ') || !ten.any((t) => t != e.$1 && t.endsWith(' ${e.$1}'))).toList();
  return ds;
}

/// Mẫu tìm một tên trong văn bản: các âm tiết nối bằng gạch HOẶC cách (một nhân vật hay đổi giữa hai
/// kiểu viết). Tên nhiều âm tiết khớp không phân biệt hoa thường; tên một âm tiết thì có, vì "bảo",
/// "quá", "an" là từ thường mà "Bảo", "Quá", "An" mới là tên.
RegExp _mauTen(String ten) {
  final am = ten.split(RegExp(r'[- ]')).where((e) => e.isNotEmpty).map(RegExp.escape).join('[- ]');
  return RegExp('(?<![\\p{L}])$am(?![\\p{L}])', caseSensitive: !ten.contains(RegExp(r'[- ]')), unicode: true);
}

bool _coChucDanh(String ten) =>
    ten.contains(' ') && RegExp('^$_dsChucDanh\\s', caseSensitive: false, unicode: true).hasMatch(ten);

bool _coTen(String ten, String van) {
  if (_mauTen(ten).hasMatch(van)) return true;
  // "Bà Weasley" cũng hiện là "Weasley" trần ở nhiều chỗ.
  return _coChucDanh(ten) &&
      RegExp('(?<![\\p{L}])${RegExp.escape(ten.split(' ').last)}(?![\\p{L}])', unicode: true).hasMatch(van);
}

String _gioiTheoChucDanh(String ten) {
  final dau = ten.split(' ').first.toLowerCase();
  if (dau == 'bà' || dau == 'cô') return 'nu';
  if (const {'ông', 'chú', 'lão', 'thầy', 'cụ', 'bác'}.contains(dau) && ten.contains(' ')) return 'nam';
  return '';
}

/// Đoán giới tính một nhân vật bằng Laya: trung bình xác suất "nữ" trên tối đa [soMau] mẫu, mỗi
/// mẫu là hai đoạn trích quanh tên (đúng cách đã đo). Chức danh Bà/Cô/Ông/Chú... ghi đè.
///
/// Mặc định 4 mẫu (10 nếu nhân vật được nhắc từ 30 lần): đo trên ba cuốn thì bỏ phiếu 3 mẫu hay 20
/// mẫu cho cùng độ chính xác ở nhân vật ít xuất hiện (lỗi của Laya ở nhân vật nữ là lỗi hệ thống,
/// thêm mẫu không sửa được), mà mỗi mẫu tốn ~0,27 giây.
Future<String> doanGioiTinh(LayaKhach laya, String ten, String van, {int? soMau, Random? rd}) async {
  final theoChucDanh = _gioiTheoChucDanh(ten);
  if (theoChucDanh.isNotEmpty) return theoChucDanh;
  // Tên chức danh thì tìm cả họ trần ("Weasley" cho "Bà Weasley"); còn lại tìm đúng tên, nhận cả
  // gạch nối lẫn dấu cách giữa các âm tiết.
  final mau = _coChucDanh(ten)
      ? RegExp('(?<![\\p{L}])${RegExp.escape(ten.split(' ').last)}(?![\\p{L}])', unicode: true)
      : _mauTen(ten);
  final vi = <int>[for (final m in mau.allMatches(van)) m.start];
  if (vi.isEmpty) return 'nam';
  vi.shuffle(rd ?? Random(1));
  // Nhân vật nhắc nhiều thì lấy nhiều mẫu hơn: nó là người xuất hiện kề các nhân vật khác nên mỗi mẫu
  // nhiễu hơn (Dương Qua hay đứng cạnh "nàng"), và sai ở người nói nhiều câu nhất là lỗi đắt nhất.
  // Chỉ tốn một lần cho mỗi nhân vật vì giới tính được lưu vào danh bạ.
  soMau ??= vi.length >= 30 ? 10 : 4;
  final huongDan = 'Is the character $ten in `passage` male or female?';
  final lua = [('nam', 'male (nam giới)'), ('nữ', 'female (nữ giới)')];
  var tong = 0.0, dem = 0;
  for (var k = 0; k < min(vi.length, soMau * 2); k += 2) {
    final doan = [
      for (final p in vi.skip(k).take(2))
        van.substring(max(0, p - 160), min(van.length, p + 200)).replaceAll('\n', ' '),
    ].join(' […] ');
    final p = await laya.chon(huongDan, doan, null, lua);
    tong += p[1];
    dem++;
  }
  return dem > 0 && tong / dem > 0.5 ? 'nu' : 'nam';
}

/// Phân tích nhân vật: [doanVanTheoChuong] là kết quả `doanVanCuaChuong` của TẤT CẢ các chương.
///
/// [chuong] là các chương cần hỏi Laya (null là cả cuốn). Phần chậm là hỏi Laya từng câu thoại
/// (~0,1 giây mỗi câu), còn tìm ứng viên chạy trên chữ của cả cuốn thì gần như tức thì — nên danh
/// sách ứng viên luôn dựng từ CẢ cuốn (nhân vật nhắc nhiều ở chương khác vẫn nhận ra được ở
/// chương này), chỉ việc hỏi Laya mới giới hạn theo [chuong].
///
/// [gioiDaBiet] là giới tính của các nhân vật đã có trong danh bạ (tên -> 'nam' | 'nu'): không
/// đoán lại, vừa đỡ gọi Laya vừa giữ nguyên chỗ người dùng đã sửa tay.
///
/// [tienDo] nhận (đã xong, tổng) theo số câu thoại. [huy] trả true thì dừng sớm và trả những gì
/// đã có.
Future<KetQuaNhanVat> phanTichNhanVat(
  List<List<String>> doanVanTheoChuong,
  LayaKhach laya, {
  Set<int>? chuong,
  Map<String, String> gioiDaBiet = const {},
  void Function(int xong, int tong)? tienDo,
  bool Function()? huy,
}) async {
  final ungVien = timUngVien(doanVanTheoChuong, chuong: chuong);
  if (ungVien.length < 2) return KetQuaNhanVat([], {});
  final ten = [for (final (t, _) in ungVien) t];

  var tong = 0;
  for (var c = 0; c < doanVanTheoChuong.length; c++) {
    if (chuong != null && !chuong.contains(c)) continue;
    for (final d in doanVanTheoChuong[c]) {
      final h = _cauHoi(d).length;
      tong += laDoanThoai(d) ? min(1, h) : h;
    }
  }
  final nguoiNoi = <String, String>{};
  final dem = <String, int>{};
  var xong = 0;

  for (var c = 0; c < doanVanTheoChuong.length; c++) {
    if (chuong != null && !chuong.contains(c)) continue;
    final ds = doanVanTheoChuong[c];
    // Người nói nhiều nhất của chương làm ứng viên dự phòng khi tên không đứng gần câu thoại.
    // Chưa biết ai nói nhiều nhất trước khi hỏi, nên tạm lấy theo số lần được nhắc ở dòng dẫn.
    final xep = [...ten]..sort((a, b) => ungVien.firstWhere((e) => e.$1 == b).$2.compareTo(ungVien.firstWhere((e) => e.$1 == a).$2));
    final hangDau = xep.take(3).toList();
    for (var i = 0; i < ds.length; i++) {
      final cau = cacCauThoai(ds[i]);
      final hoi = _cauHoi(ds[i]);
      if (hoi.isEmpty) continue;
      final cuaSo = ds.sublist(max(0, i - 6), min(ds.length, i + 3)).join('\n');
      final lua = <String>[
        for (final t in ten)
          if (_coTen(t, cuaSo)) t,
      ];
      for (final t in hangDau) {
        if (!lua.contains(t)) lua.add(t);
      }
      final chon = lua.take(toiDaUngVien).toList();
      // Đoạn văn MỞ ĐẦU bằng thoại (kiểu Harry Potter: mỗi lời thoại một dòng) hỏi MỘT lần cả đoạn,
      // đúng cách đã đo 2.1.0 (84/90), rồi gán cho mọi lời nói trong đoạn. Lời nói nằm trong đoạn
      // kể thì hỏi TỪNG câu với đoạn trích theo ký tự — cách dựng dữ liệu luyện cho Lộc Đỉnh Ký.
      final mot = laDoanThoai(ds[i]);
      for (final q in mot ? [hoi.first] : hoi) {
        if (huy?.call() ?? false) return _ketQua(ten, dem, nguoiNoi, gioiDaBiet);
        xong++;
        if (chon.length >= 2) {
          final p = await laya.chon(
            huongDanNguoiNoi,
            mot ? doanTrichQuanhThoai(ds, i) : doanTrichQuanhCau(ds, i, cau[q]),
            mot ? ds[i] : ds[i].substring(cau[q].noiDau - 1, min(ds[i].length, cau[q].noiCuoi + 1)),
            [for (final t in chon) (t, t)],
          );
          var best = 0;
          for (var k = 1; k < p.length; k++) {
            if (p[k] > p[best]) best = k;
          }
          if (p[best] >= nguongTinCay) {
            for (final qq in mot ? hoi : [q]) {
              nguoiNoi[KetQuaNhanVat.khoa(c, i, qq)] = chon[best];
              dem[chon[best]] = (dem[chon[best]] ?? 0) + 1;
            }
          }
        }
        tienDo?.call(xong, tong);
      }
    }
  }
  // Chữ cả cuốn chỉ cần khi có nhân vật MỚI cần đoán giới tính (dựng chuỗi này tốn vài chục ms
  // với sách dày, nên không dựng khi không cần).
  String? toanVan;
  final nhan = <NhanVat>[];
  for (final t in ten) {
    if ((dem[t] ?? 0) == 0) continue;
    var gioi = gioiDaBiet[t];
    if (gioi == null) {
      toanVan ??= doanVanTheoChuong.expand((e) => e).join('\n');
      gioi = await doanGioiTinh(laya, t, toanVan);
    }
    nhan.add(NhanVat(ten: t, gioi: gioi, soCau: dem[t]!));
  }
  nhan.sort((a, b) => b.soCau.compareTo(a.soCau));
  // Người không có câu thoại nào thì không có gì để chọn giọng: bỏ khỏi bảng người nói luôn.
  nguoiNoi.removeWhere((_, v) => !nhan.any((n) => n.ten == v));
  return KetQuaNhanVat(nhan, nguoiNoi);
}

KetQuaNhanVat _ketQua(List<String> ten, Map<String, int> dem, Map<String, String> nguoiNoi, Map<String, String> gioiDaBiet) {
  String gioiCua(String t) =>
      gioiDaBiet[t] ?? (_gioiTheoChucDanh(t).isEmpty ? 'nam' : _gioiTheoChucDanh(t));
  final nhan = [
    for (final t in ten)
      if ((dem[t] ?? 0) > 0) NhanVat(ten: t, gioi: gioiCua(t), soCau: dem[t]!),
  ]..sort((a, b) => b.soCau.compareTo(a.soCau));
  return KetQuaNhanVat(nhan, nguoiNoi);
}
