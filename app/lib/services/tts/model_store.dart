/// Quản lý bộ file mô hình trên máy: kiểm tra, tải về, xoá đi.
///
/// Mô hình nặng khoảng 206 MB nên không nhét vào bản cài; ứng dụng tải một lần
/// rồi dùng offline mãi. Từ điển âm vị thì đi kèm sẵn trong ứng dụng vì không
/// có nguồn tải công khai nào ổn định.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../models/work_progress.dart';
import '../storage.dart';
import 'vieneu_native.dart';
import 'vieneu_v2_native.dart';

/// Một file cần có, kèm nơi tải và kích thước để vẽ thanh tiến trình.
class ModelFile {
  const ModelFile(this.name, this.url, this.megabytes, {this.folder = 'model'});
  final String name;
  final String url;
  final double megabytes;

  /// 'model' cho mạng chính, 'codec' cho bộ giải mã âm.
  final String folder;
}

const _modelRepo = 'https://huggingface.co/pnnbao-ump/VieNeu-TTS-v3-Turbo/resolve/main/onnx_int8';
const _codecRepo =
    'https://huggingface.co/OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano-ONNX/resolve/main';

/// Đúng những file mà đường chạy ONNX cần — không tải bản fp32 hay bộ mã hoá.
const modelFiles = <ModelFile>[
  ModelFile('vieneu_prefill.onnx', '$_modelRepo/vieneu_prefill.onnx', 1.0),
  ModelFile('vieneu_decode_step.onnx', '$_modelRepo/vieneu_decode_step.onnx', 1.0),
  ModelFile('vieneu_acoustic_cached.onnx', '$_modelRepo/vieneu_acoustic_cached.onnx', 6.9),
  ModelFile('vieneu_backbone_shared.data', '$_modelRepo/vieneu_backbone_shared.data', 99.1),
  ModelFile('vieneu_v3_heads.npz', '$_modelRepo/vieneu_v3_heads.npz', 49.8),
  ModelFile('config.json', '$_modelRepo/config.json', 0.01),
  ModelFile('tokenizer.json', '$_modelRepo/tokenizer.json', 0.05),
  // Bản `_step` giải mã theo cửa sổ cuốn chiếu chứ không nuốt cả đoạn một lượt:
  // ra đúng từng mẫu như bản `_full` nhưng thời gian tuyến tính và bộ nhớ có
  // trần (xem KHUNG_MOI_LUOT trong native/vieneu/src/engine.rs). Hai bản dùng
  // chung file trọng số bên dưới nên đổi sang đây không tốn thêm gì đáng kể.
  ModelFile('moss_audio_tokenizer_decode_step.onnx',
      '$_codecRepo/moss_audio_tokenizer_decode_step.onnx', 0.4, folder: 'codec'),
  ModelFile('moss_audio_tokenizer_decode_shared.data',
      '$_codecRepo/moss_audio_tokenizer_decode_shared.data', 43.0, folder: 'codec'),
];

/// Chỉ cần khi thêm giọng mới, nên tải riêng — ai không dùng khỏi tốn 70 MB.
const enrollFiles = <ModelFile>[
  ModelFile('speaker_encoder.onnx',
      'https://huggingface.co/pnnbao-ump/VieNeu-TTS-v3-Turbo/resolve/main/speaker_encoder.onnx',
      27.0, folder: 'enroll'),
  ModelFile('moss_audio_tokenizer_encode.onnx',
      '$_codecRepo/moss_audio_tokenizer_encode.onnx', 0.8, folder: 'enroll'),
  ModelFile('moss_audio_tokenizer_encode.data',
      '$_codecRepo/moss_audio_tokenizer_encode.data', 42.4, folder: 'enroll'),
];

/// Bộ file của engine VieNeu **v2** — tải riêng, ai không dùng khỏi tốn.
///
/// Chỉ ba file, ít hơn hẳn v3: trọng số nằm gọn trong một file GGUF thay vì bị
/// chẻ ra thành đồ thị ONNX nhiều mảnh, còn bộ giải mã âm là NeuCodec một file.
///
/// Nặng hơn v3 (487 MB so với 206 MB) mà chủ yếu là do bộ giải mã: 298 MB cho
/// riêng nó, trong khi phần mô hình ngôn ngữ Q4 chỉ 189 MB dù gấp ba tham số.
const v2ModelFiles = <ModelFile>[
  ModelFile(
      'VieNeu-TTS-v2-Q4-K-M.gguf',
      'https://huggingface.co/pnnbao-ump/VieNeu-TTS-v2/resolve/main/VieNeu-TTS-v2-Q4-K-M.gguf',
      180.3,
      folder: 'v2'),
  ModelFile(
      'neucodec_decoder_int8.onnx',
      'https://huggingface.co/neuphonic/neucodec-onnx-decoder-int8/resolve/main/model.onnx',
      297.8,
      folder: 'v2'),
  ModelFile('voices.json',
      'https://huggingface.co/pnnbao-ump/VieNeu-TTS-v2/resolve/main/voices.json', 0.03,
      folder: 'v2'),
];

/// Bộ mã hoá NeuCodec — chỉ cần khi THÊM giọng cho v2, nên tải riêng.
///
/// Nặng 519 MB, hơn cả mô hình. Đây là bản **distil** của Neuphonic (encoder gốc
/// còn to hơn), và code nó sinh ra tương thích với bộ giải mã đang dùng — đã
/// kiểm bằng cách nhân bản rồi đọc lại.
const _v2EncoderRepo =
    'https://huggingface.co/KevinAHM/distill-neucodec-onnx/resolve/main/onnx';
const v2EncoderFiles = <ModelFile>[
  ModelFile('distill_neucodec_encoder.onnx',
      '$_v2EncoderRepo/distill_neucodec_encoder.onnx', 277.0,
      folder: 'v2'),
  // Trọng số ngoài của đồ thị trên — ONNX Runtime tự tìm nó CẠNH file .onnx
  // theo đúng tên này, nên hai file phải nằm chung thư mục.
  ModelFile('distill_neucodec_encoder.onnx.data',
      '$_v2EncoderRepo/distill_neucodec_encoder.onnx.data', 242.0,
      folder: 'v2'),
];

double get totalMegabytes => modelFiles.fold(0.0, (sum, f) => sum + f.megabytes);
double get v2EncoderMegabytes => v2EncoderFiles.fold(0.0, (sum, f) => sum + f.megabytes);
double get enrollMegabytes => enrollFiles.fold(0.0, (sum, f) => sum + f.megabytes);
double get v2Megabytes => v2ModelFiles.fold(0.0, (sum, f) => sum + f.megabytes);

/// Từ điển âm vị đi kèm ứng dụng, chép ra đĩa vì thư viện Rust cần đường dẫn thật.
///
/// Hồ sơ giọng KHÔNG nằm ở đây: nó phải hợp nhất chứ không chép đè, xem
/// [ModelStore._hopNhatGiong].
const _bundledAssets = {'assets/sea_g2p.bin': 'sea_g2p.bin'};

/// Như trên nhưng chép vào thư mục của engine v2.
const _bundledV2Assets = {'assets/giong_v2.json': 'giong_v2.json'};

/// Dấu mà thư viện Rust ghi cho giọng người dùng tự thêm trong ứng dụng.
///
/// Phải khớp với `save_voice` và `remove_voice_from_file` trong
/// native/vieneu/src/ffi.rs — bên đó chỉ cho xoá giọng mang dấu này, nên đây
/// cũng chỉ được coi là "tự thêm" đúng những giọng ấy.
const nhanTuThem = 'nguoi-dung';

/// Thông tin hiển thị của một giọng.
class VoiceMeta {
  const VoiceMeta({required this.gender, required this.description, required this.builtIn});
  final String gender;
  final String description;
  final bool builtIn;
}

/// Thư viện ghi 'male'/'female'; giao diện thì nói tiếng Việt.
const _genders = {'male': 'Nam', 'female': 'Nữ'};

/// Giọng này do người dùng tự thêm trên chính máy này.
///
/// Chỉ đúng dấu [nhanTuThem], không nhận đuôi .wav: giọng trong bản cài cũng
/// mang tên file mẫu (Latradio.wav, Kim Cúc.wav) nhưng chúng đi kèm ứng dụng —
/// thư viện Rust từ chối xoá, mà có xoá được thì lần mở sau [_hopNhatGiong]
/// cũng đưa chúng trở lại. Hiện nút xoá cho chúng chỉ là hứa hão.
bool _tuThem(String source) => source == nhanTuThem;

class ModelStore {
  ModelStore({Directory? root}) : _overrideRoot = root;

  /// Null nghĩa là lấy thư mục mặc định trong vùng dữ liệu của ứng dụng; kiểm
  /// thử truyền vào một thư mục tạm để không đụng dữ liệu thật.
  final Directory? _overrideRoot;

  Directory get root =>
      _overrideRoot ?? Directory(p.join(Storage.instance.root.path, 'vieneu'));
  Directory get modelDir => Directory(p.join(root.path, 'model'));
  Directory get codecDir => Directory(p.join(root.path, 'codec'));
  File get dictFile => File(p.join(root.path, 'sea_g2p.bin'));
  File get voicesFile => File(p.join(root.path, 'giong.json'));

  Directory get enrollDir => Directory(p.join(root.path, 'enroll'));
  File get speakerEncoder => File(p.join(enrollDir.path, 'speaker_encoder.onnx'));
  File get codecEncoder => File(p.join(enrollDir.path, 'moss_audio_tokenizer_encode.onnx'));

  // -- engine v2 -------------------------------------------------------------
  // Từ điển âm vị thì dùng chung [dictFile] với v3, không chép hai bản 50 MB.

  Directory get v2Dir => Directory(p.join(root.path, 'v2'));
  File get v2Gguf => File(p.join(v2Dir.path, 'VieNeu-TTS-v2-Q4-K-M.gguf'));
  File get v2Codec => File(p.join(v2Dir.path, 'neucodec_decoder_int8.onnx'));
  File get v2Voices => File(p.join(v2Dir.path, 'voices.json'));

  /// Giọng nhân bản sẵn đi kèm ứng dụng (Latradio, Việt Sử). Chép ra từ assets
  /// mỗi lần tải vì bản cập nhật có thể thêm giọng mới.
  File get v2ExtraVoices => File(p.join(v2Dir.path, 'giong_v2.json'));

  /// Giọng người dùng tự thêm — **chỉ file này** được ghi lúc chạy. Hai file
  /// trên đều bị ghi đè khi tải lại nên không cất gì lâu dài vào đó được.
  File get v2UserVoices => File(p.join(v2Dir.path, 'giong_v2_nguoi_dung.json'));

  /// Bộ mã hoá NeuCodec — chỉ cần khi thêm giọng, nên tải riêng.
  File get v2Encoder => File(p.join(v2Dir.path, 'distill_neucodec_encoder.onnx'));

  Directory _dirFor(ModelFile file) => switch (file.folder) {
        'codec' => codecDir,
        'enroll' => enrollDir,
        'v2' => v2Dir,
        _ => modelDir,
      };
  File fileFor(ModelFile file) => File(p.join(_dirFor(file).path, file.name));

  /// Đủ file để chạy chưa.
  ///
  /// Chỉ xét có file và file khác rỗng, KHÔNG so với kích thước khai báo. File
  /// tải dở luôn mang đuôi .part và chỉ được đổi sang tên thật khi đã tải xong,
  /// nên sự tồn tại của tên thật đã là bằng chứng đủ. (Bản trước so với kích
  /// thước ước lượng, mà config.json thật chỉ vài KB trong khi ước lượng làm
  /// tròn thành 0,01 MB — thành ra lần nào mở app cũng bảo là chưa tải.)
  Future<bool> isInstalled() async {
    for (final file in modelFiles) {
      final target = fileFor(file);
      if (!await target.exists()) return false;
      if (await target.length() == 0) return false;
    }
    return await dictFile.exists() && await voicesFile.exists();
  }

  Future<VieNeuPaths> paths() async {
    await _extractBundled();
    return VieNeuPaths(
      modelDir: modelDir.path,
      codecDir: codecDir.path,
      dictPath: dictFile.path,
      voicesPath: voicesFile.path,
    );
  }

  /// Chép từ điển và hồ sơ giọng từ trong ứng dụng ra đĩa.
  ///
  /// Thư viện Rust ánh xạ bộ nhớ file từ điển nên cần một đường dẫn thật, không
  /// đọc thẳng từ gói ứng dụng được.
  Future<void> _extractBundled() async {
    await root.create(recursive: true);
    for (final entry in _bundledAssets.entries) {
      final target = File(p.join(root.path, entry.value));
      final data = await rootBundle.load(entry.key);
      // So kích thước chứ không chỉ hỏi "đã có chưa": bản cập nhật có thể mang
      // từ điển mới, mà file cũ nằm sẵn trên đĩa thì bản mới không bao giờ tới
      // được người dùng.
      if (await target.exists() && await target.length() == data.lengthInBytes) {
        continue;
      }
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    await _extractBundledV2();
    await _hopNhatGiong();
  }

  /// Hoà hồ sơ giọng đi kèm bản cài với những giọng người dùng tự thêm.
  ///
  /// Bản trước chỉ chép giong.json khi trên đĩa chưa có file. Cài đè bản mới thì
  /// file cũ vẫn nằm đó, nên giọng mới thêm vào bản cài KHÔNG BAO GIỜ hiện ra —
  /// phải xoá sạch dữ liệu rồi tải lại mô hình mới thấy.
  ///
  /// Nhưng cũng không chép đè được: chính file này là chỗ thư viện Rust ghi
  /// giọng người dùng nhân bản từ mẫu ghi âm, đè lên là mất hết. Nên hợp nhất —
  /// giọng đi kèm lấy theo bản cài mới, giọng tự thêm giữ nguyên. Trùng tên thì
  /// giọng tự thêm thắng, vì đó là công người dùng bỏ ra.
  Future<void> _hopNhatGiong() async {
    Map<String, dynamic> doc(String text) {
      final v = jsonDecode(text);
      return v is Map<String, dynamic> ? v : <String, dynamic>{};
    }

    final goc = doc(await rootBundle.loadString('assets/giong.json'));
    final gocPresets = (goc['presets'] as Map<String, dynamic>?) ?? {};

    final tuThem = <String, dynamic>{};
    Map<String, dynamic> tren = {};
    if (await voicesFile.exists() && await voicesFile.length() > 0) {
      try {
        tren = (doc(await voicesFile.readAsString())['presets'] as Map<String, dynamic>?) ?? {};
        tren.forEach((ten, v) {
          if (v is Map && v['source'] == nhanTuThem) tuThem[ten] = v;
        });
      } catch (_) {
        // File hỏng thì dựng lại từ bản đi kèm, còn hơn để ứng dụng không có giọng nào.
      }
    }

    final ketQua = {...gocPresets, ...tuThem};
    // Sắp tên trước khi so: thư viện Rust ghi lại file bằng bộ ánh xạ có sắp
    // xếp, thứ tự khoá khác bản này nên so thẳng chuỗi là lần nào cũng thấy khác.
    String chuanHoa(Map<String, dynamic> m) {
      final ten = m.keys.toList()..sort();
      return jsonEncode({for (final t in ten) t: m[t]});
    }

    if (chuanHoa(ketQua) == chuanHoa(tren)) return;
    await voicesFile.writeAsString(
      jsonEncode({...goc, 'presets': ketQua}),
      flush: true,
    );
  }

  /// Đã có đủ hai mô hình phụ để nhân bản giọng chưa.
  Future<bool> canEnroll() async {
    for (final file in enrollFiles) {
      final target = fileFor(file);
      if (!await target.exists() || await target.length() == 0) return false;
    }
    return true;
  }

  /// Tải hai mô hình chỉ dùng cho việc thêm giọng.
  Future<void> downloadEnrollModels({
    required void Function(WorkProgress) onProgress,
    http.Client? client,
  }) => _fetch(enrollFiles, enrollMegabytes, onProgress, client);

  /// Chép giọng nhân bản sẵn của v2 ra đĩa, cùng lý do như [_extractBundled].
  Future<void> _extractBundledV2() async {
    await v2Dir.create(recursive: true);
    for (final entry in _bundledV2Assets.entries) {
      final target = File(p.join(v2Dir.path, entry.value));
      final data = await rootBundle.load(entry.key);
      if (await target.exists() && await target.length() == data.lengthInBytes) {
        continue;
      }
      await target.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
  }

  /// Đường dẫn cho engine v2, đã chép sẵn phần đi kèm ứng dụng.
  Future<VieNeuV2Paths> v2Paths({int threads = 0}) async {
    await _extractBundled();
    return VieNeuV2Paths(
      ggufPath: v2Gguf.path,
      codecPath: v2Codec.path,
      voicesPath: v2Voices.path,
      extraVoicesPath: v2ExtraVoices.path,
      userVoicesPath: v2UserVoices.path,
      dictPath: dictFile.path,
      threads: threads,
    );
  }

  /// Đã có bộ mã hoá để thêm giọng cho v2 chưa.
  Future<bool> canEnrollV2() async =>
      await v2Encoder.exists() && await v2Encoder.length() > 0;

  /// Tải bộ mã hoá NeuCodec — chỉ cần khi thêm giọng.
  Future<void> downloadV2Encoder({
    required void Function(WorkProgress) onProgress,
    http.Client? client,
  }) =>
      _fetch(v2EncoderFiles, v2EncoderMegabytes, onProgress, client);

  /// Đủ file để chạy engine v2 chưa.
  Future<bool> isV2Installed() async {
    for (final file in v2ModelFiles) {
      final target = fileFor(file);
      if (!await target.exists() || await target.length() == 0) return false;
    }
    // Từ điển âm vị dùng chung với v3, nhưng v2 chạy được mà không cần mô hình
    // v3 — nên vẫn phải kiểm riêng chứ đừng suy từ isInstalled().
    return await dictFile.exists();
  }

  /// Tải bộ file của engine v2.
  Future<void> downloadV2({
    required void Function(WorkProgress) onProgress,
    http.Client? client,
  }) async {
    await _fetch(v2ModelFiles, v2Megabytes, onProgress, client);
    onProgress(const WorkProgress('Đang chuẩn bị từ điển…', value: 0.99));
    await _extractBundled();
    onProgress(const WorkProgress('Xong', value: 1));
  }

  /// Xoá bộ file của engine v2, giữ nguyên v3.
  Future<void> deleteV2() async {
    if (await v2Dir.exists()) await v2Dir.delete(recursive: true);
  }

  /// Tải toàn bộ mô hình. Bỏ qua file đã có.
  Future<void> download({
    required void Function(WorkProgress) onProgress,
    http.Client? client,
  }) async {
    await _fetch(modelFiles, totalMegabytes, onProgress, client);
    onProgress(const WorkProgress('Đang chuẩn bị từ điển…', value: 0.99));
    await _extractBundled();
    onProgress(const WorkProgress('Xong', value: 1));
  }

  Future<void> _fetch(
    List<ModelFile> files,
    double total,
    void Function(WorkProgress) onProgress,
    http.Client? client,
  ) async {
    final web = client ?? http.Client();
    await modelDir.create(recursive: true);
    await codecDir.create(recursive: true);
    await enrollDir.create(recursive: true);
    await v2Dir.create(recursive: true);
    var done = 0.0;

    for (final file in files) {
      final target = fileFor(file);
      // Cùng lý do như isInstalled: có tên thật nghĩa là đã tải xong.
      if (await target.exists() && await target.length() > 0) {
        done += file.megabytes;
        continue;
      }

      onProgress(WorkProgress('Đang tải ${file.name}', value: done / total));

      // Ghi ra file tạm rồi đổi tên: đứt mạng giữa chừng không để lại file hỏng.
      final temp = File('${target.path}.part');
      final request = http.Request('GET', Uri.parse(file.url));
      final response = await web.send(request);
      if (response.statusCode != 200) {
        throw Exception('Tải ${file.name} lỗi ${response.statusCode}');
      }

      final expected = response.contentLength ?? (file.megabytes * 1024 * 1024).round();
      final sink = temp.openWrite();
      var received = 0;
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        final share = expected == 0 ? 0.0 : received / expected;
        onProgress(WorkProgress(
          'Đang tải ${file.name} — ${(received / 1024 / 1024).toStringAsFixed(0)}'
          '/${file.megabytes.toStringAsFixed(0)} MB',
          value: (done + file.megabytes * share) / total,
        ));
      }
      await sink.flush();
      await sink.close();

      if (await target.exists()) await target.delete();
      await temp.rename(target.path);
      done += file.megabytes;
    }

    if (client == null) web.close();
  }

  Future<void> delete() async {
    if (await modelDir.exists()) await modelDir.delete(recursive: true);
    if (await codecDir.exists()) await codecDir.delete(recursive: true);
  }

  /// Thông tin hiển thị của từng giọng, đọc từ file hồ sơ.
  ///
  /// Chỉ đọc, không dựng file: engine luôn gọi [paths] trước khi hỏi tới đây,
  /// mà chính [paths] mới là chỗ chép file đi kèm ra và hợp nhất hồ sơ giọng.
  Future<Map<String, VoiceMeta>> voiceMeta() async {
    try {
      final json = jsonDecode(await voicesFile.readAsString()) as Map<String, dynamic>;
      final presets = json['presets'] as Map<String, dynamic>? ?? {};
      return presets.map((name, value) {
        final data = value as Map<String, dynamic>;
        return MapEntry(
          name,
          VoiceMeta(
            gender: _genders[data['gender']] ?? '',
            description: data['description'] as String? ?? '',
            // Giọng tự thêm mới xoá được. Hai nguồn ghi dấu khác nhau: thêm
            // trong ứng dụng thì thư viện Rust ghi "nguoi-dung" (và chính nó
            // cũng chỉ cho xoá đúng những giọng mang dấu ấy), còn nap_giong.py
            // bên máy tính ghi tên file mẫu. Bản trước chỉ xét đuôi .wav nên
            // giọng thêm trong ứng dụng không bao giờ hiện nút xoá.
            builtIn: !_tuThem(data['source'] as String? ?? ''),
          ),
        );
      });
    } catch (_) {
      return {};
    }
  }
}
