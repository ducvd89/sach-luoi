/// Tua tới đúng đoạn đang được đọc trước.
///
/// Đây là ca hỏng thật đã gặp: lệnh huỷ (thêm vào để tua cho nhanh) giết luôn
/// lượt đọc trước của chính đoạn người dùng vừa chọn. `TtsManager` gom các yêu
/// cầu trùng khoá, nên lời xin của trình phát nhận lại đúng cái future vừa bị
/// giết — đoạn được chọn hỏng, trình phát nhảy sang đoạn kế.
///
/// Bài này canh phần quyết định: nhận ra được lỗi huỷ, và bảng gom yêu cầu nhả
/// khoá ra sau khi hỏng để lần xin lại tạo được lượt đọc mới.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/services/tts/tts_engine.dart';

void main() {
  group('nhận ra lỗi huỷ', () {
    test('đúng chuỗi Rust gửi sang', () {
      expect(laLoiHuy(TtsException('đã huỷ để nhường cho đoạn khác')), isTrue);
    });

    test('lỗi thường thì không nhận nhầm', () {
      expect(laLoiHuy(TtsException('không mở được mô hình')), isFalse);
      expect(laLoiHuy(Exception('hết bộ nhớ')), isFalse);
    });

    test('dấu nhận biết phải khớp với bản Rust', () {
      // Đổi chuỗi bên `native/vieneu/src/v2.rs` mà quên đổi ở đây thì việc xin
      // lại im lặng ngừng hoạt động: đoạn được chọn hỏng mà không ai biết vì
      // sao. Ghim lại đúng nguyên văn.
      expect(loiHuyDoc, 'đã huỷ để nhường cho đoạn khác');
    });
  });

  test('xin lại sau khi bị huỷ thì phải ra lượt đọc MỚI', () async {
    // Dựng lại đúng cách TtsManager gom yêu cầu: trùng khoá thì dùng chung
    // future, và nhả khoá khi future kết thúc — kể cả khi kết thúc bằng lỗi.
    final inflight = <String, Future<String>>{};
    var soLanChay = 0;

    Future<String> xin(String khoa, {required bool huy}) {
      final dangCo = inflight[khoa];
      if (dangCo != null) return dangCo;
      final f = Future<String>(() async {
        soLanChay++;
        if (huy) throw TtsException(loiHuyDoc);
        return 'âm thanh';
        // Thân hàm phải là CÂU LỆNH, không phải biểu thức: `Map.remove` trả về
        // chính future đang lưu, mà `whenComplete` lại chờ giá trị trả về nếu
        // đó là Future — thành ra future tự chờ chính nó và treo mãi mãi. Đúng
        // cái bẫy đã ghi trong `tts_manager.dart`, và viết bài test này tao lại
        // dẫm vào lần nữa.
      }).whenComplete(() {
        inflight.remove(khoa);
      });
      inflight[khoa] = f;
      return f;
    }

    // Lượt đọc trước, rồi bị huỷ.
    await expectLater(xin('doan-5', huy: true), throwsA(isA<TtsException>()));

    // Xin lại: bảng gom đã nhả khoá nên phải chạy một lượt MỚI, không dính lại
    // cái đã hỏng.
    expect(await xin('doan-5', huy: false), 'âm thanh');
    expect(soLanChay, 2, reason: 'lần xin sau phải tạo lượt đọc mới');
  });
}
