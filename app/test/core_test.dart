/// Kiểm thử các phần logic thuần: đọc số, chuẩn hoá văn bản, cắt đoạn, WAV.
///
/// Đây là những chỗ dễ sai âm thầm nhất — sai một quy tắc đọc số thì cả cuốn
/// sách đọc lệch mà không có gì báo lỗi.
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/chunker.dart';
import 'package:sach_noi/core/text_normalizer.dart';
import 'package:sach_noi/core/vi_number.dart';
import 'package:sach_noi/core/wav.dart';
import 'package:sach_noi/models/book.dart';
import 'package:sach_noi/models/settings.dart';
import 'package:sach_noi/services/export_service.dart';

void main() {
  _testTenFileXuat();
  group('Đọc số tiếng Việt', () {
    test('các trường hợp cơ bản', () {
      expect(readInteger('0'), 'không');
      expect(readInteger('15'), 'mười lăm');
      expect(readInteger('21'), 'hai mươi mốt');
      expect(readInteger('24'), 'hai mươi tư');
      expect(readInteger('101'), 'một trăm linh một');
      expect(readInteger('1000'), 'một nghìn');
      expect(readInteger('1975'), 'một nghìn chín trăm bảy mươi lăm');
      expect(readInteger('1000000'), 'một triệu');
    });

    test('số thập phân và số La Mã', () {
      expect(readDecimal('3', '25'), 'ba phẩy hai năm');
      expect(romanToNumber('IV'), 4);
      expect(romanToNumber('XX'), 20);
      expect(romanToNumber('abc'), isNull);
    });
  });

  group('Chuẩn hoá văn bản', () {
    test('số, ngày tháng, giờ', () {
      expect(normalizeForSpeech('Năm 1975'), contains('một nghìn chín trăm bảy mươi lăm'));
      expect(normalizeForSpeech('ngày 20/11/1954'), startsWith('ngày hai mươi tháng mười một năm'));
      expect(normalizeForSpeech('lúc 10:30'), contains('mười giờ ba mươi'));
      expect(normalizeForSpeech('1.234.567'), contains('một triệu hai trăm ba mươi tư nghìn'));
    });

    test('viết tắt và đơn vị', () {
      expect(normalizeForSpeech('PGS.TS Nguyễn'), startsWith('Phó giáo sư tiến sĩ'));
      expect(normalizeForSpeech('NXB Trẻ'), startsWith('Nhà xuất bản'));
      expect(normalizeForSpeech('35°C'), contains('độ C'));
      expect(normalizeForSpeech('giá 250.000đ'), contains('đồng'));
      expect(normalizeForSpeech('Chương IV'), 'Chương bốn');
    });

    test('số mục La Mã có dấu chấm đọc thành số', () {
      expect(normalizeForSpeech('VI. Kết luận'), 'sáu. Kết luận');
      expect(normalizeForSpeech('Hết phần trước. III. Mở rộng'), endsWith('ba. Mở rộng'));
      expect(normalizeForSpeech('I. Mở đầu'), 'một. Mở đầu');
      expect(normalizeForSpeech('II.', expandNumbers: false), '2.');
    });

    test('cụm La Mã không có dấu chấm hoặc là viết tắt thì giữ nguyên', () {
      expect(normalizeForSpeech('Chủng VI gây bệnh'), 'Chủng VI gây bệnh');
      expect(normalizeForSpeech('con vi khuẩn'), 'con vi khuẩn');
      expect(normalizeForSpeech('Anh ấy mua đĩa CD. Sau đó về.'), 'Anh ấy mua đĩa CD. Sau đó về.');
      expect(normalizeForSpeech('Cô ấy làm MC. Rất giỏi.'), 'Cô ấy làm MC. Rất giỏi.');
      expect(normalizeForSpeech('V. I. Lênin viết'), 'V. I. Lênin viết');
      expect(normalizeForSpeech('C. Mác và Ph. Ăng-ghen'), startsWith('C. Mác'));
    });

    test('tắt chuẩn hoá số thì giữ nguyên chữ số', () {
      expect(normalizeForSpeech('Năm 1975', expandNumbers: false), contains('1975'));
    });
  });

  group('Cắt đoạn', () {
    test('tách câu đúng chỗ', () {
      final sentences = splitSentences('Ông A. Nguyễn đến. Anh ấy nói: "Chào!" Số 3.5 là kết quả.');
      expect(sentences.length, 3);
      expect(sentences.last, 'Số 3.5 là kết quả.');
    });

    test('tiêu đề chương thành đoạn riêng và không bị lặp', () {
      final result = buildChunks([
        const RawChapter('Chương 1: Mở đầu', 'Chương 1: Mở đầu\n\nNgày xửa ngày xưa có một cô bé.'),
      ]);
      expect(result.chunks.first.heading, isTrue);
      expect(result.chunks.length, 2);
      expect(result.chunks[1].display, isNot(contains('Mở đầu')));
    });

    test('đoạn không vượt quá kích thước tối đa', () {
      final long = 'Đây là một câu văn khá dài để kiểm tra việc cắt đoạn. ' * 40;
      final result = buildChunks([RawChapter('Chương 1', long)]);
      for (final chunk in result.chunks) {
        // +1 vì _ensureTerminal có thể thêm một dấu chấm vào cuối.
        expect(chunk.display.length, lessThanOrEqualTo(chunkMaxChars + 1));
      }
    });

    test('nhiều đoạn văn ngắn liên tiếp được gộp lại thay vì vỡ vụn từng câu', () {
      // Nhiều truyện convert từ web bọc MỖI CÂU thoại vào một đoạn/thẻ <p>
      // riêng (xem epub_parser.dart) — ba đoạn "câu" ngắn dưới đây tổng cộng
      // chưa tới ngưỡng 60% mục tiêu nên phải gộp thành một chunk, không được
      // để mỗi cái đứng riêng một mình.
      final result = buildChunks([
        RawChapter('', 'Ừ.\n\nKhông sao đâu.\n\nCô ấy đi rồi.'),
      ]);
      expect(result.chunks.length, 1);
      expect(result.chunks.single.speech, 'Ừ. Không sao đâu. Cô ấy đi rồi.');
    });

    test('đoạn văn đã đủ dài thì chốt riêng, không kéo đoạn kế ngắn vào', () {
      // Đoạn văn A vượt 60% mục tiêu nhưng vẫn dưới targetChars (không cần tự
      // chia nhỏ) phải chốt thành chunk của riêng nó ngay khi vừa xong — không
      // đợi gộp thêm đoạn B ngắn phía sau.
      const sentence = 'Đây là một câu để kiểm tra độ dài của đoạn văn thứ nhất.';
      var paragraphA = sentence;
      while (paragraphA.length + 1 + sentence.length <= chunkTargetChars) {
        paragraphA = '$paragraphA $sentence';
      }
      expect(paragraphA.length, greaterThanOrEqualTo((chunkTargetChars * 0.6).ceil()));
      expect(paragraphA.length, lessThanOrEqualTo(chunkTargetChars));
      final result = buildChunks([
        RawChapter('', '$paragraphA\n\nNgắn thôi.'),
      ]);
      expect(result.chunks.length, 2);
      expect(result.chunks[0].display, paragraphA);
      expect(result.chunks[1].display, 'Ngắn thôi.');
    });

    test('mẩu cuối của một đoạn văn bị chia nhỏ mà quá ngắn thì gộp vào mẩu liền trước', () {
      // Một câu DÀI (không dấu câu giữa chừng, nên splitSentences coi là một
      // câu duy nhất) áp sát targetChars, rồi một câu ĐUÔI rất ngắn. Câu đầu
      // một mình chưa tràn nên chưa chốt, nhưng cộng thêm câu đuôi thì tràn —
      // bị tách thành mẩu riêng. Câu đuôi dưới ngưỡng gộp nên phải nhập lại
      // vào mẩu trước, ra đúng MỘT chunk chứ không phải hai (to + tí hon).
      const word = 'con mèo nhỏ ';
      var big = '';
      while (big.length < chunkTargetChars) {
        big += word;
      }
      final bigSentence = '${big.trim()}.';
      const tail = 'Ngắn thôi.';
      // Câu đầu một mình đã đủ (hoặc hơn) targetChars, nhưng vì buffer BẮT ĐẦU
      // rỗng nên nó luôn được nhận không điều kiện — chỉ câu ĐUÔI đến sau mới
      // kích hoạt việc kiểm tra tràn.
      expect(bigSentence.length, greaterThanOrEqualTo(chunkTargetChars));
      // Và cả hai cộng lại vẫn dưới trần cứng — đó là điều kiện để được gộp.
      expect(bigSentence.length + 1 + tail.length, lessThanOrEqualTo(chunkMaxChars));

      final paragraph = '$bigSentence $tail';
      final result = buildChunks([RawChapter('', paragraph)]);
      expect(result.chunks.length, 1);
      expect(result.chunks.single.display, paragraph);
    });

    test('gộp mẩu cuối phải nhường trần cứng: quá trần thì để riêng', () {
      // Cùng tình huống trên nhưng câu đầu đã sát trần. Gộp thêm cái đuôi vào
      // là vượt sức mô hình (xem chunkMaxChars) nên thà để nó đứng riêng.
      const word = 'con mèo nhỏ ';
      var big = '';
      while (big.length < chunkMaxChars - 12) {
        big += word;
      }
      final bigSentence = '${big.trim()}.';
      const tail = 'Ngắn thôi.';
      expect(bigSentence.length + 1 + tail.length, greaterThan(chunkMaxChars));

      final result = buildChunks([RawChapter('', '$bigSentence $tail')]);
      expect(result.chunks.length, 2);
      for (final chunk in result.chunks) {
        expect(chunk.display.length, lessThanOrEqualTo(chunkMaxChars + 1));
      }
    });

    test('ưu tiên cắt ở cuối câu, không xé câu còn vừa vặn', () {
      // Mỗi câu đều thừa sức nằm dưới trần và kết thúc bằng '!'. Nếu bộ cắt tôn
      // trọng ranh giới câu thì MỌI đoạn đều kết thúc bằng '!'. Còn nếu nó xé
      // câu tại dấu phẩy thì mẩu ấy kết thúc bằng '.' — _ensureTerminal đổi dấu
      // phẩy dở dang thành dấu chấm — nên chỉ cần nhìn dấu cuối là biết.
      const cau = 'Con mèo ngồi trên nóc tủ, nhìn ra ngoài cửa sổ, rồi ngủ thiếp đi!';
      expect(cau.length, lessThan(chunkMaxChars));
      final result = buildChunks([RawChapter('', List.filled(9, cau).join(' '))]);

      expect(result.chunks.length, greaterThan(1));
      for (final chunk in result.chunks) {
        expect(chunk.display, endsWith('!'));
      }
    });

    test('câu quá dài chia tại dấu phẩy thành ít mẩu nhất và đều nhau', () {
      // Một câu một mạch, chỉ ngăn bằng dấu phẩy, dài gấp mấy lần trần. Đây là
      // ca đã làm mô hình đọc hỏng: cách xếp tham lam cũ cho ra mẩu đầu sát
      // trần rồi mẩu đuôi tí hon.
      const ve = 'con mèo ngồi trên nóc tủ nhìn ra ngoài cửa sổ';
      var cau = ve;
      while (cau.length < chunkMaxChars * 3) {
        cau = '$cau, $ve';
      }
      cau = '$cau.';

      final result = buildChunks([RawChapter('', cau)]);
      final dai = result.chunks.map((c) => c.display.length).toList();

      // Không mẩu nào vượt trần (+1 cho dấu chấm mà _ensureTerminal thêm vào).
      for (final n in dai) {
        expect(n, lessThanOrEqualTo(chunkMaxChars + 1));
      }
      // Ít mẩu nhất có thể: bớt đi một mẩu là không còn đủ chỗ cho cả câu.
      expect((dai.length - 1) * chunkMaxChars, lessThan(cau.length));
      // Đều nhau: mẩu ngắn nhất không thua mẩu dài nhất quá một phần tư.
      expect(dai.reduce(min) / dai.reduce(max), greaterThan(0.75));
    });

    test('phần đọc cũng phải dưới trần dù chuẩn hoá làm văn bản nở ra', () {
      // Trần áp cho phần hiển thị, nhưng thứ mô hình đọc là phần speech đã
      // chuẩn hoá — mà "1.234.567" chín ký tự nở thành hơn năm mươi. Đoạn đầy
      // số vì thế vượt trần ở phần đọc dù phần hiển thị vẫn gọn.
      final cau = List.filled(12, 'Năm 1.234.567 có 89,5% vào 20/11/1954').join(', ');
      final result = buildChunks([RawChapter('', '$cau.')]);

      expect(result.chunks, isNotEmpty);
      // Chính là ca mà phép kiểm trên phần hiển thị bỏ lọt.
      expect(result.chunks.map((c) => c.speech.length).reduce(max),
          greaterThan(result.chunks.map((c) => c.display.length).reduce(max)));
      for (final chunk in result.chunks) {
        expect(chunk.speech.length, lessThanOrEqualTo(chunkMaxChars));
      }
    });

    test('đoạn văn gốc không có dấu kết thì được thêm dấu chấm', () {
      // Sách cào từ web hay thiếu hẳn dấu câu ở cuối đoạn (splitSentences trả
      // phần đuôi này nguyên trạng, không dấu). Mô hình sinh giọng dựa vào dấu
      // câu để biết khi nào dừng — thiếu nó dễ thành đọc dở dang.
      final result = buildChunks([
        RawChapter('', 'Hôm nay trời đẹp'),
      ]);
      expect(result.chunks.single.display, 'Hôm nay trời đẹp.');
    });

    test('mẩu bị cắt tại dấu phẩy khi câu quá dài thì đổi thành dấu chấm, không để lửng dấu phẩy', () {
      // Một câu dài phải chia làm nhiều mẩu tại dấu phẩy (_splitLongSentence).
      // Mẩu ĐẦU khi đứng thành chunk riêng đang kết thúc bằng dấu phẩy dở dang
      // — phải đổi thành dấu chấm, không được vừa có phẩy vừa thêm chấm.
      const word = 'con mèo ngồi trên nóc tủ nhìn ra ngoài cửa sổ';
      var clause = word;
      while (clause.length < chunkTargetChars) {
        clause = '$clause, $word';
      }
      final sentence = '$clause, và cứ thế tiếp tục mãi cho đến hết câu văn này.';
      final result = buildChunks([RawChapter('', sentence)]);

      expect(result.chunks, isNotEmpty);
      for (final chunk in result.chunks) {
        expect(chunk.display, isNot(endsWith(',')));
        expect(chunk.display, matches(RegExp(r'[.!?;…]["\)\]»]*$')));
      }
    });
  });

  group('Khoảng nghỉ giữa đoạn', () {
    test('tiêu đề nghỉ lâu hơn đoạn thường', () {
      final thuong = pauseAfterChunk(heading: false, pauseMs: 500);
      final tieuDe = pauseAfterChunk(heading: true, pauseMs: 500);
      expect(thuong.inMilliseconds, 500);
      expect(tieuDe.inMilliseconds, greaterThan(thuong.inMilliseconds));
    });

    test('đặt 0 thì không nghỉ', () {
      expect(pauseAfterChunk(heading: false, pauseMs: 0), Duration.zero);
      expect(pauseAfterChunk(heading: true, pauseMs: 0), Duration.zero);
    });
  });

  group('WAV', () {
    test('dựng file rồi đọc lại ra đúng thông số', () {
      final samples = Float32List(22050); // đúng 1 giây
      for (var i = 0; i < samples.length; i++) {
        samples[i] = i.isEven ? 0.5 : -0.5;
      }

      final wav = buildWav(samples, 22050);
      final info = readWavInfo(wav);
      expect(info, isNotNull);
      expect(info!.sampleRate, 22050);
      expect(info.channels, 1);
      expect(info.bitsPerSample, 16);
      expect(info.seconds, closeTo(1.0, 0.001));
      expect(wavDuration(wav), closeTo(1.0, 0.001));
      expect(wavPcm(wav).length, samples.length * 2);
    });

    test('ghép hai đoạn bằng cách nối phần dữ liệu rồi dựng lại phần đầu', () {
      final first = buildWav(Float32List(11025), 22050); // 0,5 giây
      final second = buildWav(Float32List(11025), 22050);

      final pcm = <int>[...wavPcm(first), ...wavPcm(second)];
      final joined = Uint8List.fromList([...wavHeader(pcm.length, 22050), ...pcm]);

      expect(wavDuration(joined), closeTo(1.0, 0.001));
    });

    test('không phải WAV thì trả về null', () {
      expect(readWavInfo(Uint8List.fromList([1, 2, 3, 4])), isNull);
      expect(wavDuration(Uint8List(0)), 0);
    });

    test('ghép khoảng lặng vào đầu: dài ra đúng, phần lặng thật sự im, đuôi giữ nguyên', () {
      final samples = Float32List(22050); // 1 giây, đủ to để phân biệt với lặng
      for (var i = 0; i < samples.length; i++) {
        samples[i] = i.isEven ? 0.5 : -0.5;
      }
      final goc = buildWav(samples, 22050);

      final ghep = wavWithLeadingSilence(goc, 200); // 200 ms lặng
      final info = readWavInfo(ghep);
      expect(info, isNotNull);
      expect(wavDuration(ghep), closeTo(1.2, 0.001), reason: '1s gốc + 0,2s lặng');

      final pcm = wavPcm(ghep);
      // 200 ms đầu ở 22050 Hz, 16-bit mono = 8820 byte, phải toàn số 0.
      final dauLang = pcm.sublist(0, 8820);
      expect(dauLang.every((b) => b == 0), isTrue, reason: 'phần ghép vào phải là im lặng thật');
      // Phần còn lại phải đúng dữ liệu gốc, không bị xê dịch hay cắt mất.
      expect(pcm.sublist(8820), wavPcm(goc));
    });

    test('ghép khoảng lặng: không dương hoặc không phải WAV thì trả nguyên input', () {
      final goc = buildWav(Float32List(100), 22050);
      final khongLang = wavWithLeadingSilence(goc, 0);
      expect(identical(khongLang, goc), isTrue);

      final khongPhaiWav = Uint8List.fromList([1, 2, 3, 4]);
      expect(identical(wavWithLeadingSilence(khongPhaiWav, 200), khongPhaiWav), isTrue);
    });

    test('cân bằng âm lượng chỉ hạ đỉnh xuống, không đẩy lên', () {
      final loud = Float32List.fromList([1.0, -1.0, 0.5]);
      expect(normalizePeak(loud).reduce((a, b) => a.abs() > b.abs() ? a : b).abs(), closeTo(0.84, 0.001));

      final quiet = Float32List.fromList([0.1, -0.2]);
      expect(normalizePeak(quiet), quiet);
    });
  });

  group('Khoảng nghỉ giữa các đoạn', () {
    test('chưa từng kéo thanh trượt thì được nâng lên mức mới', () {
      // 550 là mặc định của bản trước — nhỏ hơn cả nhịp nghỉ dài nhất mà mô
      // hình tự sinh ra giữa hai câu (0,50 s), nên nghe như dính liền.
      final cu = AppSettings.fromJson({'chunkPauseMs': 550});
      expect(cu.chunkPauseMs, defaultChunkPauseMs);
      expect(defaultChunkPauseMs, greaterThan(550));
    });

    test('người dùng tự chọn con số khác thì giữ nguyên', () {
      expect(AppSettings.fromJson({'chunkPauseMs': 0}).chunkPauseMs, 0);
      expect(AppSettings.fromJson({'chunkPauseMs': 300}).chunkPauseMs, 300);
      expect(AppSettings.fromJson({'chunkPauseMs': 1800}).chunkPauseMs, 1800);
    });

    test('giá trị vô lý bị kẹp lại, thiếu thì lấy mặc định', () {
      expect(AppSettings.fromJson({'chunkPauseMs': 99999}).chunkPauseMs, 3000);
      expect(AppSettings.fromJson({'chunkPauseMs': -5}).chunkPauseMs, 0);
      expect(AppSettings.fromJson(<String, dynamic>{}).chunkPauseMs, defaultChunkPauseMs);
    });

    test('tiêu đề chương nghỉ lâu hơn đoạn thường', () {
      final doan = pauseAfterChunk(heading: false, pauseMs: defaultChunkPauseMs);
      final tieuDe = pauseAfterChunk(heading: true, pauseMs: defaultChunkPauseMs);
      expect(tieuDe, greaterThan(doan));
      // Phải vượt hẳn dải nghỉ tự nhiên của mô hình (dài nhất đo được 0,50 s),
      // không thì hết đoạn nghe giống hết câu.
      expect(doan.inMilliseconds, greaterThan(700));
      expect(pauseAfterChunk(heading: false, pauseMs: 0), Duration.zero);
    });
  });

  group('Nghe và Xuất file đặt riêng', () {
    test('giọng, ngữ cảnh và tốc độ giữ được hai giá trị khác nhau', () {
      final dat = AppSettings(
        voiceNghe: 'Thái Sơn',
        voiceXuat: 'Ngọc Linh',
        nguCanhNghe: NguCanh.tuanTu,
        nguCanhXuat: NguCanh.khong,
        speed: 1.5,
        speedXuat: 0.9,
      );
      final lai = AppSettings.fromJson(dat.toJson());
      expect(lai.voiceNghe, 'Thái Sơn');
      expect(lai.voiceXuat, 'Ngọc Linh');
      expect(lai.nguCanhNghe, NguCanh.tuanTu);
      expect(lai.nguCanhXuat, NguCanh.khong);
      expect(lai.speed, 1.5);
      expect(lai.speedXuat, 0.9);
    });

    test('cài đặt cũ chỉ có một con số tốc độ thì phần xuất giữ đúng số ấy', () {
      // Bản trước dùng chung `speed` cho cả nghe lẫn xuất. Ai đang quen xuất ở
      // 1.25 thì phải tiếp tục ở 1.25, không được lặng lẽ kéo về 1.0.
      final lai = AppSettings.fromJson({'speed': 1.25});
      expect(lai.speedXuat, 1.25);
      expect(lai.speed, 1.25);
    });
  });
}

void _testTenFileXuat() {
  group('Đặt tên file xuất ra', () {
    String ten({
      int dau = 7,
      int cuoi = 7,
      int lonNhat = 638,
      int file = 2,
      String truyen = 'Phàm Nhân Tu Tiên',
    }) =>
        tenFileXuat(
          bookTitle: truyen,
          chuongDau: dau,
          chuongCuoi: cuoi,
          soChuongLonNhat: lonNhat,
          soThuTuFile: file,
        );

    test('đệm 0 cho đủ số chữ số của chương lớn nhất', () {
      expect(ten(dau: 7, cuoi: 7, lonNhat: 638), 'Phàm Nhân Tu Tiên - 007 - 002');
      expect(ten(dau: 7, cuoi: 7, lonNhat: 9), 'Phàm Nhân Tu Tiên - 7 - 002');
      expect(ten(dau: 7, cuoi: 7, lonNhat: 1200), 'Phàm Nhân Tu Tiên - 0007 - 002');
    });

    test('file gộp nhiều chương thì ghi khoảng, cùng quy tắc đệm', () {
      expect(ten(dau: 7, cuoi: 9, lonNhat: 638), 'Phàm Nhân Tu Tiên - 007-009 - 002');
      expect(ten(dau: 1, cuoi: 120, lonNhat: 1200), 'Phàm Nhân Tu Tiên - 0001-0120 - 002');
    });

    test('một chương một file thì chỉ ghi một số', () {
      expect(ten(dau: 42, cuoi: 42, lonNhat: 638).contains('-042'), isFalse);
    });

    test('sắp theo tên là ra đúng thứ tự nghe', () {
      final danh = [
        ten(dau: 100, cuoi: 100, lonNhat: 638, file: 3),
        ten(dau: 7, cuoi: 7, lonNhat: 638, file: 1),
        ten(dau: 60, cuoi: 60, lonNhat: 638, file: 2),
      ]..sort();
      expect(danh.first.contains(' - 007 - '), isTrue);
      expect(danh.last.contains(' - 100 - '), isTrue);
    });

    test('tên truyện có ký tự cấm thì lọc đi, rỗng thì có tên thay thế', () {
      expect(ten(truyen: 'A/B:C?'), isNot(contains('/')));
      expect(ten(truyen: '???').startsWith('sach-noi'), isTrue);
    });
  });
}
