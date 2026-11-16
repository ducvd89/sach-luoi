// Các lỗi do Fable tìm ra khi rà soát tính năng giọng theo nhân vật, mỗi bài ghim một lỗi.
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/nhan_vat.dart';
import 'package:sach_noi/models/book.dart';
import 'package:sach_noi/services/library_service.dart';

Book _sach(List<Chapter> chuong) => Book(
      id: 'x',
      title: 't',
      author: '',
      language: 'vi',
      sourceFile: 'x.txt',
      format: 'txt',
      addedAt: DateTime(2026),
      chapters: chuong,
      chunkCount: chuong.fold(0, (a, c) => a + c.chunkCount),
      charCount: 0,
      expandNumbers: true,
    );

Chapter _chuong(int i, int dau, int so) =>
    Chapter(index: i, title: 'C$i', firstChunk: dau, chunkCount: so, charCount: 0);

void main() {
  group('đoạn trích quanh câu thoại có trần độ dài', () {
    // Laya cắt trạng thái Ở ĐUÔI khi quá dài, mà câu thoại nằm sau đoạn văn trong chuỗi: một đoạn
    // kể dài là đủ để câu thoại bị cắt mất mà Laya vẫn trả lời, và nhãn sai được lưu.
    final dai = 'Chữ rất dài. ' * 120; // ~1.560 ký tự
    final ds = [dai, dai, 'Fred nói:', '“Cái này mới là câu thoại cần hỏi.”', 'Harry gật đầu.'];

    test('quá dài thì vẫn giữ nguyên câu thoại và không vượt trần', () {
      final d = doanTrichQuanhThoai(ds, 3);
      expect(d, contains('“Cái này mới là câu thoại cần hỏi.”'));
      expect(d.length, lessThanOrEqualTo(toiDaKyTuDoanTrich));
      expect(d, contains('Fred nói:'), reason: 'dòng dẫn ngay trước câu thoại là bằng chứng quan trọng nhất');
    });

    test('đoạn dẫn ngay trước quá dài thì cắt ĐẦU của nó, câu thoại vẫn đủ', () {
      final d = doanTrichQuanhThoai([dai, '“Ngắn.”'], 1);
      expect(d.endsWith('“Ngắn.”'), isTrue);
      expect(d.length, lessThanOrEqualTo(toiDaKyTuDoanTrich));
    });

    test('đoạn ngắn thì giữ y nguyên như cũ: 3 đoạn trước, câu thoại, 1 đoạn sau', () {
      final ngan = ['a', 'b', 'c', 'd', '“e”', 'f', 'g'];
      expect(doanTrichQuanhThoai(ngan, 4), 'b\nc\nd\n“e”\nf');
      expect(doanTrichQuanhThoai(ngan, 0), '“a”'.replaceAll('“', '').replaceAll('”', '') + '\nb', reason: 'đầu sách không có đoạn trước');
    });
  });

  group('chỗ đang nghe sau khi cắt lại sách', () {
    test('giữ vị trí TƯƠNG ĐỐI TRONG CHƯƠNG, không theo tỉ lệ cả sách', () {
      // Cũ: chương 0 có 100 đoạn, chương 1 có 100 đoạn. Mới: chương 0 thành 160 đoạn (đã phân tích
      // theo nhân vật), chương 1 vẫn 100. Đang nghe đoạn 150 = giữa chương 1 (50/100).
      final cu = _sach([_chuong(0, 0, 100), _chuong(1, 100, 100)]);
      final moi = _sach([_chuong(0, 0, 160), _chuong(1, 160, 100)]);
      expect(chiSoSauKhiCatLai(cu, moi, 150), 160 + 50, reason: 'vẫn giữa chương 1');
      // Theo tỉ lệ toàn sách cũ sẽ là 150/200*260 = 195: lùi 15 đoạn.
      expect(chiSoSauKhiCatLai(cu, moi, 25), 40, reason: '25% chương 0 -> 25% của 160 đoạn');
    });

    test('không thấy chương tương ứng thì rơi về tỉ lệ toàn sách', () {
      final cu = _sach([_chuong(0, 0, 100), _chuong(1, 100, 100)]);
      final moi = _sach([_chuong(0, 0, 150)]); // chương 1 biến mất (đổi cài đặt dọn rác)
      expect(chiSoSauKhiCatLai(cu, moi, 150), 112);
    });

    test('sách rỗng hay chương rỗng không chia cho 0', () {
      final rong = _sach([]);
      expect(chiSoSauKhiCatLai(rong, _sach([_chuong(0, 0, 10)]), 0), 0);
      expect(chiSoSauKhiCatLai(_sach([_chuong(0, 0, 10)]), rong, 5), 0);
    });
  });

  test('nhanvat.json hỏng một khoá không làm cả file không đọc được', () {
    final nv = NhanVatSach.fromJson({
      'nhanVat': [
        {'ten': 'Fred', 'gioi': 'nam', 'soCau': 1},
      ],
      'nguoiNoi': {'abc:1': 'Fred', '2:5': 'Fred'},
    });
    expect(nv.chuongDaPhanTich, {2}, reason: 'khoá "abc:1" bị bỏ qua, không ném lỗi');
    nv.hopNhatChuong(KetQuaNhanVat([], {}), {2}); // cũng không ném lỗi với khoá hỏng
    expect(nv.nguoiNoi.containsKey('abc:1'), isTrue);
  });
}
