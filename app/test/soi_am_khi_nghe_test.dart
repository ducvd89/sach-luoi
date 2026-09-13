/// Đường nhận dạng dùng chung phải ổn định khi đọc trước, nghe lại và đổi tốc độ.
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/services/kiem_am/bo_kiem_am.dart';
import 'package:sach_noi/services/kiem_am/kho_wav2vec2.dart';
import 'package:sach_noi/services/kiem_am/wav2vec2_native.dart';
import 'package:sach_noi/services/tts/tts_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory thu;
  late File wav;
  setUp(() async {
    thu = await Directory.systemTemp.createTemp('sach-luoi-kiem-am-');
    wav = await File('${thu.path}/mau.wav').writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await thu.delete(recursive: true);
  });

  test('lời gốc không được đưa vào nhận dạng để ép số âm đúng', () async {
    var lan = 0;
    final bo = BoKiemAm(
      nhanAm: (f, nhip) async {
        lan++;
        return const AmNhanDang(2, 'a-0 iə-1');
      },
    );
    addTearDown(bo.dong);
    final dung = await bo.kiem(loi: 'xin chào', wav: wav);
    final sai = await bo.kiem(
      loi: 'một hai ba bốn năm sáu bảy tám chín mười',
      wav: wav,
    );
    expect(lan, 1);
    expect(dung.dat, isTrue);
    expect(sai.dat, isFalse);
    expect(sai.amVi, 'a-0 iə-1');
  });

  test('expected cộng đủ âm tiếng Anh rồi mới chấm ngưỡng 100–110%', () async {
    // 7 từ Việt + Windows(2) + driver(2) = 11 âm, không phải 9 hay 13.
    const loi = 'Anh ấy mở Windows lên rồi cài driver mới.';
    for (final soAm in [10, 11, 12, 13]) {
      final bo = BoKiemAm(
        nhanAm: (f, nhip) async => AmNhanDang(soAm, 'âm vị giả'),
      );
      addTearDown(bo.dong);
      final ket = await bo.kiem(loi: loi, wav: wav);
      expect(ket.soTu, 11);
      expect(ket.dat, soAm == 11 || soAm == 12, reason: '$soAm/11 âm');
    }
  });

  test('từ Anh có hoặc không có thẻ en đều cộng âm một lần', () async {
    final bo = BoKiemAm(
      nhanAm: (f, nhip) async => const AmNhanDang(4, 'âm vị giả'),
    );
    addTearDown(bo.dong);
    for (final loi in ['Mua iPhone mới', 'Mua <en>iPhone</en> mới']) {
      final ket = await bo.kiem(loi: loi, wav: wav);
      expect(ket.soTu, 4);
      expect(ket.dat, isTrue);
    }
  });

  test(
    'chạm mtime giữ cache, thay nội dung WAV thì phải nhận dạng lại',
    () async {
      var lan = 0;
      final bo = BoKiemAm(
        nhanAm: (f, nhip) async {
          lan++;
          return AmNhanDang(lan, 'a-0');
        },
      );
      addTearDown(bo.dong);
      await bo.kiem(loi: 'một', wav: wav);
      await wav.setLastModified(DateTime(2030));
      await bo.kiem(loi: 'một', wav: wav);
      expect(lan, 1);
      await wav.writeAsBytes([3, 2, 1]);
      expect((await bo.kiem(loi: 'hai', wav: wav)).soAm, 2);
    },
  );

  test(
    'yêu cầu đồng thời dùng một hàng đợi, lỗi không làm treo yêu cầu kế',
    () async {
      var dangChay = 0;
      var dinh = 0;
      var lan = 0;
      final bo = BoKiemAm(
        nhanAm: (f, nhip) async {
          dangChay++;
          if (dangChay > dinh) dinh = dangChay;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          dangChay--;
          if (lan++ == 0) throw StateError('lỗi thử');
          return const AmNhanDang(1, 'a-0');
        },
      );
      addTearDown(bo.dong);
      final ket = await Future.wait([
        bo.kiem(loi: 'một', wav: wav),
        bo.kiem(loi: 'hai', wav: wav),
      ]);
      expect(dinh, 1);
      expect(ket.first.daKiem, isFalse);
      expect(ket.last.dat, isTrue);
    },
  );

  test('chỉ khôi phục cao độ hai VieNeu, không đổi cao độ Matcha', () async {
    final nhipNhan = <double>[];
    final bo = BoKiemAm(
      nhanAm: (f, nhip) async {
        nhipNhan.add(nhip);
        return const AmNhanDang(1, 'a-0');
      },
    );
    addTearDown(bo.dong);
    final tts = TtsManager(boKiemAm: bo);
    for (final id in ['vieneu', 'vieneu_v2', 'matcha', 'piper', 'system']) {
      await bo.napLai();
      await tts.kiemDoan(loi: 'một', wav: wav, engineId: id, tocDo: 1.5);
    }
    expect(nhipNhan, [1.5, 1.5, 1, 1, 1]);
  });

  test('thiếu mô hình trả chưa kiểm, không thay bằng đếm sóng', () async {
    final bo = BoKiemAm(
      kho: KhoWav2vec2(thuMuc: Directory('${thu.path}/thieu')),
    );
    addTearDown(bo.dong);
    final ket = await bo.kiem(loi: 'một hai ba', wav: wav);
    expect(ket.soAm, isNull);
    expect(ket.dat, isFalse);
    expect(ket.lyDoBoQua, contains('Cài đặt'));
  });

  test(
    'thiếu thư viện native phải trả lỗi và đóng isolate, không chờ mãi',
    () async {
      await expectLater(
        Wav2vec2Native.mo(thu.path, thuVien: '${thu.path}/khong-co.dll'),
        throwsA(isA<StateError>()),
      );
    },
  );
}
