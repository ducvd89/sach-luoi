/// Hai lỗi hay gặp ở sách convert từ web, và cách chữa.
///
/// 1. Tên riêng viết hoa toàn bộ bị sea-g2p coi là từ viết tắt rồi đánh vần:
///    "Ngôi nhà RIDDLE." đọc thành "Ngôi nhà R-I-D-D-L-E".
/// 2. Tiêu đề chương bị lặp lại ở đầu thân bài, nhưng đánh số theo kiểu khác
///    ("Chương 01:" so với "CHƯƠNG MỘT") nên phép so nguyên văn không bắt được.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/chunker.dart';
import 'package:sach_noi/models/book.dart';

void main() {
  group('bảng chữ hoa dựng từ chính cuốn sách', () {
    test('nhận tên riêng vì nó cũng xuất hiện ở dạng thường', () {
      final bang = bangChuHoaTenRieng([
        const RawChapter('NGÔI NHÀ RIDDLE', 'Gia đình Riddle sống ở đó. Riddle giàu có.'),
      ]);
      expect(bang['riddle'], 'Riddle');
    });

    test('KHÔNG nhận từ viết tắt thật', () {
      // "USB" không bao giờ xuất hiện thành "Usb" nên không có bằng chứng để
      // sửa — và đánh vần U-S-B mới là đọc đúng.
      final bang = bangChuHoaTenRieng([
        const RawChapter('Chương 1', 'Cắm USB vào máy rồi mở file HTML.'),
      ]);
      expect(bang.containsKey('usb'), isFalse);
      expect(bang.containsKey('html'), isFalse);
    });

    test('lấy dạng gặp nhiều nhất, không phải dạng gặp đầu tiên', () {
      final bang = bangChuHoaTenRieng([
        const RawChapter('', 'riddle. Riddle. Riddle. Riddle.'),
      ]);
      expect(bang['riddle'], 'Riddle');
    });
  });

  group('sửa chữ hoa trong văn bản đọc lên', () {
    final bang = {'riddle': 'Riddle', 'hangleton': 'Hangleton'};

    test('đổi tên riêng viết hoa về dạng thường', () {
      expect(
        suaChuHoaTenRieng('Ngôi nhà RIDDLE ở làng HANGLETON.', bang),
        'Ngôi nhà Riddle ở làng Hangleton.',
      );
    });

    test('không đụng tới từ không có trong bảng', () {
      expect(suaChuHoaTenRieng('Cắm USB vào máy.', bang), 'Cắm USB vào máy.');
    });

    test('không đụng tới chữ thường', () {
      expect(suaChuHoaTenRieng('Ngôi nhà Riddle.', bang), 'Ngôi nhà Riddle.');
    });

    test('bảng rỗng thì trả nguyên văn', () {
      expect(suaChuHoaTenRieng('NGÔI NHÀ RIDDLE', {}), 'NGÔI NHÀ RIDDLE');
    });
  });

  group('tiêu đề chương lặp ở đầu thân bài', () {
    test('bỏ được dù mục lục ghi số còn thân bài ghi chữ', () {
      final ra = buildChunks([
        const RawChapter(
          'Chương 01: NGÔI NHÀ RIDDLE.',
          'CHƯƠNG MỘT NGÔI NHÀ RIDDLE\n\n'
              'Dân làng Hangleton Nhỏ vẫn còn gọi đó là Ngôi Nhà Riddle.',
        ),
      ]);
      // Đúng một đoạn mang tiêu đề, và thân bài không mở đầu bằng tiêu đề nữa.
      final tieuDe = ra.chunks.where((c) => c.heading).length;
      expect(tieuDe, 1);
      final than = ra.chunks.where((c) => !c.heading).toList();
      expect(than.first.display, isNot(contains('CHƯƠNG MỘT')));
      expect(than.first.display, startsWith('Dân làng'));
    });

    test('không xoá nhầm dòng mở đầu của chương khác', () {
      // Cả hai đều rút về rỗng sau khi bỏ số — không được coi là khớp.
      final ra = buildChunks([
        const RawChapter('Chương 1', 'Chương 2\n\nNội dung của chương này.'),
      ]);
      final than = ra.chunks.where((c) => !c.heading).toList();
      expect(than.any((c) => c.display.contains('Chương 2')), isTrue);
    });
  });
}
