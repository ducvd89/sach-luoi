/// Màn hình cài đặt: chọn engine, giọng đọc, thêm giọng riêng, dọn bộ nhớ đệm.
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/settings.dart';
import '../models/work_progress.dart';
import '../services/storage.dart';
import '../services/tts/model_store.dart';
import '../services/tts/voice_pack.dart';
import 'app_scope.dart';
import 'cuon_tay_cam.dart';
import 'nut_sac.dart';
import 'thanh_keo_tay_cam.dart';
import 'theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _cuon = ScrollController();
  ({int bytes, int files})? _cache;

  @override
  void dispose() {
    _cuon.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCache());
  }

  Future<void> _confirmRemoveVoice(BuildContext context, String name) async {
    final state = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Xoá giọng "$name"?'),
        content: const Text('Sách đã đọc bằng giọng này vẫn nghe được nhờ bộ nhớ đệm, '
            'nhưng phần chưa đọc sẽ phải chọn giọng khác.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      // Hai engine giữ giọng ở hai chỗ khác nhau nên phải gọi đúng bên.
      if (state.settings.engineId == 'vieneu_v2') {
        await state.removeVoiceV2(name);
      } else {
        await state.removeVoice(name);
      }
    } catch (err) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Không xoá được: $err')));
      }
    }
  }

  Future<void> _loadCache() async {
    final stats = await AppScope.read(context).cacheStats();
    if (mounted) setState(() => _cache = stats);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final settings = state.settings;
    final hint = Theme.of(context).hintColor;

    return CuonTayCam(
      controller: _cuon,
      child: ListView(
      controller: _cuon,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 26),
      children: [
        Text('Cài đặt', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 18),

        // -- Giọng đọc --------------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Giọng đọc', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 14),
                RadioGroup<String>(
                  groupValue: settings.engineId,
                  onChanged: (value) {
                    if (value != null) AppScope.read(context).setEngine(value);
                  },
                  // Giữ nguyên cách canh của Column bọc ngoài: RadioGroup chỉ
                  // thay chỗ giữ giá trị đang chọn, không được đổi bố cục.
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final engine in state.tts.engines)
                        RadioListTile<String>(
                          value: engine.id,
                          contentPadding: EdgeInsets.zero,
                          title: Text(engine.displayName, style: const TextStyle(fontSize: 14)),
                          subtitle:
                              Text(engine.description, style: TextStyle(fontSize: 12.5, color: hint)),
                        ),
                    ],
                  ),
                ),
                const Divider(height: 26),
                if (state.voices.isEmpty)
                  Text(
                    state.engineStatus.message,
                    style: TextStyle(fontSize: 13, color: hint),
                  )
                else ...[
                  // Chọn giọng nằm ở trang Nghe và trang Xuất file, mỗi trang một
                  // giọng riêng. Ở đây chỉ còn việc quản lý: xem có những giọng
                  // nào và xoá giọng tự thêm.
                  Text('Giọng đã có trên máy', style: TextStyle(fontSize: 12.5, color: hint)),
                  const SizedBox(height: 6),
                  for (final voice in state.voices)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text(
                        voice.gender.isEmpty ? voice.name : '${voice.name} · ${voice.gender}',
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: voice.description.isEmpty
                          ? null
                          : Text(voice.description, style: TextStyle(fontSize: 12.5, color: hint)),
                      // Giọng dựng sẵn không xoá được; chỉ giọng tự thêm mới có nút.
                      trailing: voice.builtIn
                          ? null
                          : IconButton(
                              tooltip: 'Xoá giọng này',
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () => _confirmRemoveVoice(context, voice.name),
                            ),
                    ),
                ],
                if (settings.engineId == 'vieneu' && state.voices.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  const _AddVoiceButton(),
                ],
                if (settings.engineId == 'vieneu_v2' && state.voices.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  const _AddVoiceV2Button(),
                ],
                if (settings.engineId == 'vieneu') ...[
                  const Divider(height: 26),
                  const _ModelSection(),
                ],
                if (settings.engineId == 'vieneu_v2') ...[
                  const Divider(height: 26),
                  const _ModelV2Section(),
                ],
                if (settings.engineId == 'piper') ...[
                  const Divider(height: 26),
                  const _VoicePackSection(),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // -- Cách đọc ---------------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Cách đọc', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                SwitchListTile(
                  value: settings.expandNumbers,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (value) async {
                    settings.expandNumbers = value;
                    await AppScope.read(context).saveSettings();
                  },
                  title: const Text('Chuẩn hoá số, ngày tháng và viết tắt', style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    '“1.234” → “một nghìn hai trăm ba mươi tư”, “20/11/1954” → “ngày hai mươi tháng mười một…”, '
                    '“PGS.TS” → “Phó giáo sư tiến sĩ”. Áp dụng cho sách nhập vào sau khi đổi.',
                    style: TextStyle(fontSize: 12.5, color: hint),
                  ),
                ),
                const Divider(height: 26),
                SwitchListTile(
                  value: settings.removeBoilerplate,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (value) async {
                    settings.removeBoilerplate = value;
                    await AppScope.read(context).saveSettings();
                  },
                  title: const Text('Bỏ quảng cáo và mục lục của trang đăng truyện',
                      style: TextStyle(fontSize: 14)),
                  subtitle: Text(
                    'Cắt tên trang web ở đầu chương, dòng ghi công người dịch/convert, lời kêu gọi '
                    'ủng hộ ở cuối chương, và cả chương mục lục dài. Sách cũ thì bấm nút chổi '
                    'trong Thư viện để dọn lại.',
                    style: TextStyle(fontSize: 12.5, color: hint),
                  ),
                ),
                const Divider(height: 26),
                const Text('Khoảng nghỉ giữa các đoạn', style: TextStyle(fontSize: 14)),
                const SizedBox(height: 2),
                Text(
                  'Nghỉ thêm một nhịp mỗi khi hết đoạn, dài hơn dấu chấm câu, cho đỡ dồn dập. '
                  'Hết một tiêu đề chương thì nghỉ lâu hơn nữa. Đổi là nghe thấy ngay, '
                  'không phải đọc lại cả cuốn sách.',
                  style: TextStyle(fontSize: 12.5, color: hint),
                ),
                Row(
                  children: [
                    Expanded(
                      child: ThanhKeoTayCam(
                        value: settings.chunkPauseMs.toDouble().clamp(0, 2000),
                        min: 0,
                        max: 2000,
                        divisions: 40,
                        label: settings.chunkPauseMs == 0
                            ? 'Không nghỉ'
                            : '${(settings.chunkPauseMs / 1000).toStringAsFixed(2)} giây',
                        onChanged: (value) {
                          settings.chunkPauseMs = value.round();
                          AppScope.read(context).notifySettingsChanged();
                        },
                        onChangeEnd: (_) => AppScope.read(context).saveSettings(),
                      ),
                    ),
                    SizedBox(
                      width: 92,
                      child: Text(
                        settings.chunkPauseMs == 0
                            ? 'Không nghỉ'
                            : '${(settings.chunkPauseMs / 1000).toStringAsFixed(2)} giây',
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // -- Dữ liệu ----------------------------------------------------------
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Dữ liệu', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text(
                  _cache == null
                      ? 'Đang tính dung lượng…'
                      : 'Bộ nhớ đệm: ${_cache!.files} đoạn âm thanh · ${formatBytes(_cache!.bytes)}',
                  style: TextStyle(fontSize: 13, color: hint),
                ),
                const SizedBox(height: 4),
                Text(
                  'Mỗi đoạn đã tạo được lưu lại nên nghe lại hoặc xuất file sau khi nghe sẽ gần như tức thì.',
                  style: TextStyle(fontSize: 12.5, color: hint),
                ),
                const Divider(height: 26),
                _CacheLimitPicker(onChanged: _loadCache),
                const SizedBox(height: 14),
                // Flexible + coGian chứ không Wrap: cửa sổ máy tính kéo hẹp thì
                // chữ trong nút co lại (thêm ...) thay vì tràn hay lùi dòng.
                Row(
                  children: [
                    Flexible(
                      child: NutSac(
                        nho: true,
                        coGian: true,
                        vienRong: true,
                        sac: SacNut.nguyHiem,
                        nhan: 'Xoá bộ nhớ đệm',
                        hinh: Icons.delete_sweep_outlined,
                        onNhan: () async {
                          await AppScope.read(context).clearCache();
                          await _loadCache();
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: NutSac(
                        nho: true,
                        coGian: true,
                        vienRong: true,
                        sac: SacNut.phu,
                        nhan: 'Mở thư mục dữ liệu',
                        hinh: Icons.folder_open_rounded,
                        onNhan: () {
                          if (Platform.isWindows) Process.run('explorer', [state.dataDirectory]);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SelectableText(state.dataDirectory, style: TextStyle(fontSize: 12, color: hint)),
              ],
            ),
          ),
        ),
      ],
      ),
    );
  }
}

/// Tải mô hình giọng đọc về máy — mục cài đặt duy nhất mà máy nào cũng cần.
///
/// Mô hình khoảng 206 MB nên không nhét vào bản cài; tải một lần rồi dùng
/// offline mãi. Từ điển âm vị thì đã đi kèm sẵn trong ứng dụng.
class _ModelSection extends StatefulWidget {
  const _ModelSection();

  @override
  State<_ModelSection> createState() => _ModelSectionState();
}

class _ModelSectionState extends State<_ModelSection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.read(context).refreshModelStatus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final hint = Theme.of(context).hintColor;
    final progress = state.modelProgress;
    final installed = state.modelInstalled;

    if (progress != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Đang tải mô hình giọng đọc', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(value: progress.value, minHeight: 5),
          ),
          const SizedBox(height: 6),
          Text('${progress.phase} · ${progress.percent}%',
              style: TextStyle(fontSize: 12.5, color: hint)),
        ],
      );
    }

    if (installed == true) {
      return Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 18, color: Colors.green),
          const SizedBox(width: 9),
          Expanded(
            child: Text('Mô hình đã có trên máy — đọc được khi không có mạng',
                style: TextStyle(fontSize: 13, color: hint)),
          ),
          TextButton(
            onPressed: () => _confirmDelete(context),
            child: const Text('Xoá mô hình'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cần tải mô hình về máy một lần (~${totalMegabytes.round()} MB). Sau đó đọc được '
          'hoàn toàn không cần mạng, kể cả khi để máy bay.',
          style: TextStyle(fontSize: 12.5, color: hint),
        ),
        const SizedBox(height: 10),
        NutSac(
          nhan: 'TẢI MÔ HÌNH (${totalMegabytes.round()} MB)',
          hinh: Icons.arrow_downward_rounded,
          onNhan: installed == null ? null : () => AppScope.read(context).downloadModel(),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final state = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xoá mô hình?'),
        content: const Text('Giải phóng khoảng 206 MB. Muốn nghe offline lại thì phải tải lại.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok == true) await state.deleteModel();
  }
}

/// Tải bộ file của engine v2.
///
/// Tách khỏi [_ModelSection] vì hai engine tải riêng và nặng khác nhau hẳn: v3
/// là 206 MB, v2 là 478 MB — mà phần lớn chỗ chênh nằm ở bộ giải mã NeuCodec
/// (298 MB) chứ không phải ở mô hình ngôn ngữ.
class _ModelV2Section extends StatefulWidget {
  const _ModelV2Section();

  @override
  State<_ModelV2Section> createState() => _ModelV2SectionState();
}

class _ModelV2SectionState extends State<_ModelV2Section> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.read(context).refreshV2Status();
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final hint = Theme.of(context).hintColor;
    final progress = state.modelProgress;
    final installed = state.v2Installed;

    if (progress != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Đang tải mô hình v2', style: TextStyle(fontSize: 14)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(value: progress.value, minHeight: 5),
          ),
          const SizedBox(height: 6),
          Text('${progress.phase} · ${progress.percent}%',
              style: TextStyle(fontSize: 12.5, color: hint)),
        ],
      );
    }

    if (installed == true) {
      return Row(
        children: [
          const Icon(Icons.check_circle_outline, size: 18, color: Colors.green),
          const SizedBox(width: 9),
          Expanded(
            child: Text('Mô hình v2 đã có trên máy — đọc được khi không có mạng',
                style: TextStyle(fontSize: 13, color: hint)),
          ),
          TextButton(
            onPressed: () => _confirmDelete(context),
            child: const Text('Xoá mô hình v2'),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Cần tải mô hình v2 về máy một lần (~${v2Megabytes.round()} MB). Nặng hơn v3 Turbo '
          'nhưng đọc tự nhiên hơn và xử lý được tiếng Anh xen kẽ.',
          style: TextStyle(fontSize: 12.5, color: hint),
        ),
        const SizedBox(height: 10),
        NutSac(
          nhan: 'TẢI MÔ HÌNH V2 (${v2Megabytes.round()} MB)',
          hinh: Icons.arrow_downward_rounded,
          onNhan: installed == null ? null : () => AppScope.read(context).downloadV2Model(),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final state = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xoá mô hình v2?'),
        content: Text('Giải phóng khoảng ${v2Megabytes.round()} MB. '
            'Mô hình v3 Turbo không bị ảnh hưởng.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok == true) await state.deleteV2Model();
  }
}

/// Gói giọng của engine nhẹ: tải về, xoá đi.
///
/// Khác mục mô hình VieNeu ở chỗ mỗi giọng là một gói riêng, tải cái nào dùng
/// cái đó — máy yếu chỉ cần gói 21 MB là đọc được.
class _VoicePackSection extends StatefulWidget {
  const _VoicePackSection();

  @override
  State<_VoicePackSection> createState() => _VoicePackSectionState();
}

class _VoicePackSectionState extends State<_VoicePackSection> {
  String? _downloading;
  WorkProgress? _progress;

  Future<void> _download(VoicePack pack) async {
    setState(() {
      _downloading = pack.folder;
      _progress = const WorkProgress('Đang chuẩn bị…');
    });
    try {
      await downloadVoicePack(pack, onProgress: (p) {
        if (mounted) setState(() => _progress = p);
      });
      if (mounted) await AppScope.read(context).refreshEngine();
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Tải gói giọng lỗi: $err')),
        );
      }
    } finally {
      if (mounted) setState(() { _downloading = null; _progress = null; });
    }
  }

  Future<void> _delete(VoicePack pack) async {
    await deleteVoicePack(pack.folder);
    if (mounted) await AppScope.read(context).refreshEngine();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Gói giọng tải về máy', style: TextStyle(fontSize: 12.5, color: hint)),
        const SizedBox(height: 2),
        Text('Tải một lần rồi dùng offline mãi. Cùng gói này chạy được trên điện thoại.',
            style: TextStyle(fontSize: 12.5, color: hint)),
        const SizedBox(height: 8),
        for (final pack in availableVoicePacks) _row(pack, hint),
      ],
    );
  }

  Widget _row(VoicePack pack, Color hint) {
    final installed = findVoicePack(pack.folder) != null;
    final busy = _downloading == pack.folder;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(installed ? Icons.check_circle_outline : Icons.download_outlined,
                  size: 18, color: installed ? Colors.green : hint),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${pack.name} · ${pack.gender}', style: const TextStyle(fontSize: 14)),
                    Text('${pack.description} · ${pack.megabytes} MB',
                        style: TextStyle(fontSize: 12.5, color: hint)),
                  ],
                ),
              ),
              if (installed)
                TextButton(onPressed: busy ? null : () => _delete(pack), child: const Text('Xoá'))
              else
                NutSac(
                  nho: true,
                  nhan: busy ? 'Đang tải…' : 'Tải về',
                  hinh: Icons.arrow_downward_rounded,
                  dangChay: busy,
                  onNhan: _downloading != null ? null : () => _download(pack),
                ),
            ],
          ),
          if (busy) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(value: _progress?.value, minHeight: 4),
            ),
            const SizedBox(height: 4),
            Text(_progress?.phase ?? '', style: TextStyle(fontSize: 12, color: hint)),
          ],
        ],
      ),
    );
  }
}

/// Nút thêm giọng mới từ một file ghi âm.
///
/// Mẫu tốt nhất là 3–15 giây, một người nói rõ ràng, không nhạc nền. Lần đầu
/// dùng sẽ tải thêm hai mô hình phụ (~70 MB) — chỉ ai thêm giọng mới phải tải.
class _AddVoiceButton extends StatelessWidget {
  const _AddVoiceButton();

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NutSac(
          nhan: 'THÊM GIỌNG TỪ FILE GHI ÂM',
          hinh: Icons.person_add_alt_1_rounded,
          sac: SacNut.them,
          vienRong: true,
          onNhan: () => _pick(context),
        ),
        const SizedBox(height: 4),
        Text('File .wav một người nói rõ, không nhạc nền. Bản ghi dài cũng được — '
            'ứng dụng tự chọn đoạn 8 giây sạch tiếng nhất trong đó.',
            style: TextStyle(fontSize: 12.5, color: hint)),
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav'],
      dialogTitle: 'Chọn file ghi âm mẫu',
    );
    final path = picked?.files.singleOrNull?.path;
    if (path == null || !context.mounted) return;

    final suggestion = p.basenameWithoutExtension(path);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(suggestion: suggestion),
    );
    if (name == null || name.trim().isEmpty) return;

    try {
      await state.addVoice(name: name.trim(), wavPath: path);
      messenger.showSnackBar(SnackBar(content: Text('Đã thêm giọng "$name"')));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('Không thêm được giọng: $err')));
    }
  }
}

/// Thêm giọng cho engine v2 — khác v3 ở chỗ **bắt buộc nhập lời**.
///
/// v3 trích được vector đặc trưng người nói từ riêng sóng âm nên chỉ cần file
/// ghi âm. v2 thì nhận cặp *mã tham chiếu + lời của đúng đoạn ấy*: mô hình đọc
/// lời để biết đoạn mã kia ứng với những âm nào. Lời sai là nó học nhầm cách
/// phát âm, chứ không phải chỉ giống giọng ít đi một chút.
///
/// Cũng vì thế mà KHÔNG tự cắt đoạn 8 giây sạch tiếng như v3 — cắt audio mà giữ
/// nguyên lời là hai thứ lệch nhau.
class _AddVoiceV2Button extends StatelessWidget {
  const _AddVoiceV2Button();

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NutSac(
          nhan: 'THÊM GIỌNG TỪ FILE GHI ÂM',
          hinh: Icons.person_add_alt_1_rounded,
          sac: SacNut.them,
          vienRong: true,
          onNhan: () => _pick(context),
        ),
        const SizedBox(height: 4),
        Text('File .wav 3–10 giây, một người nói rõ, không nhạc nền. Phải chép đúng lời '
            'trong đoạn ghi âm — v2 dựa vào lời để bắt giọng.',
            style: TextStyle(fontSize: 12.5, color: hint)),
      ],
    );
  }

  Future<void> _pick(BuildContext context) async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);

    // Bộ mã hoá nặng 519 MB và chỉ dùng lúc thêm giọng — ai không thêm khỏi tải.
    if (!await state.tts.modelStore.canEnrollV2()) {
      if (!context.mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Cần tải thêm bộ mã hoá'),
          content: Text('Để nhân bản giọng cho v2 cần tải bộ mã hoá '
              '${v2EncoderMegabytes.round()} MB. Chỉ tải một lần.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Tải')),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await state.downloadV2Encoder();
      } catch (err) {
        messenger.showSnackBar(SnackBar(content: Text('Không tải được bộ mã hoá: $err')));
        return;
      }
    }

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav'],
      dialogTitle: 'Chọn file ghi âm mẫu',
    );
    final path = picked?.files.singleOrNull?.path;
    if (path == null || !context.mounted) return;

    final ketQua = await showDialog<({String name, String text})>(
      context: context,
      builder: (context) => _NameAndTextDialog(suggestion: p.basenameWithoutExtension(path)),
    );
    if (ketQua == null) return;

    try {
      await state.addVoiceV2(name: ketQua.name, wavPath: path, text: ketQua.text);
      messenger.showSnackBar(SnackBar(content: Text('Đã thêm giọng "${ketQua.name}"')));
    } catch (err) {
      messenger.showSnackBar(SnackBar(content: Text('Không thêm được giọng: $err')));
    }
  }
}

/// Hỏi tên giọng và lời của đoạn ghi âm.
class _NameAndTextDialog extends StatefulWidget {
  const _NameAndTextDialog({required this.suggestion});
  final String suggestion;

  @override
  State<_NameAndTextDialog> createState() => _NameAndTextDialogState();
}

class _NameAndTextDialogState extends State<_NameAndTextDialog> {
  late final _ten = TextEditingController(text: widget.suggestion);
  final _loi = TextEditingController();

  @override
  void dispose() {
    _ten.dispose();
    _loi.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return AlertDialog(
      title: const Text('Thêm giọng'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ten,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Tên giọng'),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _loi,
            maxLines: 4,
            minLines: 3,
            decoration: const InputDecoration(
              labelText: 'Lời trong đoạn ghi âm',
              alignLabelWithHint: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 6),
          Text('Chép đúng từng chữ nghe thấy trong file. Số thì viết thành chữ '
              '("8.000" → "tám nghìn").',
              style: TextStyle(fontSize: 12.5, color: hint)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
        FilledButton(
          onPressed: _ten.text.trim().isEmpty || _loi.text.trim().isEmpty
              ? null
              : () => Navigator.pop(context, (name: _ten.text.trim(), text: _loi.text.trim())),
          child: const Text('Thêm'),
        ),
      ],
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.suggestion});
  final String suggestion;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _controller = TextEditingController(text: widget.suggestion);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Đặt tên cho giọng'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Ví dụ: Bố, Mẹ, Việt Sử…'),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: const Text('Thêm'),
        ),
      ],
    );
  }
}

/// Chọn trần dung lượng bộ nhớ đệm.
///
/// Vượt trần thì đoạn cũ nhất bị xoá trước — đoạn đang nghe hay nghe lại luôn
/// được chạm vào nên coi là mới, còn đoạn của cuốn sách bỏ dở thì nhường chỗ.
class _CacheLimitPicker extends StatefulWidget {
  const _CacheLimitPicker({required this.onChanged});

  /// Gọi sau khi dọn xong để mục dung lượng phía trên cập nhật lại.
  final Future<void> Function() onChanged;

  @override
  State<_CacheLimitPicker> createState() => _CacheLimitPickerState();
}

class _CacheLimitPickerState extends State<_CacheLimitPicker> {
  bool _busy = false;

  static String _label(int megabytes) {
    if (megabytes <= 0) return 'Không hạn';
    if (megabytes >= 1024) return '${(megabytes / 1024).toStringAsFixed(megabytes % 1024 == 0 ? 0 : 1)} GB';
    return '$megabytes MB';
  }

  Future<void> _pick(int megabytes) async {
    final state = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final removed = await state.setCacheLimit(megabytes);
      await widget.onChanged();
      if (removed > 0) {
        messenger.showSnackBar(
          SnackBar(content: Text('Đã dọn ${formatBytes(removed)} đoạn cũ nhất')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final hint = Theme.of(context).hintColor;
    final scheme = Theme.of(context).colorScheme;
    final current = state.settings.cacheLimitMb;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Dung lượng tối đa', style: TextStyle(fontSize: 14)),
        const SizedBox(height: 2),
        Text(
          'Vượt mức này thì các đoạn lâu không nghe bị xoá trước. Xoá rồi nghe lại '
          'thì máy đọc lại đoạn đó, chỉ mất thời gian chứ không mất gì.',
          style: TextStyle(fontSize: 12.5, color: hint),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final choice in cacheLimitChoices)
              ChoiceChip(
                label: Text(_label(choice)),
                selected: current == choice,
                onSelected: _busy ? null : (picked) { if (picked) _pick(choice); },
              ),
          ],
        ),
        if (current <= 0) ...[
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, size: 18, color: scheme.error),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Không hạn: bộ nhớ đệm sẽ lớn lên mãi. Một cuốn sách dài có thể '
                  'ngốn vài GB, và ứng dụng sẽ không tự dọn — đến khi hết chỗ trên '
                  'máy thì việc đọc dừng giữa chừng.',
                  style: TextStyle(fontSize: 12.5, color: scheme.error, height: 1.45),
                ),
              ),
            ],
          ),
        ],
        if (_busy) ...[
          const SizedBox(height: 10),
          const LinearProgressIndicator(minHeight: 3),
        ],
      ],
    );
  }
}
