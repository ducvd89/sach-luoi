/// Gói giọng Piper: tải về máy, kiểm tra, xoá đi.
///
/// Piper là mô hình VITS nhỏ (21-64 MB), chạy được cả trên máy yếu lẫn điện
/// thoại. Nó không hay bằng VieNeu nhưng nhẹ hơn mười lần và không cần tải mô
/// hình 145 MB, nên vẫn đáng giữ làm lựa chọn.
library;

import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../models/work_progress.dart';
import '../storage.dart';
import 'model_store.dart' show tenTrongGoi;

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

/// Nơi tải gói giọng: bản sao do chính dự án giữ.
///
/// Cùng lý do như mô hình VieNeu (xem `model_store.dart`): nguồn của bên thứ ba
/// có thể bị khoá hoặc gỡ bất cứ lúc nào, mà lúc ấy thì không ai sửa được gì.
/// Các gói ở đây là bản sao nguyên vẹn từ sherpa-onnx của k2-fsa.
const _base = 'https://github.com/ducvd89/sach-luoi-models/releases/download/v1';

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
    description: 'Mô hình mức thấp, giọng hơi máy',
    megabytes: 64,
    url: '$_base/vits-piper-vi_VN-25hours_single-low.tar.bz2',
    modelFile: 'vi_VN-25hours_single-low.onnx',
  ),
  VoicePack(
    folder: 'vits-piper-vi_VN-vivos-x_low',
    name: 'Vivos',
    gender: 'Nam',
    description: 'Nhỏ nhất, dành cho máy yếu',
    megabytes: 32,
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
  final nen = File(p.join(voicePackDir.path, '${pack.folder}.tar.bz2.part'));
  final tar = File(p.join(voicePackDir.path, '${pack.folder}.tar.part'));

  try {
    final sink = nen.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress(WorkProgress(
          'Đang tải ${(received / 1024 / 1024).toStringAsFixed(0)}/${pack.megabytes} MB',
          // Chừa 10% cuối cho việc giải nén.
          value: expected == 0 ? 0 : (received / expected) * 0.9,
        ));
      }
    } finally {
      await sink.flush();
      await sink.close();
    }

    onProgress(const WorkProgress('Đang giải nén…', value: 0.92));
    // Rút sẵn ra chuỗi: isolate mới không có `Storage.instance` nên gọi
    // `voicePackDir` bên trong nó là ném lỗi, mà File cũng không gửi qua được.
    final duongNen = nen.path, duongTar = tar.path, duongDich = voicePackDir.path;
    await Isolate.run(() => _giaiNen(duongNen, duongTar, duongDich));
  } finally {
    if (await nen.exists()) await nen.delete();
    if (await tar.exists()) await tar.delete();
    if (client == null) web.close();
  }

  if (findVoicePack(pack.folder) == null) {
    throw Exception('Giải nén ${pack.name} xong nhưng không thấy file mô hình');
  }
  onProgress(const WorkProgress('Xong', value: 1));
}

/// Bung `.tar.bz2` từ file ra file, không qua bộ nhớ.
///
/// Chạy trong isolate riêng vì hai lẽ. Một: bản cài đặt bz2 của gói `archive`
/// viết bằng Dart thuần và chậm — để trên isolate giao diện thì màn hình đứng
/// vài giây và Android kêu ANR. Hai: bản cũ gom cả gói vào `List<int>` rồi mới
/// giải, mà list growable của Dart giữ mỗi phần tử 8 byte, nên gói 64 MB ngốn
/// ~512 MB (chưa kể lúc nhân đôi để mở rộng, và bản tar giải ra sau đó) —
/// Android giết luôn tiến trình, người dùng chỉ thấy ứng dụng biến mất.
void _giaiNen(String nen, String tar, String dich) {
  var vao = InputFileStream(nen);
  var ra = OutputFileStream(tar);
  try {
    BZip2Decoder().decodeStream(vao, ra);
  } finally {
    ra.closeSync();
    vao.closeSync();
  }

  vao = InputFileStream(tar);
  try {
    for (final muc in TarDecoder().decodeStream(vao)) {
      if (!muc.isFile) continue;
      // Chuẩn hoá dấu phân cách rồi chặn đường dẫn leo ra ngoài thư mục đích.
      final duong = File(p.normalize(p.join(dich, tenTrongGoi(muc.name))));
      if (!p.isWithin(dich, duong.path)) continue;

      duong.parent.createSync(recursive: true);
      final o = OutputFileStream(duong.path);
      try {
        muc.writeContent(o);
      } finally {
        o.closeSync();
      }
    }
  } finally {
    vao.closeSync();
  }
}
