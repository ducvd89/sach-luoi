/// Các ngưỡng kiểm âm không phụ thuộc mô hình hay hình dạng sóng.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/kiem_am.dart';

void main() {
  group('Ngưỡng đạt', () {
    test('câu một từ không thể đạt khi WAV im lặng', () {
      expect(const KetQuaKiemAm(soTu: 1, soAm: 0).dat, isFalse);
      expect(const KetQuaKiemAm(soTu: 0, soAm: 0).dat, isTrue);
      expect(const KetQuaKiemAm(soTu: 0, soAm: 3).dat, isFalse);
    });
    test('câu ngắn cũng dùng 100–110%, không còn ngoại lệ ±1 âm', () {
      for (var so = 1; so < 10; so++) {
        expect(KetQuaKiemAm(soTu: so, soAm: so).dat, isTrue);
        expect(KetQuaKiemAm(soTu: so, soAm: so - 1).dat, isFalse);
        expect(KetQuaKiemAm(soTu: so, soAm: so + 1).dat, isFalse);
      }
    });

    test('đạt từ đúng 100% tới đúng 110%, không làm tròn tỉ lệ', () {
      expect(const KetQuaKiemAm(soTu: 20, soAm: 19).dat, isFalse);
      expect(const KetQuaKiemAm(soTu: 20, soAm: 20).dat, isTrue);
      expect(const KetQuaKiemAm(soTu: 20, soAm: 22).dat, isTrue);
      expect(const KetQuaKiemAm(soTu: 20, soAm: 23).dat, isFalse);
      expect(const KetQuaKiemAm(soTu: 30, soAm: 33).dat, isTrue);
      expect(const KetQuaKiemAm(soTu: 11, soAm: 12).dat, isTrue);
      expect(const KetQuaKiemAm(soTu: 11, soAm: 13).dat, isFalse);
      expect(const KetQuaKiemAm(soTu: 201, soAm: 200).dat, isFalse);
      expect(const KetQuaKiemAm(soTu: 201, soAm: 222).dat, isFalse);
      expect(
        const KetQuaKiemAm(soTu: 40, soAm: 20).dat,
        isFalse,
        reason: 'nuốt mất nửa đoạn',
      );
      expect(
        const KetQuaKiemAm(soTu: 40, soAm: 60).dat,
        isFalse,
        reason: 'lặp lại không dừng',
      );
    });

    test('không đo được là chưa kiểm, không phải đạt', () {
      expect(const KetQuaKiemAm(soTu: 20, soAm: null).dat, isFalse);
      expect(
        const KetQuaKiemAm(soTu: 20, soAm: null).lech,
        double.infinity,
        reason: 'nhưng cũng không được chọn làm bản tốt nhất',
      );
    });

    test('chọn bản gần 100% nhất', () {
      const a = KetQuaKiemAm(soTu: 20, soAm: 14);
      const b = KetQuaKiemAm(soTu: 20, soAm: 18);
      const c = KetQuaKiemAm(soTu: 20, soAm: 25);
      expect(b.lech, lessThan(a.lech));
      expect(b.lech, lessThan(c.lech));
    });
  });
}
