/// Kiểm thử phần đọc lại khi xuất file: đoạn nào số âm không khớp số từ thì
/// đọc lại, hết lượt vẫn lệch thì lấy bản gần đúng nhất.
///
/// Engine giả ở đây sinh ra đúng số "âm" mà bài test muốn, nên soi được hành vi
/// mà không cần mô hình thật.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sach_noi/core/wav.dart';
import 'package:sach_noi/models/book.dart';
import 'package:sach_noi/models/export_job.dart';
import 'package:sach_noi/models/settings.dart';
import 'package:sach_noi/services/export_service.dart';
import 'package:sach_noi/services/storage.dart';
import 'package:sach_noi/services/tts/tts_engine.dart';
import 'package:sach_noi/services/tts/tts_manager.dart';

const _rate = 16000;

/// Sóng có [soAm] hạt âm rõ ràng, mỗi hạt là một đoạn sóng có thanh.
Float32List _chuoiAm(int soAm) {
  const amMau = _rate * 180 ~/ 1000;
  const nghiMau = _rate * 70 ~/ 1000;
  final out = Float32List(soAm * (amMau + nghiMau) + 1);
  var at = 0;
  for (var n = 0; n < soAm; n++) {
    for (var i = 0; i < amMau; i++) {
      final t = i / _rate;
      final bao = math.sin(math.pi * i / amMau);
      out[at + i] = 0.5 *
          bao *
          (math.sin(2 * math.pi * 130 * t) +
              0.5 * math.sin(4 * math.pi * 130 * t) +
              0.25 * math.sin(6 * math.pi * 130 * t));
    }
    at += amMau + nghiMau;
  }
  return out;
}

/// Engine giả: mỗi lần đọc trả về số âm do bài test đặt trước.
class _EngineGia implements TtsEngine {
  _EngineGia(this.soAmTheoLan, {this.raKhac = true});

  /// Số âm sẽ sinh ra ở lần đọc thứ 0, 1, 2… Hết danh sách thì lặp lại phần tử
  /// cuối.
  final List<int> soAmTheoLan;

  final bool raKhac;

  /// Đã đọc mấy lượt, tính cả các lần đọc lại.
  final lanDaGoi = <int>[];

  @override
  String get id => 'gia';
  @override
  String get displayName => 'Engine giả';
  @override
  bool get isLocal => true;
  @override
  String get description => '';
  @override
  String get audioFormat => 'wav';
  @override
  bool get docLaiRaKhac => raKhac;

  @override
  Future<EngineStatus> status() async => const EngineStatus(ready: true, message: 'Sẵn sàng');

  @override
  Future<List<TtsVoice>> voices() async =>
      [const TtsVoice(id: 'gia', name: 'Giả', gender: '')];

  @override
  Future<void> setBulkMode(bool on) async {}

  @override
  Future<TtsResult> synthesize({
    required String text,
    required String voiceId,
    double speed = 1.0,
    List<int>? nguCanh,
    int lanThu = 0,
  }) async {
    lanDaGoi.add(lanThu);
    final so = soAmTheoLan[math.min(lanThu, soAmTheoLan.length - 1)];
    final mau = _chuoiAm(so);
    return TtsResult(buildWav(mau, _rate), mau.length / _rate);
  }
}

/// Sách một đoạn mười từ — đủ dài để dùng dải 85-115%.
const _doan = 'Một hai ba bốn năm sáu bảy tám chín mười.';

void main() {
  // TtsManager dựng luôn engine TTS hệ thống, mà cái đó cần binding của Flutter
  // mới mở được kênh sang phía máy.
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory outDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sachnoi_xuat_');
    outDir = Directory('${root.path}${Platform.pathSeparator}ra');
    await Storage.init(overrideRoot: root);
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  /// Chạy một lượt xuất trọn vẹn với engine giả, trả về job đã xong.
  Future<ExportJob> xuat(_EngineGia engine) async {
    final tts = TtsManager(themEngine: [engine]);
    final service = ExportService(tts);
    addTearDown(service.dispose);

    final book = Book(
      id: 'sach',
      title: 'Sách thử',
      author: '',
      language: 'vi',
      sourceFile: '',
      format: 'txt',
      addedAt: DateTime.now(),
      chapters: const [
        Chapter(index: 0, title: 'Chương một', firstChunk: 0, chunkCount: 1, charCount: 40),
      ],
      chunkCount: 1,
      charCount: 40,
      expandNumbers: true,
    );
    final chunks = [
      const Chunk(index: 0, chapter: 0, display: _doan, speech: _doan, heading: false),
    ];

    final job = await service.createJob(
      book: book,
      settings: AppSettings(
        engineId: engine.id,
        voiceXuat: 'gia',
        exportFormat: ExportFormat.wav,
        splitMode: SplitMode.single,
        chunkPauseMs: 0,
      ),
      voiceName: 'Giả',
      outputDir: outDir.path,
      treeUri: '',
      fromChunk: 0,
      toChunk: 0,
    );

    await service.start(job, chunks, book.chapters);
    // start() chạy nền — chờ tới khi job xong.
    final hetGio = DateTime.now().add(const Duration(seconds: 30));
    while (job.isActive || service.isRunning(job.id)) {
      if (DateTime.now().isAfter(hetGio)) fail('job không kết thúc: ${job.status} ${job.error}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(job.status, JobStatus.done, reason: job.error ?? '');
    return job;
  }

  test('đọc đúng ngay lần đầu thì không đọc lại', () async {
    final engine = _EngineGia([10]);
    final job = await xuat(engine);

    expect(engine.lanDaGoi, [0]);
    expect(job.doanDocLai, 0);
    expect(job.doanChuaDat, 0);
  });

  test('lệch thì đọc lại tới khi đạt rồi dừng', () async {
    // Lần đầu nuốt mất một nửa, lần hai vẫn thiếu, lần ba đọc đúng.
    final engine = _EngineGia([5, 7, 10]);
    final job = await xuat(engine);

    expect(engine.lanDaGoi, [0, 1, 2], reason: 'phải dừng ngay khi có bản đạt');
    expect(job.doanDocLai, 1);
    expect(job.doanChuaDat, 0);
  });

  test('đọc lại tối đa năm lần rồi lấy bản gần đúng nhất', () async {
    // Không lần nào đạt; lần thứ tư (12 âm, tức 120%) là gần 10 nhất.
    final engine = _EngineGia([3, 20, 4, 12, 16, 5]);
    final job = await xuat(engine);

    expect(engine.lanDaGoi, [0, 1, 2, 3, 4, 5], reason: 'một lần đầu + năm lần đọc lại');
    expect(job.doanDocLai, 1);
    expect(job.doanChuaDat, 1);

    // File xuất ra phải đúng là bản 12 âm: 12 x 250 ms.
    final file = File('${outDir.path}${Platform.pathSeparator}${job.parts.single.fileName}');
    expect(await file.exists(), isTrue);
    expect(wavDuration(await file.readAsBytes()), closeTo(12 * 0.25, 0.05));
  });

  test('bản gần đúng nhất là bản đọc đầu thì vẫn tính là đã đọc lại', () async {
    // Lỗi cũ: đếm theo "bản được chọn là lần thứ mấy", nên năm lượt đọc lại
    // công cốc mà sổ sách vẫn ghi không đọc lại lần nào.
    final engine = _EngineGia([12, 20, 25, 30, 4, 3]);
    final job = await xuat(engine);

    expect(engine.lanDaGoi, [0, 1, 2, 3, 4, 5]);
    expect(job.doanDocLai, 1);
    expect(job.doanChuaDat, 1);

    final file = File('${outDir.path}${Platform.pathSeparator}${job.parts.single.fileName}');
    expect(wavDuration(await file.readAsBytes()), closeTo(12 * 0.25, 0.05));
  });

  test('engine đọc lại ra y hệt thì không đọc lại lần nào', () async {
    final engine = _EngineGia([4], raKhac: false);
    final job = await xuat(engine);

    expect(engine.lanDaGoi, [0], reason: 'đọc lại cũng ra đúng bản cũ, phí thời gian');
    expect(job.doanDocLai, 0);
  });
}
