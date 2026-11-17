// Bộ cắt đoạn tách MỖI LỜI NÓI thành một đoạn riêng ngay từ lúc nhập (`manhCauThoai`), dù có đọc
// nhiều giọng hay không — nên phân tích nhân vật hay bật/tắt nhiều giọng chỉ đổi giọng, không cắt lại
// sách. Test canh: lời nói đứng riêng (cả lời nói nằm trong đoạn kể), mỗi đoạn lời nói mang đúng
// chỉ số "đoạn văn:câu thoại", lời dẫn vẫn gộp như trước, và đoạn văn không có lời nói cắt y như cũ.
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/chunker.dart';
import 'package:sach_noi/core/nhan_vat.dart';
import 'package:sach_noi/models/book.dart';

RawChapter _chuong(List<String> doanVan, {String tieuDe = 'Chương 1'}) =>
    RawChapter(tieuDe, doanVan.join('\n\n'));

List<Chunk> _than(ChunkResult kq) => kq.chunks.where((c) => !c.heading).toList();

void main() {
  test('lời thoại mỗi dòng (kiểu Harry Potter): mỗi lời nói một đoạn, lời dẫn gộp như cũ', () {
    final doan = [
      'Fred đưa một tay ra kéo Harry đứng lên, hồi hộp hỏi:',
      '“Nó có ăn không?”',
      'Harry đứng thẳng lên:',
      '“Có. Mà đó là cái gì vậy?”',
      'Cả hai nhìn nhau cười.',
      'Trời vẫn còn tối.',
    ];
    final c = _than(buildChunks([_chuong(doan)]));
    expect([for (final x in c) x.cau], ['', '1:0', '', '3:0', '']);
    expect(c[1].display, '“Nó có ăn không?”.');
    expect(c.last.display, contains('Cả hai nhìn nhau cười.'));
    expect(c.last.display, contains('Trời vẫn còn tối.'), reason: 'hai đoạn lời dẫn liền nhau vẫn gộp');
  });

  test('lời nói nằm TRONG đoạn kể (kiểu Lộc Đỉnh Ký) cũng thành đoạn riêng', () {
    const d = 'Đứa nhỏ hỏi: “Cha, họ phạm tội gì thế?”. Văn sĩ nói: “Có phạm tội gì đâu?”, rồi thở dài.';
    final c = _than(buildChunks([_chuong([d])]));
    expect([for (final x in c) (x.cau, x.display)], [
      ('', 'Đứa nhỏ hỏi.'),
      ('0:0', '“Cha, họ phạm tội gì thế?”.'),
      ('', 'Văn sĩ nói.'),
      ('0:1', '“Có phạm tội gì đâu?”.'),
      ('', 'rồi thở dài.'),
    ]);
  });

  test('câu trong ngoặc không phải lời nói (tiếng động, tên chiêu) ở lại trong lời dẫn', () {
    const d = 'Cái bầu rượu đập vào cánh tay y “chát” một tiếng, y dùng chiêu “Hồi phong phất liễu” chém ra.';
    final c = _than(buildChunks([_chuong([d])]));
    expect(c, hasLength(1));
    expect(c.single.cau, '');
  });

  test('đoạn văn không có lời nói cắt y như trước: không đoạn nào có câu thoại', () {
    final kq = buildChunks([_chuong(['Một.', 'Hai.', 'Ba.'])]);
    expect(kq.chunks.every((c) => c.cau.isEmpty), isTrue);
    expect(_than(kq), hasLength(1), reason: 'ba đoạn văn ngắn vẫn gộp làm một');
  });

  test('tiêu đề chương luôn là lời dẫn', () {
    final kq = buildChunks([_chuong(['“Đi thôi.”'])]);
    expect(kq.chunks.first.heading, isTrue);
    expect(kq.chunks.first.cau, '');
  });

  test('người nói tra lúc phát từ nhãn: khoá ba phần, khoá hai phần của 2.1.0, và đoạn cắt bằng 2.1.0', () {
    const c = Chunk(index: 0, chapter: 2, display: 'x', speech: 'x', heading: false, cau: '5:1');
    expect(nguoiNoiCuaDoan({'2:5:1': 'Fred'}, c), 'Fred');
    expect(nguoiNoiCuaDoan({'2:5': 'Harry'}, c), 'Harry', reason: 'khoá cũ áp cho mọi câu của đoạn văn');
    expect(nguoiNoiCuaDoan({'2:5:0': 'Fred'}, c), '');
    const cu = Chunk(index: 0, chapter: 2, display: 'x', speech: 'x', heading: false, speaker: 'Ron');
    expect(nguoiNoiCuaDoan(const {}, cu), 'Ron', reason: 'đoạn cắt bằng 2.1.0 ghi thẳng người nói');
  });

  test('Chunk lưu và đọc lại chỉ số câu thoại; sách cũ không có trường này vẫn đọc được', () {
    const c = Chunk(index: 3, chapter: 0, display: 'x', speech: 'x', heading: false, cau: '4:0');
    expect(Chunk.fromJson(c.toJson()).cau, '4:0');
    const rong = Chunk(index: 3, chapter: 0, display: 'x', speech: 'x', heading: false);
    expect(rong.toJson().containsKey('q'), isFalse);
    expect(Chunk.fromJson({'i': 1, 'c': 0, 'd': 'a', 's': 'a'}).cau, '');
  });

  test('doanVanCuaChuong đếm đoạn văn đúng như bộ cắt đoạn (bỏ đoạn rỗng và tiêu đề lặp)', () {
    final raw = RawChapter('Chương 1', 'Chương 1\n\n\n\nMột.\n\n   \n\nHai.\n\n“Ba.”');
    expect(doanVanCuaChuong(raw), ['Một.', 'Hai.', '“Ba.”']);
    final ba = buildChunks([raw]).chunks.where((c) => c.cau.isNotEmpty).single;
    expect(ba.cau, '2:0');
  });
}
