/// Đếm số âm tiết mà văn bản sẽ đọc ra — phần chữ của phép kiểm âm.
///
/// Hai tầng. Tầng đầu là bảng số viết tay nên máy nào cũng chạy được; mọi con
/// số trong bảng lấy từ âm vị THẬT do sea-g2p sinh ra, ghi kèm ngay cạnh để lần
/// sau khỏi phải đoán lại. Tầng sau gọi thẳng sea-g2p đối chiếu, và tự bỏ qua
/// khi máy chưa build thư viện.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/am_tiet_chu.dart';
import 'package:sach_noi/services/tts/sea_g2p.dart';

import 'duong_dan_repo.dart';

void main() {
  group('Nhận diện âm tiết tiếng Việt', () {
    test('nhận đủ các kiểu vần, kể cả vần hiếm', () {
      const nhan = [
        'người', 'chuyện', 'nghiêng', 'khuya', 'quá', 'giường', 'thuyền', 'oai',
        'khuỷu', 'quyên', 'xoong', 'ướt', 'yếu', 'nguyễn', 'hoặc', 'giếng',
        'ngoằn', 'trăng', 'thương', 'chương', 'không', 'được', 'uyên', 'ưu',
        'anh', 'em', 'ba', 'ai', 'gì', 'ơi', 'ừ',
      ];
      for (final tu in nhan) {
        expect(laAmTietViet(tu), isTrue, reason: '"$tu" là âm tiết tiếng Việt');
      }
    });

    test('từ không dấu mà sea-g2p vẫn đọc theo tiếng Việt', () {
      // Đây là chỗ ăn tiền: `can → kˈaːn`, `ban → bˈaːn`, `sang → sˈaːŋ`,
      // `do → zˈɔ` — không dấu nhưng vẫn một âm. Đoán chúng là tiếng Anh thì
      // vẫn ra 1, nhưng nhận đúng thì chắc chắn hơn.
      for (final tu in ['can', 'ban', 'sang', 'tin', 'do', 'la', 'mua', 'long']) {
        expect(laAmTietViet(tu), isTrue, reason: '"$tu"');
      }
    });

    test('loại từ tiếng Anh nhờ phụ âm cuối và cụm phụ âm đầu', () {
      // `de`, `ne`, `me` không phải phụ âm cuối tiếng Việt; `bl`, `str`, `gr`
      // không phải phụ âm đầu.
      const loai = [
        'code', 'phone', 'time', 'blue', 'stream', 'green', 'space', 'chrome',
        'Harry', 'Potter', 'London', 'Snape', 'Holmes', 'Paris', 'Tokyo',
        'radio', 'media', 'about', 'hello', 'happy', 'city', 'Windows', 'driver',
      ];
      for (final tu in loai) {
        expect(laAmTietViet(tu), isFalse, reason: '"$tu" không phải âm tiết tiếng Việt');
      }
    });
  });

  group('Đoán âm tiết tiếng Anh', () {
    // Số mong đợi = số nhân âm trong âm vị sea-g2p sinh ra, ghi kèm để đối chiếu.
    const bang = {
      // một âm
      'phone': 1, // fˈoʊn
      'blue': 1, // blˈuː
      'stream': 1, // stɹˈiːm
      'through': 1, // θɹˈuː
      'code': 1, // kˈoʊd
      'change': 1, // tʃˈeɪndʒ
      'strange': 1, // stɹˈeɪndʒ
      'edge': 1, // ˈɛdʒ
      'the': 1, 'one': 1, 'here': 1, 'please': 1, 'three': 1,
      'Snape': 1, // snˈeɪp
      'Holmes': 1, // hˈoʊmz
      // đuôi -ed, -es
      'walked': 1, // wˈɔːkt
      'passed': 1, // pˈæst
      'played': 1, // plˈeɪd
      'wanted': 2, // wˈɔntᵻd
      'needed': 2,
      'boxes': 2, // bˈɑːksᵻz
      'houses': 2, // hˈaʊzᵻz
      'watches': 2, // wˈɑːtʃᵻz
      'names': 1, 'pages': 2, 'places': 2, 'sizes': 2,
      // đuôi -le là âm thật, -e cuối thì câm
      'people': 2, // pˈiːpəl
      'table': 2, // tˈeɪbəl
      'little': 2, // lˈɪɾəl
      'cycle': 2, // sˈaɪkəl
      'available': 4, // ɐvˈeɪləbəl
      // tên riêng hay gặp trong sách dịch
      'Harry': 2, // hˈæɹi
      'Potter': 2, // pˈɑːɾɚ
      'Weasley': 2, // wˈiːzli
      'Hagrid': 2, // hˈæɡɹɪd
      'Sherlock': 2, // ʃˈɜːlɑːk
      'Watson': 2, // wˈɑːtsən
      'London': 2, // lˈʌndən
      'Paris': 2, // pˈæɹɪs
      'Tokyo': 3, // tˈoʊkɪˌoʊ
      'Voldemort': 3, // vˈɑːldᵻmˌɔːɹ
      'Gryffindor': 3, // ɡɹˈɪfaɪndˌɔːɹ
      'Slytherin': 3, // slˈaɪθɚɹˌɪn
      'Dumbledore': 3, // dˈʌməldˌɔːɹ
      'America': 4, // ɐmˈɛɹɪkə
      // từ ghép viết dính — đã được `danhDauTiengAnh` bọc thẻ <en>
      'Windows': 2, // wˈɪndoʊz
      'iPhone': 2, // ˈaɪfoʊn
      'eBay': 2, // ˈiːbeɪ
      'YouTube': 2, // jˈuːtuːb
      'MacBook': 2, // mˈækbʊk
      'Google': 2, // ɡˈuːɡəl
      'Microsoft': 3, // mˈaɪkɹəsˌɑːft
      // dài, nhiều âm
      'driver': 2, // dɹˈaɪvɚ
      'computer': 3, // kəmpjˈuːɾɚ
      'container': 3, // kəntˈeɪnɚ
      'internet': 3, // ˈɪntɚnˌɛt
      'application': 4, // ˌæplɪkˈeɪʃən
      'university': 5, // jˌuːnɪvˈɜːsᵻɾi
      'vegetable': 4, // vˈɛdʒɪɾəbəl
      // hai nguyên âm cuối tách làm hai âm
      'radio': 3, // ɹˈeɪdɪˌoʊ
      'audio': 3, // ˈɔːdɪˌoʊ
      'video': 3, // vˈɪdɪoʊ
      'media': 3, // mˈiːdiːə
      'India': 3, // ˈɪndiə
      'studio': 3, // stˈuːdɪˌoʊ
      'Romeo': 3, // ɹˈoʊmɪˌoʊ
      // …trừ sau t/s/c/x, vì đó là -tion, -sia
      'Asia': 2, // ˈeɪʒə
      'Russia': 2, // ɹˈʌʃə
    };

    bang.forEach((tu, so) {
      test('$tu → $so âm', () => expect(demAmTiengAnh(tu), so));
    });
  });

  group('Từ viết hoa toàn bộ thì đánh vần', () {
    // sea-g2p coi từ viết hoa đứng giữa chữ thường là viết tắt rồi đọc từng chữ
    // cái — kể cả khi đó là từ tiếng Việt: `ANH → ˈeɪ ˈɛn ˈeɪtʃ`.
    const bang = {
      'Cắm USB vào máy': 6, // Cắm(1) + U-S-B(3) + vào(1) + máy(1)
      'Ngôi nhà RIDDLE': 8, // 2 + R-I-D-D-L-E(6)
      'Xem TV đi': 4, // 1 + T-V(2) + 1
      'Ngôi nhà ANH đó': 6, // 2 + A-N-H(3) + 1
      'Hỏi AI xem': 4, // 1 + A-I(2) + 1
      'Máy có WWW rồi': 12, // 2 + W×3 âm ×3(9) + 1 — "đáp-bờ-liu"
    };
    bang.forEach((cau, so) {
      test('"$cau" → $so âm', () => expect(demAmChu(cau), so));
    });

    test('cả câu viết hoa thì KHÔNG đánh vần', () {
      // Không có tương phản hoa/thường thì sea-g2p đọc như thường — đo được
      // `NGÔI NHÀ RIDDLE.` chỉ bốn nhân âm, đúng bằng lúc viết thường.
      expect(demAmChu('NGÔI NHÀ RIDDLE.'), 4);
      expect(demAmChu('Ngôi nhà RIDDLE.'), 8);
      // Chữ HOA có dấu vẫn phải tính là chữ hoa. Dải `[a-zà-ỹ]` xếp theo mã ký
      // tự nên `Ă`, `Ơ`, `Ư` lọt vào giữa và câu này bị coi là có chữ thường,
      // rồi RIDDLE bị đánh vần thành sáu âm thay vì đọc liền "rid-dle" hai âm.
      expect(demAmChu('NGĂN CẢN RIDDLE.'), 4);
      expect(demAmChu('CƠN MƯA RIDDLE.'), 4);
    });

    test('có dấu tiếng Việt thì thoát, dù viết hoa', () {
      // `MỘT → mˈo6t̪`, đọc liền chứ không đánh vần.
      expect(demAmChu('Ngôi nhà MỘT đó'), 4);
    });
  });

  group('Cả đoạn', () {
    test('tiếng Việt thuần: mỗi chữ một âm, dấu câu không tính', () {
      expect(demAmChu('Xin chào, đây là bản đọc thử.'), 7);
      expect(demAmChu('Ông ấy đi — rồi về .'), 5);
      expect(demAmChu(''), 0);
      expect(demAmChu('   '), 0);
    });

    test('chữ số đọc thành nhiều âm', () {
      // "1975" -> một nghìn chín trăm bảy mươi lăm (7 âm) + "Năm" = 8.
      expect(demAmChu('Năm 1975.'), 8);
      expect(demAmChu('3km'), 2); // "ba" + "km"
      expect(demAmChu('Chương 12'), 3); // "Chương" + "mười" + "hai"
    });

    test('thẻ <en> là chỉ dẫn cho g2p, không phải chữ để đọc', () {
      // `normalizeForSpeech` bọc thẻ quanh từ ghép viết dính, nên speech lưu
      // trong chunks.json có sẵn thẻ. Đếm cả thẻ thì "<en>iPhone</en>" thành
      // một cục dính liền không ra âm nào đúng.
      expect(demAmChu('Mua <en>iPhone</en> mới'), 4); // 1 + 2 + 1
      expect(demAmChu('Mua iPhone mới'), 4);
    });

    test('từ ghép nối bằng gạch thì đếm từng mảnh', () {
      expect(demAmChu('gửi e-mail đi'), 4); // 1 + e(1) + mail(1) + 1
    });

    test('dấu lược không tạo thêm âm', () {
      expect(demAmTiengAnh("don't"), 1);
      expect(demAmTiengAnh("O'Brien"), 2);
    });

    test('câu lẫn tiếng Anh không còn bị đếm hụt', () {
      // Số âm vị thật đo bằng sea-g2p. Cách đếm cũ (mỗi từ một âm) cho ra con
      // số trong ngoặc — lệch tới 35%, vượt xa dải ±15% của `kiem_am.dart`,
      // nên đoạn đọc hoàn toàn đúng vẫn bị bắt đọc lại năm lần.
      expect(demAmChu('Anh ấy mở Windows lên rồi cài driver mới.'), 11); // cũ 9
      expect(demAmChu('Cắm USB vào máy tính rồi bật lên.'), 10); // cũ 8
      expect(demAmChu('Giáo sư Dumbledore nhìn Voldemort rồi quay sang Severus Snape.'), 16); // cũ 10
      expect(demAmChu('Sherlock Holmes và bác sĩ Watson rời London đi Paris trong đêm.'), 16); // cũ 12
      expect(demAmChu('Chương trình chạy trên Google Chrome nhanh hơn hẳn Microsoft Edge.'), 14);
    });
  });

  group('Sai số đã biết', () {
    // Ghi lại để lần sau ai sửa phép đoán thì biết mình đang đổi cái gì, chứ
    // không phải mục tiêu phải đạt. Tất cả lệch đúng MỘT âm và lệch cả hai
    // chiều nên bù trừ nhau trong một đoạn dài — trừ NASA lệch hai.
    const lech = {
      'business': (3, 2), // bˈɪznəs — "bus-ness", nuốt mất nguyên âm giữa
      'chocolate': (3, 2), // tʃˈɑːklət
      'interesting': (4, 3), // ˈɪntɹɛstɪŋ
      'comfortable': (4, 3), // kˈʌmftəbəl
      'Facebook': (3, 2), // fˈeɪsbʊk — `e` câm nằm giữa từ ghép
      'create': (1, 2), // kɹiːˈeɪt — hai nguyên âm giữa từ lại tách đôi
      'Hermione': (2, 4), // hɜːmˈaɪəni
    };
    lech.forEach((tu, so) {
      final (doan, that) = so;
      test('$tu: đoán $doan, thật $that', () => expect(demAmTiengAnh(tu), doan));
    });

    test('NASA đã có trong từ điển nên đọc liền, không đánh vần', () {
      // `nˈæsɐ` — hai âm, nên cả câu đọc ra năm âm; ở đây đánh vần N-A-S-A nên
      // đếm thành bảy. Đoán ngược lại thì sai với cả nghìn từ viết tắt khác.
      expect(demAmChu('Ngôi nhà NASA đó'), 7);
    });
  });

  _doiChieuVoiG2p();
}

/// Đối chiếu thẳng với sea-g2p: số âm đoán được phải sát số nhân âm trong chuỗi
/// âm vị mà mô hình thật sự nhận.
void _doiChieuVoiG2p() {
  test('sát âm vị thật trên câu lẫn tiếng Anh', () {
    final dict = '$assetsDir/sea_g2p.bin';
    if (!File(seaG2pLibPath).existsSync() || !File(dict).existsSync()) {
      markTestSkipped('Chưa build sea-g2p — bỏ qua');
      return;
    }
    final g2p = SeaG2p.open(dictPath: dict, libraryPath: seaG2pLibPath);
    addTearDown(g2p.close);

    const cau = [
      'Ngôi nhà RIDDLE.',
      'NGÔI NHÀ RIDDLE.',
      'Cắm USB vào máy tính rồi bật lên.',
      'Anh ấy mở Windows lên rồi cài driver mới.',
      'Harry Potter và Hermione bước vào phòng chung của nhà Gryffindor.',
      'Giáo sư Dumbledore nhìn Voldemort rồi quay sang Severus Snape.',
      'Cô ấy dùng iPhone quay video rồi tải lên YouTube và Facebook.',
      'Chương trình chạy trên Google Chrome nhanh hơn hẳn Microsoft Edge.',
      'Sherlock Holmes và bác sĩ Watson rời London đi Paris trong đêm.',
      'Ứng dụng này có trên Windows, Android và cả MacBook nữa.',
      'Xin chào, đây là bản đọc thử của ứng dụng sách nói.',
      'Buổi sáng hôm ấy trời trong xanh và gió nhẹ thổi qua khu vườn nhỏ sau nhà.',
    ];

    var lechTong = 0.0;
    for (final c in cau) {
      final that = _nhanAm(g2p.phonemize(c));
      final doan = demAmChu(c);
      lechTong += (doan / that - 1).abs();
      // ignore: avoid_print
      print('${doan.toString().padLeft(3)}/$that  $c');
    }
    final lech = lechTong / cau.length;
    // ignore: avoid_print
    print('Lệch trung bình ${(lech * 100).toStringAsFixed(1)}%');

    // Đo được 1,5% khi dò; cách đếm cũ (mỗi từ một âm) cho 24,3% trên đúng bộ
    // câu này. Ngưỡng chống hồi quy, không phải mục tiêu.
    expect(lech, lessThan(0.05),
        reason: 'đoán số âm lệch quá xa âm vị thật — xem lại am_tiet_chu.dart');
  });
}

/// Nguyên âm trong bộ âm vị sea-g2p sinh ra, gồm cả tiếng Việt lẫn tiếng Anh.
const _nguyenAm = 'aɑɐæeɛəɘɤiɪᵻoɔøœuʊɯyʏʌɚɝɜɨ';

/// Số nhân âm trong chuỗi âm vị: gom các nguyên âm liền nhau làm một.
///
/// Dấu trọng âm `ˈ`/`ˌ` phải đổi thành RANH GIỚI chứ không được xoá — xoá đi
/// thì `jˌuːˌɛs` (chữ U rồi chữ S) dính lại thành một nhân âm.
///
/// Vẫn là phép xấp xỉ: nguyên âm đôi rồi tới nguyên âm mờ trong cùng một nhịp
/// (`aɪə` của Hermione) bị gom nhầm làm một, nên chỉ dùng để canh sai số tổng
/// chứ đừng dùng để chốt số cho từng từ.
int _nhanAm(String am) {
  final s = am.replaceAll(RegExp(r'[ˈˌ]'), '|').replaceAll(RegExp(r'[ːʰ̃\-0-9]'), '');
  var so = 0;
  var truoc = false;
  for (final c in s.split('')) {
    final la = _nguyenAm.contains(c);
    if (la && !truoc) so++;
    truoc = la;
  }
  return so;
}
