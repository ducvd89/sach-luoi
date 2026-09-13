/// Tải đúng bản wav2vec2 đã kiểm chứng, xác minh SHA-256 trước khi dùng.
///
/// Giữ bản sao nguyên vẹn trong sach-luoi-models cùng các mô hình giọng nói,
/// tránh phụ thuộc tình trạng truy cập của kho nguồn. Revision và SHA-256
/// vẫn ghim bản đã đo; đổi nơi tải không bắt người dùng tải lại bản đã có.
/// File .part không bao giờ được coi là đã cài.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../models/work_progress.dart';
import '../storage.dart';

const phienBanWav2vec2 = 'ded9b63317d3efdb0d0422fd05592efb43cdee10';
const nguonWav2vec2 =
    'https://github.com/ducvd89/sach-luoi-models/releases/download/v1';
const _tep = [
  (
    ten: 'model_quantized.onnx',
    duongDan: 'wav2vec2-vi-phone-model_quantized.onnx',
    byte: 122435778,
    bam: 'c4c7503ce9c0ab43cdb31fb8b5a6cb1fc1d0693281ac9bc473cdf6cee09e8a29',
  ),
  (
    ten: 'phonemes.json',
    duongDan: 'wav2vec2-vi-phone-phonemes.json',
    byte: 1636,
    bam: '71616f1fad5bb7224c45852eaa629837635523f8c02d9dedcf89ea3c2b737181',
  ),
];

class KhoWav2vec2 {
  KhoWav2vec2({this._thuMuc});
  final Directory? _thuMuc;
  Directory get thuMuc =>
      _thuMuc ??
      Directory(
        p.join(Storage.instance.root.path, 'kiem-am', phienBanWav2vec2),
      );
  File get _dau => File(p.join(thuMuc.path, 'da-xac-minh.json'));
  Future<void>? _dangTai;

  Future<bool> sanSang() async {
    if (!await _dau.exists()) return false;
    try {
      final dau = jsonDecode(await _dau.readAsString()) as Map<String, dynamic>;
      if (dau['phienBan'] != phienBanWav2vec2) return false;
      for (final tep in _tep) {
        final f = File(p.join(thuMuc.path, tep.ten));
        if (!await f.exists() || await f.length() != tep.byte) return false;
        // Nếu file bị thay sau khi xác minh thì không được dùng dấu cũ.
        if (dau[tep.ten] != (await f.lastModified()).microsecondsSinceEpoch) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> tai({
    required void Function(WorkProgress) tienDo,
    http.Client? mayKhach,
  }) {
    return _dangTai ??= _tai(tienDo, mayKhach).whenComplete(() {
      _dangTai = null;
    });
  }

  Future<void> _tai(
    void Function(WorkProgress) tienDo,
    http.Client? mayKhach,
  ) async {
    if (await sanSang()) return;
    final khach = mayKhach ?? http.Client();
    final tong = _tep.fold<int>(0, (so, tep) => so + tep.byte);
    var daTai = 0;
    await thuMuc.create(recursive: true);
    try {
      for (final tep in _tep) {
        final dich = File(p.join(thuMuc.path, tep.ten));
        if (await dich.exists() &&
            await dich.length() == tep.byte &&
            (await sha256.bind(dich.openRead()).first).toString() == tep.bam) {
          daTai += tep.byte;
          continue;
        }
        final tam = File('${dich.path}.part');
        try {
          final ra = await khach
              .send(
                http.Request(
                  'GET',
                  Uri.parse(
                    '$nguonWav2vec2/${tep.duongDan}',
                  ),
                ),
              )
              .timeout(const Duration(seconds: 30));
          if (ra.statusCode != 200) {
            throw HttpException(
              'Không tải được wav2vec2: HTTP ${ra.statusCode}',
            );
          }
          final ghi = tam.openWrite();
          var nhan = 0;
          var lanBao = DateTime.fromMillisecondsSinceEpoch(0);
          try {
            await for (final khoi in ra.stream.timeout(
              const Duration(seconds: 60),
            )) {
              nhan += khoi.length;
              if (nhan > tep.byte) {
                throw const FormatException('File wav2vec2 sai kích thước');
              }
              ghi.add(khoi);
              if (DateTime.now().difference(lanBao).inMilliseconds >= 150) {
                tienDo(
                  WorkProgress(
                    'Đang tải wav2vec2…',
                    value: (daTai + nhan) / tong * 0.95,
                  ),
                );
                lanBao = DateTime.now();
              }
            }
            await ghi.flush();
          } finally {
            await ghi.close();
          }
          if (nhan != tep.byte ||
              (await sha256.bind(tam.openRead()).first).toString() != tep.bam) {
            throw const FormatException(
              'File wav2vec2 tải thiếu hoặc sai SHA-256; hãy tải lại',
            );
          }
          if (await dich.exists()) await dich.delete();
          await tam.rename(dich.path);
          daTai += nhan;
        } finally {
          if (await tam.exists()) await tam.delete();
        }
      }
      final dau = <String, dynamic>{'phienBan': phienBanWav2vec2};
      for (final tep in _tep) {
        dau[tep.ten] = (await File(
          p.join(thuMuc.path, tep.ten),
        ).lastModified()).microsecondsSinceEpoch;
      }
      await _dau.writeAsString(jsonEncode(dau), flush: true);
      tienDo(const WorkProgress('Đã tải và xác minh wav2vec2', value: 1));
    } finally {
      if (mayKhach == null) khach.close();
    }
  }
}
