/// Kiểm chứng FFI/isolate bằng trọng số và tiếng nói thật, không thay bằng sóng giả.
/// Đặt MO_HINH_KIEM_AM, WAV_KIEM_AM, LOI_KIEM_AM và ORT_DYLIB_PATH để chạy.
/// Thêm TAI_MO_HINH_KIEM_AM=1 với thư mục rỗng để kiểm cả tải từ GitHub.
library;

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/am_tiet_chu.dart';
import 'package:sach_noi/core/kiem_am.dart';
import 'package:sach_noi/core/wav.dart';
import 'package:sach_noi/services/kiem_am/wav2vec2_native.dart';
import 'package:sach_noi/services/kiem_am/kho_wav2vec2.dart';
import 'package:http/testing.dart';
import 'duong_dan_repo.dart';

void main() {
  final moHinh = Platform.environment['MO_HINH_KIEM_AM'];
  final duongWav = Platform.environment['WAV_KIEM_AM'];
  final loi = Platform.environment['LOI_KIEM_AM'];
  final duDieuKien =
      moHinh != null &&
      duongWav != null &&
      loi != null &&
      File(vieneuLibPath).existsSync();
  test(
    'wav2vec2 thật: nguyên câu, cắt nửa, lặp, tốc độ, im lặng và khôi phục sau lỗi',
    () async {
      final thu = await Directory.systemTemp.createTemp('kiem-am-that-');
      final kho = KhoWav2vec2(thuMuc: Directory(moHinh!));
      final camMang = Platform.environment['TAI_MO_HINH_KIEM_AM'] == '1'
          ? null
          : MockClient(
              (_) async => throw StateError('Test phải dùng file sẵn có'),
            );
      // Tải tiếp từ hai file thật đã có: xác minh SHA-256 và ghi dấu hoàn tất.
      await kho.tai(tienDo: (_) {}, mayKhach: camMang);
      camMang?.close();
      expect(await kho.sanSang(), isTrue);
      final bo = await Wav2vec2Native.mo(moHinh, thuVien: vieneuLibPath);
      try {
        final raw = await File(duongWav!).readAsBytes();
        final thongTin = readWavInfo(raw)!;
        expect(thongTin.bitsPerSample, 16);
        expect(thongTin.channels, 1);
        final pcm = wavPcm(raw);
        final soChu = demAmChu(loi!);
        Future<AmNhanDang> thuPcm(
          String ten,
          List<int> mau, {
          int? tanSo,
          double nhip = 1,
        }) async {
          final wav = await File('${thu.path}/$ten.wav').writeAsBytes([
            ...wavHeader(mau.length, tanSo ?? thongTin.sampleRate),
            ...mau,
          ]);
          return bo.nhan(wav.path, nhipCaoDo: nhip);
        }

        final nguyen = await bo.nhan(duongWav);
        // Không ghim một con số nghe được từ model: so với lời gốc độc lập.
        expect(
          KetQuaKiemAm(soTu: soChu, soAm: nguyen.soAm).dat,
          isTrue,
          reason: '${nguyen.soAm}/$soChu: ${nguyen.amVi}',
        );
        final nua = await thuPcm('nua', pcm.sublist(0, pcm.length ~/ 4 * 2));
        expect(nua.soAm, lessThan(nguyen.soAm * 0.75));
        final lap = await thuPcm('lap', [
          ...pcm,
          ...Uint8List(thongTin.sampleRate),
          ...pcm,
        ]);
        expect(lap.soAm, greaterThan(nguyen.soAm * 1.7));
        expect(KetQuaKiemAm(soTu: soChu, soAm: lap.soAm).dat, isFalse);
        final dai = await thuPcm('dai', [for (var i = 0; i < 5; i++) ...pcm]);
        expect(
          dai.soAm,
          closeTo(nguyen.soAm * 5, nguyen.soAm * 0.6),
          reason: 'ghép cửa sổ không mất/lặp âm',
        );
        final nhanh = await thuPcm(
          'nhanh',
          pcm,
          tanSo: (thongTin.sampleRate * 1.5).round(),
          nhip: 1.5,
        );
        expect(
          nhanh.soAm,
          nguyen.soAm,
          reason: 'khôi phục cao độ phải trả cùng mẫu đầu vào',
        );
        for (final tanSo in [16000, 22050, 24000, 48000]) {
          expect(
            (await thuPcm(
              'lang-$tanSo',
              Uint8List(tanSo * 2),
              tanSo: tanSo,
            )).soAm,
            0,
          );
        }
        final loiWav = await File(
          '${thu.path}/hong.wav',
        ).writeAsBytes([1, 2, 3]);
        await expectLater(bo.nhan(loiWav.path), throwsA(isA<StateError>()));
        final sauLoi = await Future.wait([
          bo.nhan(duongWav),
          bo.nhan(duongWav),
        ]);
        expect(sauLoi.map((k) => k.soAm), everyElement(nguyen.soAm));
        // ignore: avoid_print
        print(
          'wav2vec2: gốc ${nguyen.soAm}/$soChu, nửa ${nua.soAm}, lặp ${lap.soAm}, dài ${dai.soAm}',
        );
      } finally {
        await bo.dong();
        await thu.delete(recursive: true);
      }
    },
    skip: duDieuKien
        ? false
        : 'Cần mô hình, WAV/lời gốc qua biến môi trường và DLL Rust mới',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
