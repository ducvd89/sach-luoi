/// Tốc độ đọc của TTS hệ thống, và việc bỏ bản đã đệm khi cách đọc đổi.
///
/// Không gọi được `flutter_tts` thật trong `flutter test` (nó cần máy Android
/// hoặc iOS), nên bài này soi đúng hai thứ soi được mà không cần máy: phép quy
/// đổi tốc độ, và khoá bộ nhớ đệm.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:sach_noi/services/tts/system_tts_engine.dart';
import 'package:sach_noi/services/tts/tts_manager.dart';

/// Dải mà `flutter_tts` báo về trên Android — lấy từ chính mã nguồn plugin
/// (`getSpeechRateValidRange`: min 0, normal 0.5, max 1.5).
SpeechRateValidRange _daiAndroid() =>
    SpeechRateValidRange(0, 0.5, 1.5, TextToSpeechPlatform.android);

/// iOS đưa thẳng vào `AVSpeechUtterance.rate`, mặc định cũng 0,5.
SpeechRateValidRange _daiIos() => SpeechRateValidRange(0, 0.5, 1, TextToSpeechPlatform.ios);

void main() {
  group('Quy đổi tốc độ sang thang của flutter_tts', () {
    test('giọng bình thường KHÔNG phải setSpeechRate(1.0)', () {
      // Đây là cả cái lỗi: app tổng hợp ở tốc độ 1.0 rồi mới chỉnh tốc độ lúc
      // phát, nhưng truyền thẳng 1.0 xuống thì flutter_tts nhân đôi trước khi
      // đưa cho Android — máy đọc gấp đôi ngay từ lúc tổng hợp.
      expect(nhipHeThong(1.0, _daiAndroid()), 0.5);
      expect(nhipHeThong(1.0, _daiIos()), 0.5);
    });

    test('nhanh chậm vẫn theo đúng tỉ lệ', () {
      expect(nhipHeThong(0.5, _daiAndroid()), 0.25);
      expect(nhipHeThong(2.0, _daiAndroid()), 1.0);
    });

    test('không vượt ra ngoài dải nền tảng nhận', () {
      expect(nhipHeThong(9.0, _daiAndroid()), 1.5);
      expect(nhipHeThong(9.0, _daiIos()), 1.0);
      expect(nhipHeThong(-1, _daiAndroid()), 0);
    });

    test('hỏi không được dải thì vẫn lấy mức bình thường 0,5', () {
      // Cả Android lẫn iOS đều báo 0,5; hỏng lời gọi phụ không được kéo theo
      // việc đọc gấp đôi.
      expect(nhipHeThong(1.0, null), 0.5);
      expect(nhipHeThong(1.5, null), 0.75);
    });

    test('dải vô lý thì bỏ qua chứ không tin theo', () {
      final bay = SpeechRateValidRange(0, 0, 1, TextToSpeechPlatform.android);
      expect(nhipHeThong(1.0, bay), closeTo(0.5, 1e-9), reason: 'normal = 0 là câm hẳn');
    });
  });

  group('Đổi cách đọc thì phải bỏ bản đã đệm', () {
    test('engine system mang số hiệu mới', () {
      // Người đã nghe bằng TTS hệ thống có sẵn một đống WAV đọc gấp đôi trong
      // bộ nhớ đệm. Khoá cache chỉ gồm giọng/tốc độ/văn bản nên không tự đổi —
      // không tăng số hiệu thì sửa xong họ vẫn nghe y như cũ.
      expect(TtsManager.phienBanAm('system'), 2);
    });

    test('các engine khác không bị đụng tới', () {
      // Tăng nhầm là ném đi toàn bộ cache của engine chạy mô hình, mỗi đoạn
      // tổng hợp lại mất 5-7 giây.
      for (final id in ['vieneu', 'vieneu_v2', 'piper']) {
        expect(TtsManager.phienBanAm(id), 1, reason: id);
      }
    });
  });
}
