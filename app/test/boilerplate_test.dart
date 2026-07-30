/// Kiểm thử bộ lọc rác của trang đăng truyện.
///
/// Các mẫu ở đây lấy nguyên văn từ sách thật tải trên mạng: header lặp ở đầu
/// mỗi chương, trang bìa ghi nguồn, và chương mục lục. Phần "không được đụng
/// vào" quan trọng ngang phần "phải bỏ" — xoá nhầm một câu văn thì người nghe
/// mất nội dung mà không hề biết.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/boilerplate.dart';
import 'package:sach_noi/models/book.dart';

/// Dựng một chương có header lặp giống sách của DTV-EBOOK.
RawChapter _withHeader(int n, String body) => RawChapter(
      'Chương $n: Tiêu đề',
      'Phàm Nhân Tu Tiên\n\nVong Ngữ\n\nDTV-EBOOK.COM.VN\n\nQuyển 1\n\n'
          'Chương $n: Tiêu đề\n\n$body',
    );

void main() {
  group('Bỏ header lặp ở đầu chương', () {
    test('cắt tên sách, tác giả và tên trang web nhưng giữ nội dung', () {
      final chapters = [
        for (var i = 1; i <= 10; i++)
          _withHeader(i, 'Đây là nội dung thật của chương $i, dài và không lặp lại ở đâu cả.'),
      ];

      final report = stripBoilerplate(chapters);

      expect(report.chapters, hasLength(10));
      for (final chapter in report.chapters) {
        expect(chapter.text, isNot(contains('DTV-EBOOK')));
        expect(chapter.text, isNot(contains('Vong Ngữ')));
        expect(chapter.text, contains('nội dung thật của chương'));
      }
      expect(report.removedLines, greaterThanOrEqualTo(20));
    });

    test('sách ít chương thì không dám suy đoán theo tần suất', () {
      final chapters = [
        RawChapter('Chương 1', 'Một câu mở đầu quen thuộc.\n\nNội dung chương một.'),
        RawChapter('Chương 2', 'Một câu mở đầu quen thuộc.\n\nNội dung chương hai.'),
      ];
      final report = stripBoilerplate(chapters);
      expect(report.removedLines, 0);
      expect(report.chapters[0].text, contains('Một câu mở đầu quen thuộc'));
    });
  });

  group('Bỏ chương rác', () {
    test('chương mục lục bị bỏ hẳn', () {
      final toc = StringBuffer();
      for (var i = 1; i <= 60; i++) {
        toc.writeln('Chương $i: Tên chương thứ $i');
      }
      final chapters = [
        RawChapter('Mục lục', toc.toString()),
        RawChapter('Chương 1', 'Nội dung thật sự của cuốn sách bắt đầu từ đây.'),
      ];

      final report = stripBoilerplate(chapters);
      expect(report.chapters, hasLength(1));
      expect(report.removedChapters, 1);
      expect(report.chapters.first.title, 'Chương 1');
    });

    test('trang bìa ghi nguồn tải bị bỏ', () {
      final chapters = [
        RawChapter(
          'TÊN SÁCH',
          'TÊN SÁCH\n\nTác giả: Sở Thu Vi Hàn\nThể loại: Hiện Đại\n'
              'Nguồn: Tuấn Trần —★— DTV-EBOOK.COM.VN',
        ),
        RawChapter('Chương 1', 'Nội dung thật sự của cuốn sách bắt đầu từ đây.'),
      ];

      final report = stripBoilerplate(chapters);
      expect(report.removedChapters, 1);
      expect(report.chapters.first.title, 'Chương 1');
    });

    test('không bao giờ bỏ sạch cả cuốn sách', () {
      final chapters = [RawChapter('Mục lục', 'Chương 1: A\nChương 2: B\n' * 30)];
      final report = stripBoilerplate(chapters);
      expect(report.chapters, isNotEmpty);
    });
  });

  group('Bỏ dòng ghi công và quảng cáo', () {
    test('bắt các kiểu ghi công thường gặp ở cuối chương', () {
      final junk = [
        'Nguồn: truyenfull.vn',
        'Converter: Alobooks',
        'Nhóm dịch: Thất Nguyệt',
        'Đọc truyện mới nhất tại TruyenYY',
        'Vui lòng ủng hộ nhóm dịch tại fanpage nhé các bạn',
        '——— o O o ———',
        'https://dtv-ebook.com.vn',
      ];
      for (final line in junk) {
        final report = stripBoilerplate([
          RawChapter('Chương 1', 'Câu văn thật nằm ở đây và phải được giữ nguyên.\n\n$line'),
        ]);
        expect(report.chapters.first.text, isNot(contains(line)), reason: 'phải bỏ: $line');
        expect(report.chapters.first.text, contains('Câu văn thật'));
      }
    });

    test('không xoá câu văn chỉ vì có nhắc tới web hay chữ nguồn', () {
      const keep = 'Hắn mở máy tính, gõ vào thanh địa chỉ rồi chờ trang web hiện ra, '
          'trong lòng thầm nghĩ nguồn tin này liệu có đáng tin hay không.';
      final report = stripBoilerplate([RawChapter('Chương 1', keep)]);
      expect(report.chapters.first.text, contains('nguồn tin này'));
      expect(report.removedLines, 0);
    });

    test('giữ nguyên ranh giới đoạn văn sau khi dọn', () {
      final chapters = [
        for (var i = 1; i <= 8; i++)
          RawChapter('Chương $i', 'TRUYENFULL.VN\n\nĐoạn văn thứ nhất của chương $i.\n\n'
              'Đoạn văn thứ hai của chương $i.'),
      ];
      final report = stripBoilerplate(chapters);
      // Hai đoạn vẫn phải cách nhau bằng dòng trống, nếu không bộ cắt đoạn sẽ
      // dính chúng làm một và nhịp đọc thay đổi.
      expect(report.chapters.first.text,
          'Đoạn văn thứ nhất của chương 1.\n\nĐoạn văn thứ hai của chương 1.');
    });
  });
}
