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

  /// Khoá "chương:đoạn văn" -> tên người nói. Đoạn văn không có trong bảng là người dẫn.
  final Map<String, String> nguoiNoi;

  static String khoa(int chuong, int doanVan) => '$chuong:$doanVan';

  String nguoiCua(int chuong, int doanVan) => nguoiNoi[khoa(chuong, doanVan)] ?? '';

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

  /// Đang đọc nhiều giọng. Chỉ có nghĩa khi các đoạn của sách đã cắt theo người nói
  /// (`Chunk.speaker`); sách chưa cắt lại thì bật cờ này cũng không đổi gì.
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
final _dongTuDauDong = RegExp('^\\s*\\p{Lu}.{0,80}?$_dongTuNoi', unicode: true);
final _tuNoiSauThoai = RegExp('[”"»]\\s*,?\\s*(.+?)\\s+$_dongTuNoi', unicode: true);

/// Đoạn văn mở đầu bằng dấu mở thoại: “ " « hoặc gạch đầu dòng kiểu truyện dịch cũ ("- Xin sư phụ"
/// và cả "-Kìa" dính liền, hay gặp ở bản scan). Gạch dính liền SỐ ("-5 độ") thì không phải thoại.
bool laDoanThoai(String doan) {
  final d = doan.trimLeft();
  if (d.isEmpty) return false;
  if ('“"«'.contains(d[0])) return true;
  return RegExp(r'^[—–-]\s*[\p{L}“"«]', unicode: true).hasMatch(d);
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
  final tuDem = RegExp(r'^\s*\p{Lu}\p{Ll}*\s').firstMatch(dong);
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
      if (!laDoanThoai(ds[i])) continue;
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
    tong += doanVanTheoChuong[c].where(laDoanThoai).length;
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
      if (!laDoanThoai(ds[i])) continue;
      if (huy?.call() ?? false) return _ketQua(ten, dem, nguoiNoi, gioiDaBiet);
      final cuaSo = ds.sublist(max(0, i - 6), min(ds.length, i + 3)).join('\n');
      final lua = <String>[
        for (final t in ten)
          if (_coTen(t, cuaSo)) t,
      ];
      for (final t in hangDau) {
        if (!lua.contains(t)) lua.add(t);
      }
      final chon = lua.take(toiDaUngVien).toList();
      xong++;
      if (chon.length >= 2) {
        final p = await laya.chon(
          huongDanNguoiNoi,
          doanTrichQuanhThoai(ds, i),
          ds[i],
          [for (final t in chon) (t, t)],
        );
        var best = 0;
        for (var k = 1; k < p.length; k++) {
          if (p[k] > p[best]) best = k;
        }
        if (p[best] >= nguongTinCay) {
          nguoiNoi[KetQuaNhanVat.khoa(c, i)] = chon[best];
          dem[chon[best]] = (dem[chon[best]] ?? 0) + 1;
        }
      }
      tienDo?.call(xong, tong);
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
