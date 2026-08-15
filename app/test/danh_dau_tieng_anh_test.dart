/// Gắn thẻ `<en>` cho từ ghép viết dính khi chuẩn hoá.
///
/// Bài này canh hai phía, và phía thứ hai mới là phía dễ hỏng: gắn ĐÚNG chỗ, và
/// **không** gắn vào từ tiếng Việt. Đoán sai một từ vốn đang đọc đúng thì đắt
/// hơn nhiều so với cái được — xem [danhDauTiengAnh].
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/text_normalizer.dart';

void main() {
  group('gắn thẻ cho từ ghép viết dính', () {
    for (final tu in ['iPhone', 'YouTube', 'MacBook', 'eBay', 'PowerPoint', 'GitHub']) {
      test(tu, () => expect(danhDauTiengAnh(tu), '<en>$tu</en>'));
    }

    test('giữ nguyên phần còn lại của câu', () {
      expect(
        danhDauTiengAnh('Anh ấy mua một chiếc iPhone mới.'),
        'Anh ấy mua một chiếc <en>iPhone</en> mới.',
      );
    });
  });

  group('KHÔNG gắn thẻ', () {
    test('từ tiếng Việt có dấu', () {
      const cau = 'Chỉ cần bản thể không bị phá hủy hoàn toàn.';
      expect(danhDauTiengAnh(cau), cau);
    });

    test('từ tiếng Việt không dấu', () {
      // sea-g2p đã tự lo mấy từ này; gắn thẻ chỉ tổ làm hỏng.
      const cau = 'Toi mua mot cai can nhua.';
      expect(danhDauTiengAnh(cau), cau);
    });

    test('từ nhập nhằng Việt–Anh để nguyên tiếng Việt', () {
      // "can", "ban", "tin" là từ tiếng Việt thật. Đây là quyết định có chủ ý:
      // thà đọc kiểu Việt còn hơn đoán sai ngữ cảnh.
      const cau = 'Tôi mua một cái can nhựa và một hộp ban đêm.';
      expect(danhDauTiengAnh(cau), cau);
    });

    test('từ tiếng Anh thường, viết rời', () {
      // Không cần thẻ: g2p đã ra âm vị tiếng Anh đúng cho những từ này.
      const cau = 'Anh ấy dùng Windows và tải file về máy.';
      expect(danhDauTiengAnh(cau), cau);
    });

    test('viết hoa toàn bộ', () {
      const cau = 'Cắm USB vào rồi mở file HTML.';
      expect(danhDauTiengAnh(cau), cau);
    });

    test('văn bản đã có thẻ thì không lồng thêm', () {
      const cau = 'Mua <en>iPhone</en> mới.';
      expect(danhDauTiengAnh(cau), cau);
    });
  });

  test('normalizeForSpeech gắn thẻ, normalizeForDisplay thì không', () {
    // Màn hình đọc phải thấy đúng chữ trong sách; thẻ chỉ dành cho engine.
    const cau = 'Anh ấy mua iPhone.';
    expect(normalizeForSpeech(cau), contains('<en>iPhone</en>'));
    expect(normalizeForDisplay(cau), isNot(contains('<en>')));
  });
}
