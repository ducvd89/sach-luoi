// Nhận diện nhân vật cho truyện dịch kiểu Kim Dung — không cần sách ngoài (xem `kim_dung_test.dart`
// cho bản chạy trên cuốn thật). Mỗi bài ghim một lỗi đã gặp ở Thần Điêu Đại Hiệp.
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/chunker.dart';
import 'package:sach_noi/core/nhan_vat.dart';
import 'package:sach_noi/models/book.dart';

void main() {
  test('gạch thoại dính liền chữ ("-Kìa") vẫn là thoại, dính liền số ("-5 độ") thì không', () {
    expect(laDoanThoai('-Kìa, đến hôm nay ông lão vẫn còn ngồi đó.'), isTrue);
    expect(laDoanThoai('- Các chị ơi, ông lão kia ngồi đó ba ngày.'), isTrue);
    expect(laDoanThoai('— Ai đó?'), isTrue);
    expect(laDoanThoai('-5 độ C ngoài trời'), isFalse);
    expect(laDoanThoai('Trình Anh bấm nhẹ vào vai Lục Vô Song bảo:'), isFalse);
  });

  test('khoaTen gộp gạch nối, dấu cách và hoa thường', () {
    expect(khoaTen('Lý-mạc-Thu'), khoaTen('Lý Mạc Thu'));
    expect(khoaTen('Dương-Qua'), 'dương qua');
    expect(khoaTen('  Vi  Tiểu Bảo '), 'vi tiểu bảo');
  });

  test('tên nhiều âm tiết được nhận dù âm tiết của nó cũng là từ thường', () {
    // "trình", "anh", "vô", "song", "dương", "qua" đều có viết thường trong đoạn văn.
    final chuong = [
      'Trình Anh bấm nhẹ vào vai Lục Vô Song bảo:',
      '- Nói khẽ chứ nếu ông ta nghe được thì khốn!',
      'Lục Vô Song vẫn lớn tiếng:',
      '- Nếu không người điên sao mặc áo phụ nữ?',
      'Trình Anh lắc đầu nói:',
      '- Anh ấy qua đây từ dương gian, không phải người điên.',
      'Lục Vô Song cười đáp:',
      '- Thế thì song song cả hai người điên rồi.',
      'Dương-Qua nói:',
      '- Ta đi.',
      'Dương Qua hỏi:',
      '- Các ngươi là ai?',
    ];
    final ds = timUngVien([chuong]);
    final ung = {for (final (t, n) in ds) khoaTen(t): n};
    expect(ung.keys, containsAll(['trình anh', 'lục vô song', 'dương qua']));
    expect(ds.where((e) => khoaTen(e.$1) == 'dương qua'), hasLength(1),
        reason: '"Dương-Qua" và "Dương Qua" là MỘT nhân vật, không phải hai mục');
    expect(ung['dương qua']! >= 2, isTrue);
    // Không bị chặt thành mảnh "Trình", "Anh", "Lục".
    expect(ung.keys, isNot(contains('trình')));
    expect(ung.keys, isNot(contains('lục')));
  });

  test('lấy tên ĐẦU TIÊN của dòng dẫn (chủ ngữ), kể cả khi nó nằm giữa câu', () {
    final chuong = [
      'Họ ngồi trong thuyền, mọi việc đã xong rồi.', // để "trong", "rồi" có dạng viết thường như sách thật
      'Trong lúc mọi người đang chú ý thì Lục Vô Song nhảy dựng lên, chỉ vào Trình Anh nói:',
      '- Nhìn kìa!',
      'Rồi Lục Vô Song cười:',
      '- Hay quá!',
    ];
    final ung = {for (final (t, n) in timUngVien([chuong])) khoaTen(t): n};
    expect(ung['lục vô song']! >= 2, isTrue, reason: 'chủ ngữ là Lục Vô Song, không phải người bị chỉ');
    expect(ung.keys, isNot(contains('trình anh')));
  });

  test('đoạn bị ngắt cứng giữa câu được nối lại thành MỘT đoạn văn', () {
    // Bản scan: câu bị chặt làm đôi, mỗi nửa một <p>; nửa sau mở đầu bằng chữ thường.
    final ds = doanVanCuaChuong(const RawChapter(
      'Hồi 1',
      'Hồi 1\n\nLục Vô Song nhảy dựng trên thuyền, chỏ\n\nmiệng về phía ông già nói:\n\n- Các chị ơi!\n\nTrình Anh bảo:',
    ));
    expect(ds, [
      'Lục Vô Song nhảy dựng trên thuyền, chỏ miệng về phía ông già nói:',
      '- Các chị ơi!',
      'Trình Anh bảo:',
    ]);
  });

  test('sách chuẩn (đoạn nào cũng mở bằng chữ hoa) không bị nối gì', () {
    final ds = doanVanCuaChuong(const RawChapter('', 'Một.\n\nHai.\n\n“Ba.”\n\nBốn.'));
    expect(ds, ['Một.', 'Hai.', '“Ba.”', 'Bốn.']);
  });

  test('nhân vật chỉ nổi ở chương đang phân tích vẫn được nhận, dù cả sách hiếm nhắc', () {
    // "Tỉnh-Quang" chỉ có ở chương 1 (2 lần) còn "Dương Qua" có ~800 lần: dưới 1% của cả cuốn.
    final dong = [for (var i = 0; i < 400; i++) ...['Dương Qua nói:', '- Câu $i.']];
    final c0 = dong;
    final c1 = ['Tỉnh-Quang thưa:', '- Dạ.', 'Tỉnh-Quang hỏi:', '- Thưa sư phụ?'];
    final ca = {for (final (t, _) in timUngVien([c0, c1])) khoaTen(t)};
    expect(ca, isNot(contains('tỉnh quang')), reason: 'cả cuốn: dưới ngưỡng 1% nên bị coi là nhiễu');
    final rieng = {for (final (t, _) in timUngVien([c0, c1], chuong: {1})) khoaTen(t)};
    expect(rieng, contains('tỉnh quang'), reason: 'ngay trong chương 1 nó nói hai lần');
  });
}
