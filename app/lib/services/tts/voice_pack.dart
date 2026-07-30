/// Gói giọng Piper: tải về máy, kiểm tra, xoá đi.
///
/// Piper là mô hình VITS nhỏ (21-64 MB), chạy được cả trên máy yếu lẫn điện
/// thoại. Nó không hay bằng VieNeu nhưng nhẹ hơn mười lần và không cần tải mô
/// hình 206 MB, nên vẫn đáng giữ làm lựa chọn.
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../models/work_progress.dart';
import '../storage.dart';

/// Một gói giọng tải về được.
class VoicePack {
  const VoicePack({
    required this.folder,
    required this.name,
    required this.gender,
    required this.description,
    required this.megabytes,
    required this.url,
    required this.modelFile,
  });

  /// Tên thư mục sau khi giải nén, cũng là mã của giọng.
  final String folder;
  final String name;
  final String gender;
  final String description;
  final int megabytes;
  final String url;

  /// File .onnx bên trong thư mục.
  final String modelFile;
}

const _base = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models';

/// Ba giọng tiếng Việt của Piper, cân giữa dung lượng và chất lượng.
const availableVoicePacks = <VoicePack>[
  VoicePack(
    folder: 'vits-piper-vi_VN-vais1000-medium',
    name: 'Vais',
    gender: 'Nữ',
    description: 'Rõ ràng, dễ nghe — bản cân bằng nhất',
    megabytes: 64,
    url: '$_base/vits-piper-vi_VN-vais1000-medium.tar.bz2',
    modelFile: 'vi_VN-vais1000-medium.onnx',
  ),
  VoicePack(
    folder: 'vits-piper-vi_VN-25hours_single-low',
    name: 'Hai Lăm Giờ',
    gender: 'Nữ',
    description: 'Nhẹ hơn, giọng hơi máy',
    megabytes: 29,
    url: '$_base/vits-piper-vi_VN-25hours_single-low.tar.bz2',
    modelFile: 'vi_VN-25hours_single-low.onnx',
  ),
  VoicePack(
    folder: 'vits-piper-vi_VN-vivos-x_low',
    name: 'Vivos',
    gender: 'Nam',
    description: 'Nhỏ nhất, dành cho máy yếu',
    megabytes: 21,
    url: '$_base/vits-piper-vi_VN-vivos-x_low.tar.bz2',
    modelFile: 'vi_VN-vivos-x_low.onnx',
  ),
];

Directory get voicePackDir => Directory(p.join(Storage.instance.root.path, 'voices'));

/// Thư mục của một gói đã cài, null nếu chưa có.
Directory? findVoicePack(String folder) {
  final dir = Directory(p.join(voicePackDir.path, folder));
  if (!dir.existsSync()) return null;
  // Có thư mục nhưng thiếu file mô hình nghĩa là giải nén dở.
  final hasModel = dir.listSync().whereType<File>().any((f) => f.path.endsWith('.onnx'));
  return hasModel ? dir : null;
}

List<VoicePack> installedVoicePacks() =>
    availableVoicePacks.where((pack) => findVoicePack(pack.folder) != null).toList();

Future<void> deleteVoicePack(String folder) async {
  final dir = Directory(p.join(voicePackDir.path, folder));
  if (await dir.exists()) await dir.delete(recursive: true);
}

/// Tải và giải nén một gói giọng.
Future<void> downloadVoicePack(
  VoicePack pack, {
  required void Function(WorkProgress) onProgress,
  http.Client? client,
}) async {
  final web = client ?? http.Client();
  await voicePackDir.create(recursive: true);

  onProgress(WorkProgress('Đang tải ${pack.name}', value: 0));
  final response = await web.send(http.Request('GET', Uri.parse(pack.url)));
  if (response.statusCode != 200) {
    throw Exception('Tải gói giọng lỗi ${response.statusCode}');
  }

  final expected = response.contentLength ?? pack.megabytes * 1024 * 1024;
  final bytes = <int>[];
  await for (final chunk in response.stream) {
    bytes.addAll(chunk);
    onProgress(WorkProgress(
      'Đang tải ${(bytes.length / 1024 / 1024).toStringAsFixed(0)}/${pack.megabytes} MB',
      // Chừa 10% cuối cho việc giải nén.
      value: (bytes.length / expected) * 0.9,
    ));
  }

  onProgress(const WorkProgress('Đang giải nén…', value: 0.92));
  // Gói của sherpa-onnx là .tar.bz2: bung bz2 rồi mới đọc tar.
  final tar = BZip2Decoder().decodeBytes(bytes);
  final archive = TarDecoder().decodeBytes(tar);

  for (final entry in archive) {
    if (!entry.isFile) continue;
    final target = File(p.join(voicePackDir.path, entry.name));
    await target.parent.create(recursive: true);
    await target.writeAsBytes(entry.content as List<int>, flush: true);
  }

  onProgress(const WorkProgress('Xong', value: 1));
  if (client == null) web.close();
}
