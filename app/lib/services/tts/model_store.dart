/// Quản lý bộ file mô hình trên máy: kiểm tra, tải về, xoá đi.
///
/// Mô hình nặng khoảng 145 MB nên không nhét vào bản cài; ứng dụng tải một lần
/// rồi dùng offline mãi. Từ điển âm vị thì đi kèm sẵn trong ứng dụng vì không
/// có nguồn tải công khai nào ổn định.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../../models/work_progress.dart';
import '../storage.dart';
import 'vieneu_native.dart';
import 'vieneu_v2_native.dart';

/// Nơi tải mô hình: bản sao do chính dự án giữ, không phải nguồn gốc.
///
/// Trước đây tải thẳng từ HuggingFace và đã trả giá: repo
/// `neuphonic/neucodec-onnx-decoder-int8` chuyển sang chế độ hạn chế truy cập,
/// máy chủ trả 401, và **mọi người dùng mất khả năng tải engine v2** — không ai
/// sửa được gì vì đó là quyết định của bên thứ ba.
///
/// Các file ở kho này là bản sao nguyên vẹn, giấy phép và ghi công đầy đủ trong
/// README của nó. Toàn bộ nguồn gốc đều là Apache-2.0, cho phép phân phối lại.
const _khoMoHinh = 'https://github.com/ducvd89/sach-luoi-models/releases/download/v1';

/// Một gói mô hình: tải đúng MỘT file nén rồi bung ra.
///
/// Trước đây tải rời từng file (v3 có tới 9 file). Gộp thành một gói vừa ít
/// lượt kết nối hơn, vừa bỏ được cả một lớp lỗi: tải rời mà đứt ở file thứ bảy
/// thì thư mục còn lại một mớ dở dang mà `isInstalled` vẫn có thể nhìn nhầm
/// thành đủ.
class ModelPack {
  const ModelPack({
    required this.ten,
    required this.tep,
    required this.megabytes,
    required this.canCo,
  });

  /// Tên hiển thị lúc tải.
  final String ten;

  /// Tên file trong kho phát hành.
  final String tep;

  final double megabytes;

  /// Các file phải có sau khi bung, tính từ thư mục đích. Dùng để biết gói đã
  /// cài xong chưa — bung dở thì thiếu file và lần sau tải lại.
  final List<String> canCo;

  String get url => '$_khoMoHinh/$tep';
}

/// Mô hình chính của v3 Turbo: mạng sinh âm + bộ giải mã âm.
///
/// Bung vào thư mục gốc, bên trong gói đã chia sẵn `model/` và `codec/`.
const goiV3 = ModelPack(
  ten: 'mô hình v3 Turbo',
  tep: 'vieneu-v3.zip',
  megabytes: 145.4,
  canCo: [
    'model/vieneu_prefill.onnx',
    'model/vieneu_decode_step.onnx',
    'model/vieneu_acoustic_cached.onnx',
    'model/vieneu_backbone_shared.data',
    'model/vieneu_v3_heads.npz',
    'model/config.json',
    'model/tokenizer.json',
    // Bản `_step` giải mã theo cửa sổ cuốn chiếu chứ không nuốt cả đoạn một
    // lượt: ra đúng từng mẫu như bản `_full` nhưng thời gian tuyến tính và bộ
    // nhớ có trần (xem KHUNG_MOI_LUOT trong native/vieneu/src/engine.rs).
    'codec/moss_audio_tokenizer_decode_step.onnx',
    'codec/moss_audio_tokenizer_decode_shared.data',
  ],
);

/// Chỉ cần khi thêm giọng cho v3 — ai không dùng khỏi tốn.
const goiV3Enroll = ModelPack(
  ten: 'bộ thêm giọng v3',
  tep: 'vieneu-v3-enroll.zip',
  megabytes: 70.2,
  canCo: [
    'speaker_encoder.onnx',
    'moss_audio_tokenizer_encode.onnx',
    'moss_audio_tokenizer_encode.data',
  ],
);

/// Mô hình của engine VieNeu **v2**.
///
/// Chỉ ba file, ít hơn hẳn v3: trọng số nằm gọn trong một file GGUF thay vì bị
/// chẻ ra thành đồ thị ONNX nhiều mảnh, còn bộ giải mã âm là NeuCodec một file.
///
/// Nặng hơn v3 mà chủ yếu do bộ giải mã: 298 MB cho riêng nó, trong khi phần mô
/// hình ngôn ngữ Q4 chỉ 189 MB dù gấp ba tham số.
const goiV2 = ModelPack(
  ten: 'mô hình v2',
  tep: 'vieneu-v2.zip',
  megabytes: 478.2,
  canCo: [
    'VieNeu-TTS-v2-Q4-K-M.gguf',
    'neucodec_decoder_int8.onnx',
    'voices.json',
  ],
);

/// Bộ mã hoá NeuCodec — chỉ cần khi THÊM giọng cho v2.
///
/// Nặng hơn cả mô hình. Đây là bản **distil** của Neuphonic (encoder gốc còn to
/// hơn), và code nó sinh ra tương thích với bộ giải mã đang dùng — đã kiểm bằng
/// cách nhân bản rồi đọc lại.
const goiV2Encoder = ModelPack(
  ten: 'bộ mã hoá giọng v2',
  tep: 'vieneu-v2-encoder.zip',
  megabytes: 494.6,
  canCo: [
    'distill_neucodec_encoder.onnx',
    // Trọng số ngoài của đồ thị trên — ONNX Runtime tự tìm nó CẠNH file .onnx
    // theo đúng tên này, nên hai file phải nằm chung thư mục.
    'distill_neucodec_encoder.onnx.data',
  ],
);

/// Tên một mục trong gói nén, đã chuẩn hoá về dấu phân cách "/".
///
/// Đặc tả zip bắt dùng "/" (APPNOTE mục 4.4.17.1) nhưng vài công cụ nén trên
/// Windows vẫn ghi dấu gạch ngược. Khi ấy Android coi cả cụm
/// `model\config.json` là TÊN FILE nằm ở thư mục gốc: bung xong không lỗi gì,
/// chỉ có phép kiểm đủ file trượt với "vẫn thiếu file". Windows không lộ ra vì
/// dấu gạch ngược ở đó cũng là dấu phân cách — nên lỗi này chỉ hiện trên điện
/// thoại, và chỉ với gói có thư mục con (gói v2 phẳng nên thoát).
String tenTrongGoi(String ten) => ten.replaceAll(r'\', '/');

double get totalMegabytes => goiV3.megabytes;
double get v2EncoderMegabytes => goiV2Encoder.megabytes;
double get enrollMegabytes => goiV3Enroll.megabytes;
double get v2Megabytes => goiV2.megabytes;

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

  /// Gói đã bung đủ file vào [dich] chưa.
  ///
  /// Chỉ xét có file và file khác rỗng. Gói tải dở luôn mang đuôi .part và chỉ
  /// được bung khi đã tải trọn, nên sự tồn tại của các file thật là bằng chứng
  /// đủ. (Đừng so với kích thước khai báo: config.json thật chỉ vài KB trong
  /// khi số khai báo làm tròn thành 0,01 MB — bản trước vì thế mà lần nào mở
  /// app cũng bảo là chưa tải.)
  Future<bool> _duFile(ModelPack goi, Directory dich) async {
    for (final ten in goi.canCo) {
      final f = File(p.join(dich.path, ten));
      if (!await f.exists() || await f.length() == 0) return false;
    }
    return true;
  }

  /// Đủ file để chạy chưa.
  ///
  /// Chỉ xét có file và file khác rỗng, KHÔNG so với kích thước khai báo. File
  /// tải dở luôn mang đuôi .part và chỉ được đổi sang tên thật khi đã tải xong,
  /// nên sự tồn tại của tên thật đã là bằng chứng đủ. (Bản trước so với kích
  /// thước ước lượng, mà config.json thật chỉ vài KB trong khi ước lượng làm
  /// tròn thành 0,01 MB — thành ra lần nào mở app cũng bảo là chưa tải.)
  Future<bool> isInstalled() async {
    if (!await _duFile(goiV3, root)) return false;
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
  Future<bool> canEnroll() => _duFile(goiV3Enroll, enrollDir);

  /// Tải hai mô hình chỉ dùng cho việc thêm giọng.
  Future<void> downloadEnrollModels({
    required void Function(WorkProgress) onProgress,
    http.Client? client,
  }) => _taiGoi(goiV3Enroll, enrollDir, onProgress, client);

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
      _taiGoi(goiV2Encoder, v2Dir, onProgress, client);

  /// Đủ file để chạy engine v2 chưa.
  Future<bool> isV2Installed() async {
    if (!await _duFile(goiV2, v2Dir)) return false;
    // Từ điển âm vị dùng chung với v3, nhưng v2 chạy được mà không cần mô hình
    // v3 — nên vẫn phải kiểm riêng chứ đừng suy từ isInstalled().
    return await dictFile.exists();
  }

  /// Tải bộ file của engine v2.
  Future<void> downloadV2({
    required void Function(WorkProgress) onProgress,
    http.Client? client,
  }) async {
    await _taiGoi(goiV2, v2Dir, onProgress, client);
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
    await _taiGoi(goiV3, root, onProgress, client);
    onProgress(const WorkProgress('Đang chuẩn bị từ điển…', value: 0.99));
    await _extractBundled();
    onProgress(const WorkProgress('Xong', value: 1));
  }

  /// Tải một gói rồi bung vào [dich].
  ///
  /// Ghi ra file `.part` trước, bung xong mới xoá: đứt mạng giữa chừng thì
  /// không để lại thư mục nửa vời mà lần sau tưởng là đã cài.
  ///
  /// **Bung theo luồng, không nạp cả gói vào RAM.** Gói v2 nặng 478 MB — đọc
  /// hết vào một `List<int>` rồi mới giải nén là chắc chắn hết bộ nhớ trên điện
  /// thoại.
  Future<void> _taiGoi(
    ModelPack goi,
    Directory dich,
    void Function(WorkProgress) onProgress,
    http.Client? client,
  ) async {
    if (await _duFile(goi, dich)) return;

    final web = client ?? http.Client();
    await dich.create(recursive: true);
    final tam = File(p.join(dich.path, '${goi.tep}.part'));

    try {
      onProgress(WorkProgress('Đang tải ${goi.ten}', value: 0));
      final response = await web.send(http.Request('GET', Uri.parse(goi.url)));
      if (response.statusCode != 200) {
        throw Exception('Tải ${goi.ten} lỗi ${response.statusCode}');
      }

      final expected =
          response.contentLength ?? (goi.megabytes * 1024 * 1024).round();
      final sink = tam.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(WorkProgress(
            'Đang tải ${goi.ten} — ${(received / 1024 / 1024).toStringAsFixed(0)}'
            '/${goi.megabytes.toStringAsFixed(0)} MB',
            // Chừa 8% cuối cho việc bung gói.
            value: expected == 0 ? 0 : (received / expected) * 0.92,
          ));
        }
      } finally {
        await sink.flush();
        await sink.close();
      }

      onProgress(WorkProgress('Đang bung ${goi.ten}…', value: 0.93));
      await _bungGoi(tam, dich);

      if (!await _duFile(goi, dich)) {
        throw Exception('Bung ${goi.ten} xong nhưng vẫn thiếu file');
      }
    } finally {
      if (await tam.exists()) await tam.delete();
      if (client == null) web.close();
    }
  }

  /// Xoá mô hình v3, giữ nguyên v2 và từ điển.
  Future<void> delete() async {
    if (await modelDir.exists()) await modelDir.delete(recursive: true);
    if (await codecDir.exists()) await codecDir.delete(recursive: true);
  }

  /// Bung một file zip vào [dich], đọc và ghi theo luồng.
  Future<void> _bungGoi(File zip, Directory dich) async {
    final nguon = InputFileStream(zip.path);
    try {
      for (final muc in ZipDecoder().decodeStream(nguon)) {
        if (!muc.isFile) continue;
        final ten = tenTrongGoi(muc.name);
        // Chặn đường dẫn leo ra ngoài thư mục đích ("zip slip"). Gói là của
        // mình nên không chờ đợi chuyện này, nhưng một dòng kiểm thì rẻ mà bỏ
        // được cả một lớp rủi ro.
        final ra = File(p.normalize(p.join(dich.path, ten)));
        if (!p.isWithin(dich.path, ra.path)) continue;

        await ra.parent.create(recursive: true);
        final oStream = OutputFileStream(ra.path);
        try {
          muc.writeContent(oStream);
        } finally {
          await oStream.close();
        }
      }
    } finally {
      await nguon.close();
    }
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
