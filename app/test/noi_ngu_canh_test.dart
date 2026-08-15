/// Canh cờ [TtsEngine.noiNguCanh] của từng engine.
///
/// Cờ này quyết định `player_controller` đọc trước theo kiểu nào, và đặt sai thì
/// hỏng rất êm: không có lỗi, không có cảnh báo, chỉ là nghe tới đâu chờ tới đó.
///
/// Lỗi thật đã xảy ra: engine v2 không trả mã đuôi, nhưng `_prefetchAround` lại
/// chọn nhánh theo cài đặt `nguCanhNghe` của người dùng. Cài đặt bật thì v2 rơi
/// vào nhánh tuần tự, mà nhánh ấy thoát ngay vòng đầu vì `ngu.isEmpty` — thành
/// ra KHÔNG đoạn nào được đọc trước, mỗi lần chuyển đoạn phải chờ trọn 4–7 giây.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/models/settings.dart'
    show AppSettings, coEngineV2, defaultEngineId;
import 'package:sach_noi/services/tts/tts_manager.dart';

void main() {
  // SystemTtsEngine chạm vào plugin flutter_tts ngay trong hàm dựng, nên phải có
  // binding trước khi tạo TtsManager.
  TestWidgetsFlutterBinding.ensureInitialized();
  final tts = TtsManager();

  test('chỉ VieNeu v3 Turbo nối được ngữ cảnh', () {
    // v3 trả mã đuôi sau mỗi đoạn nên đoạn sau nối được vào đoạn trước.
    expect(tts.engine('vieneu').noiNguCanh, isTrue);

    // Các engine còn lại đều đọc từng đoạn độc lập. Chúng PHẢI khai false, không
    // thì mất hết việc đọc trước. (v2 chỉ có trên máy tính — xem [coEngineV2].)
    for (final id in [if (coEngineV2) 'vieneu_v2', 'piper', 'system']) {
      expect(tts.engine(id).noiNguCanh, isFalse, reason: 'engine $id');
    }
  });

  test('mặc định: đọc trước BẬT, soi âm TẮT', () {
    // Hai mặc định này ngược nhau có chủ ý và đáng canh:
    //
    // * Đọc trước bật vì không có nó thì mỗi lần chuyển đoạn phải chờ vài giây —
    //   đó là trải nghiệm mặc định tệ.
    // * Soi âm tắt vì nó ăn thẳng vào quỹ thời gian đọc trước, mà phần lớn đoạn
    //   đọc không hỏng.
    final s = AppSettings(engineId: defaultEngineId);
    expect(s.docTruocKhiNghe, isTrue);
    expect(s.soiAmKhiNghe, isFalse);
  });

  test('engine nào nối ngữ cảnh thì cũng phải đọc lại ra khác', () {
    // Không phải luật tự nhiên mà là ràng buộc của cách xuất file: bộ soi âm chỉ
    // đọc lại được khi engine đổi hạt giống ra bản khác. Engine nối ngữ cảnh mà
    // đọc lại y hệt thì đoạn hỏng sẽ hỏng mãi.
    for (final engine in tts.engines) {
      if (engine.noiNguCanh) {
        expect(engine.docLaiRaKhac, isTrue, reason: 'engine ${engine.id}');
      }
    }
  });
}
