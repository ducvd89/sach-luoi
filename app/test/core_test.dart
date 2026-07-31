/// Kiểm thử các phần logic thuần: đọc số, chuẩn hoá văn bản, cắt đoạn, MP3.
///
/// Đây là những chỗ dễ sai âm thầm nhất — sai một quy tắc đọc số thì cả cuốn
/// sách đọc lệch mà không có gì báo lỗi.
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/chunker.dart';
import 'package:sach_noi/core/mp3.dart';
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
        expect(chunk.display.length, lessThanOrEqualTo(chunkMaxChars + 120));
      }
    });
  });

  group('MP3', () {
    test('thẻ ID3 hợp lệ và bị cắt đúng', () {
      final tag = buildId3(title: 'Chương một', artist: 'Tác giả', album: 'Sách', track: '1');
      expect(tag[0], 0x49); // 'I'
      expect(tag[1], 0x44); // 'D'
      expect(tag[2], 0x33); // '3'

      final fake = Uint8List.fromList([...tag, 0xFF, 0xFB, 0x90, 0x00]);
      final stripped = stripTags(fake);
      expect(stripped.length, 4);
      expect(stripped[0], 0xFF);
    });

    test('thời lượng của luồng rỗng là 0', () {
      expect(mp3Duration(Uint8List(0)), 0);
    });

    test('khung im lặng ghép vào đúng thời lượng và đúng định dạng', () {
      // Một khung MPEG1 Layer III, 64 kbps, 24 kHz... thực tế 24 kHz là MPEG2:
      // 0xFF 0xF3 = MPEG2 Layer III, 0x40 = 64 kbps + 24 kHz.
      final frame = Uint8List(4 + 100);
      frame[0] = 0xFF;
      frame[1] = 0xF3;
      frame[2] = 0x40;
      frame[3] = 0xC4; // mono
      final oneFrame = mp3Duration(frame);
      expect(oneFrame, greaterThan(0));

      final silence = silentFramesLike(frame, 0.6);
      expect(silence, isNotEmpty);
      expect(mp3Duration(silence), closeTo(0.6, oneFrame));

      // Phải giữ nguyên tần số lấy mẫu và bitrate của luồng gốc, nếu không nối
      // vào là méo tiếng.
      expect(silence[0], 0xFF);
      expect(silence[2], frame[2]);
      expect(silence[1] & 0xFE, frame[1] & 0xFE);
      // Thân khung toàn số 0 — đó là chỗ tạo ra im lặng.
      expect(silence.sublist(4, 30).every((b) => b == 0), isTrue);
    });

    test('không có khung hợp lệ thì không dựng được im lặng', () {
      expect(silentFramesLike(Uint8List.fromList([1, 2, 3, 4]), 1.0), isEmpty);
      expect(silentFramesLike(Uint8List(0), 1.0), isEmpty);
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
