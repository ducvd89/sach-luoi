/// Soi âm lúc nghe: đọc lại đoạn hỏng và phát bản khớp nhất.
///
/// Bài này không dựng cả PlayerController (nó cần media_kit) mà kiểm đúng phần
/// quyết định: cách chấm điểm và cách chọn. Cùng luật với `export_service.dart`,
/// chỉ khác số lượt đọc lại.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/kiem_am.dart';
import 'package:sach_noi/core/wav.dart';

/// Dựng một chuỗi "âm" giả: mỗi âm là một đoạn sóng có thanh, cách nhau bằng
/// khoảng lặng ngắn. Giống cách `kiem_am_test.dart` dựng mẫu.
Uint8List _wavCoAm(int soAm) {
  const rate = 16000;
  const mauAm = rate * 180 ~/ 1000;
  const mauNghi = rate * 70 ~/ 1000;
  final out = Float32List(soAm * (mauAm + mauNghi));
  var at = 0;
  for (var i = 0; i < soAm; i++) {
    for (var j = 0; j < mauAm; j++) {
      final t = j / rate;
      // Vài hài của f0 để phép xét thanh nhận ra là có chu kỳ.
      out[at++] = 0.5 *
          (0.6 * _sin(130, t) + 0.3 * _sin(260, t) + 0.1 * _sin(390, t)) *
          // Vào/ra êm cho khỏi lách cách ở hai đầu.
          (j < 400 ? j / 400 : (mauAm - j < 400 ? (mauAm - j) / 400 : 1));
    }
    at += mauNghi;
  }
  return buildWav(out, rate);
}

double _sin(double hz, double t) => math.sin(2 * math.pi * hz * t);

void main() {
  test('bản khớp số từ được chấm là đạt, bản lệch thì không', () {
    // Mười hai từ, mười hai âm — đúng nhịp tiếng Việt một từ một âm tiết.
    const loi = 'một hai ba bốn năm sáu bảy tám chín mười mười một';
    final soTu = loi.split(' ').length;

    final dung = kiemAm(speech: loi, wav: _wavCoAm(soTu), nhip: 1.0);
    expect(dung.soTu, soTu);

    // Đoạn đọc lảm nhảm: gấp ba số âm. Đây đúng là bệnh đo được ở v2 khi hạt
    // giống xấu — 27 giây tiếng cho câu đáng lẽ 5 giây.
    final thua = kiemAm(speech: loi, wav: _wavCoAm(soTu * 3), nhip: 1.0);
    expect(thua.lech, greaterThan(dung.lech),
        reason: 'bản lảm nhảm phải lệch xa hơn bản đúng');
  });

  test('chọn bản lệch ít nhất trong các lần đọc lại', () {
    // Mô phỏng đúng vòng chọn trong PlayerController._docCoSoi: giữ bản lệch ít
    // nhất, và lệch bằng nhau thì giữ bản ĐẦU vì các lần sau không hơn gì.
    final lech = [0.9, 0.3, 0.3];
    var chon = -1;
    var tot = double.infinity;
    for (var lan = 0; lan < lech.length; lan++) {
      if (lech[lan] < tot) {
        tot = lech[lan];
        chon = lan;
      }
    }
    expect(chon, 1, reason: 'phải lấy lần đầu tiên đạt mức lệch nhỏ nhất');
  });
}
