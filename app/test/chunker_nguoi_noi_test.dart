// Bộ cắt đoạn biết người nói: mỗi Chunk đúng một người, và không gộp qua ranh giới người nói.
//
// Bản gốc gộp các đoạn văn ngắn liền nhau cho tới khi đủ dài (truyện convert từ web hay bọc
// MỖI câu thoại vào một <p>), nên một Chunk có thể chứa lời dẫn lẫn câu thoại của nhiều người —
// không thể gán một giọng cho nó. Test này canh hai điều: người nói đổi thì chunk phải chốt, và
// không truyền `nguoiNoi` thì kết quả y hệt trước đây (sách đã nhập không đổi).
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/chunker.dart';
import 'package:sach_noi/models/book.dart';

RawChapter _chuong(List<String> doanVan, {String tieuDe = 'Chương 1'}) =>
    RawChapter(tieuDe, doanVan.join('\n\n'));

void main() {
  final doan = [
    'Fred đưa một tay ra kéo Harry đứng lên, hồi hộp hỏi:',
    '“Nó có ăn không?”',
    'Harry đứng thẳng lên:',
    '“Có. Mà đó là cái gì vậy?”',
    'Cả hai nhìn nhau cười.',
    'Trời vẫn còn tối.',
  ];
  // 0 dẫn, 1 Fred, 2 dẫn, 3 Harry, 4 dẫn, 5 dẫn
  String nguoi(int chuong, int doanVan) => switch (doanVan) {
        1 => 'Fred',
        3 => 'Harry',
        _ => '',
      };

  test('mỗi Chunk một người nói và câu thoại không bị gộp với lời dẫn', () {
    final kq = buildChunks([_chuong(doan)], nguoiNoi: nguoi);
    final noi = [for (final c in kq.chunks.where((c) => !c.heading)) (c.speaker, c.display)];
    expect(noi.map((e) => e.$1).toList(), ['', 'Fred', '', 'Harry', '']);
    // hai đoạn dẫn cuối cùng một người (người dẫn) nên được gộp như cũ
    expect(noi.last.$2, contains('Cả hai nhìn nhau cười.'));
    expect(noi.last.$2, contains('Trời vẫn còn tối.'));
    // câu thoại đứng riêng
    expect(noi[1].$2, startsWith('“Nó có ăn không?”'));
    expect(noi[1].$2, isNot(contains('Harry đứng')));
  });

  test('tiêu đề chương luôn là người dẫn', () {
    final kq = buildChunks([_chuong(doan)], nguoiNoi: (c, d) => 'Fred');
    expect(kq.chunks.first.heading, isTrue);
    expect(kq.chunks.first.speaker, '');
  });

  test('không truyền nguoiNoi thì y hệt trước đây: không ai có người nói và đoạn ngắn vẫn gộp', () {
    final a = buildChunks([_chuong(doan)]);
    expect(a.chunks.every((c) => c.speaker.isEmpty), isTrue);
    final b = buildChunks([_chuong(doan)], nguoiNoi: (c, d) => '');
    expect([for (final c in a.chunks) c.display], [for (final c in b.chunks) c.display]);
    // cả năm đoạn văn ngắn gộp lại, chỉ còn tiêu đề + một đoạn thân
    expect(a.chunks.length, lessThan(doan.length));
  });

  test('doanVanCuaChuong đếm đoạn văn đúng như bộ cắt đoạn (bỏ đoạn rỗng và tiêu đề lặp)', () {
    final raw = RawChapter('Chương 1', 'Chương 1\n\n\n\nMột.\n\n   \n\nHai.\n\nBa.');
    final ds = doanVanCuaChuong(raw);
    expect(ds, ['Một.', 'Hai.', 'Ba.']);
    // chỉ số 2 phải là "Ba." trong cả hai bên: gắn người nói cho nó rồi xem chunk
    final kq = buildChunks([raw], nguoiNoi: (c, d) => d == 2 ? 'Ba' : '');
    final ba = kq.chunks.where((c) => c.speaker == 'Ba').toList();
    expect(ba, hasLength(1));
    expect(ba.single.display, 'Ba.');
  });

  test('Chunk lưu và đọc lại người nói; sách cũ không có trường này vẫn đọc được', () {
    const c = Chunk(index: 3, chapter: 0, display: 'x', speech: 'x', heading: false, speaker: 'Fred');
    expect(Chunk.fromJson(c.toJson()).speaker, 'Fred');
    expect(c.toJson()['v'], 'Fred');
    const rong = Chunk(index: 3, chapter: 0, display: 'x', speech: 'x', heading: false);
    expect(rong.toJson().containsKey('v'), isFalse, reason: 'sách không phân tích thì file chunks.json không đổi');
    expect(Chunk.fromJson({'i': 1, 'c': 0, 'd': 'a', 's': 'a'}).speaker, '');
  });
}
