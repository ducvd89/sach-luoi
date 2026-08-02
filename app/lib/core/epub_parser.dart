/// Trích xuất nội dung sách từ file EPUB (cả EPUB 2 và EPUB 3).
///
/// Luồng: container.xml -> file OPF -> manifest + spine -> đọc từng XHTML theo
/// đúng thứ tự đọc, chuyển sang văn bản thuần. Tên chương lấy từ mục lục
/// (toc.ncx hoặc nav.xhtml), nếu không có thì lấy thẻ tiêu đề đầu tiên.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../models/book.dart';

String? _attr(String tag, String name) {
  final m = RegExp('$name\\s*=\\s*("([^"]*)"|\'([^\']*)\')', caseSensitive: false).firstMatch(tag);
  if (m == null) return null;
  return m[2] ?? m[3];
}

Iterable<String> _tags(String xml, String tagName) =>
    RegExp('<$tagName\\b[^>]*/?>', caseSensitive: false).allMatches(xml).map((m) => m[0]!);

const _namedEntities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ',
  'ndash': '–', 'mdash': '—', 'hellip': '…', 'ldquo': '“', 'rdquo': '”',
  'lsquo': '‘', 'rsquo': '’', 'laquo': '«', 'raquo': '»', 'copy': '©',
  'reg': '®', 'trade': '™', 'deg': '°', 'middot': '·', 'bull': '•', 'shy': '',
};

String _decodeEntities(String text) {
  return text.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (m) {
    final code = m[1]!;
    if (code.startsWith('#')) {
      final isHex = code.length > 1 && (code[1] == 'x' || code[1] == 'X');
      final value = int.tryParse(isHex ? code.substring(2) : code.substring(1), radix: isHex ? 16 : 10);
      if (value == null || value < 0 || value > 0x10FFFF) return m[0]!;
      return String.fromCharCode(value);
    }
    return _namedEntities[code] ?? m[0]!;
  });
}

const _blockTags = 'p|div|li|tr|h[1-6]|blockquote|section|article|figcaption|td|th|pre|hr';

/// Chuyển XHTML thành văn bản thuần, giữ ranh giới đoạn bằng dòng trống.
///
/// `<br>` xuống dòng MỀM — nhiều sách convert từ web dùng nó để ngắt dòng
/// giữa câu (thơ, xuống dòng theo khổ giấy gốc) chứ không phải hết đoạn. Cho
/// nó thành `\n\n` như các thẻ khối khác thì bộ cắt đoạn (`chunker.dart`, tách
/// đoạn văn tại `\n{2,}`) hiểu nhầm thành ranh giới đoạn thật, cắt chương ra
/// nhiều đoạn hơn cần thiết — mỗi đoạn là một lượt tổng hợp riêng nên sinh
/// thêm chỗ chuyển giọng không đáng có giữa câu. Nên chỉ xuống MỘT dòng, để
/// bước sau (`chunker.dart` nối dòng bằng khoảng trắng trong cùng đoạn) gộp
/// nó lại thành một câu liền mạch.
String htmlToText(String html) {
  var text = html
      .replaceAll(RegExp(r'<\?[\s\S]*?\?>'), '')
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAllMapped(RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>'), (m) => m[1]!)
      .replaceAll(RegExp(r'<(script|style|head)\b[\s\S]*?</\1>', caseSensitive: false), '')
      // Chú thích cuối trang trong EPUB thường là <a epub:type="noteref">1</a>.
      .replaceAll(RegExp(r'''<a\b[^>]*epub:type\s*=\s*["']noteref["'][\s\S]*?</a>''', caseSensitive: false), '')
      .replaceAll(RegExp(r'<sup\b[^>]*>[\s\S]{0,20}?</sup>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<\s*br\s*/?\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp('</?(?:$_blockTags)\\b[^>]*>', caseSensitive: false), '\n\n')
      .replaceAll(RegExp(r'<[^>]+>'), '');

  return _decodeEntities(text)
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[ \t ]+'), ' ')
      .replaceAll(RegExp(r' *\n *'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// Ghép đường dẫn tương đối bên trong file zip (luôn dùng dấu /).
String _resolveHref(String base, String href) {
  final clean = Uri.decodeFull(href.split('#').first);
  final joined = p.posix.normalize(p.posix.join(p.posix.dirname(base), clean));
  return joined.startsWith('./') ? joined.substring(2) : joined;
}

class _Item {
  _Item(this.href, this.mediaType, this.properties);
  final String href;
  final String mediaType;
  final String properties;
}

/// Đọc file EPUB thành danh sách chương.
///
/// [onChapter] được gọi sau mỗi file nội dung để báo tiến trình — sách lớn có
/// hàng trăm file và mất vài chục giây.
ParsedBook parseEpub(Uint8List bytes, {void Function(int done, int total)? onChapter}) {
  final archive = ZipDecoder().decodeBytes(bytes);

  // Một số công cụ trên Windows ghi dấu "\" thay vì "/" trong tên file.
  final files = <String, ArchiveFile>{};
  for (final file in archive.files) {
    if (file.isFile) files[file.name.replaceAll('\\', '/')] = file;
  }

  String readText(String name) => utf8.decode(files[name]!.content as List<int>, allowMalformed: true);

  String? opfPath;
  if (files.containsKey('META-INF/container.xml')) {
    final container = readText('META-INF/container.xml');
    final rootfile = RegExp(r'<rootfile\b[^>]*>', caseSensitive: false).firstMatch(container)?[0];
    if (rootfile != null) opfPath = _attr(rootfile, 'full-path');
  }
  opfPath ??= files.keys.where((n) => n.toLowerCase().endsWith('.opf')).firstOrNull;
  if (opfPath == null) {
    throw const FormatException('Không tìm thấy file OPF — đây có thể không phải EPUB hợp lệ');
  }

  final opf = readText(opfPath);

  String metaText(String tag) {
    final m = RegExp('<$tag\\b[^>]*>([\\s\\S]*?)</$tag>', caseSensitive: false).firstMatch(opf);
    return m == null ? '' : _decodeEntities(m[1]!.replaceAll(RegExp(r'<[^>]+>'), '')).trim();
  }

  final manifest = <String, _Item>{};
  final manifestBlock =
      RegExp(r'<manifest\b[^>]*>([\s\S]*?)</manifest>', caseSensitive: false).firstMatch(opf)?[1] ?? opf;
  for (final tag in _tags(manifestBlock, 'item')) {
    final id = _attr(tag, 'id');
    final href = _attr(tag, 'href');
    if (id == null || href == null) continue;
    manifest[id] = _Item(
      _resolveHref(opfPath, href),
      _attr(tag, 'media-type') ?? '',
      _attr(tag, 'properties') ?? '',
    );
  }

  final spineBlock = RegExp(r'<spine\b[^>]*>([\s\S]*?)</spine>', caseSensitive: false).firstMatch(opf)?[1] ?? '';
  final spineIds = _tags(spineBlock, 'itemref')
      .where((tag) => _attr(tag, 'linear') != 'no')
      .map((tag) => _attr(tag, 'idref'))
      .whereType<String>()
      .toList();

  // Mục lục: EPUB 3 dùng nav.xhtml, EPUB 2 dùng toc.ncx.
  final tocTitles = <String, String>{};

  final navItem = manifest.values.where((i) => i.properties.contains('nav')).firstOrNull;
  if (navItem != null && files.containsKey(navItem.href)) {
    try {
      final xml = readText(navItem.href);
      final navBlock =
          RegExp(r'''<nav\b[^>]*epub:type\s*=\s*["']toc["'][\s\S]*?</nav>''', caseSensitive: false).firstMatch(xml)?[0] ??
              xml;
      for (final m in RegExp(r'''<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>''', caseSensitive: false)
          .allMatches(navBlock)) {
        final target = _resolveHref(navItem.href, m[1]!);
        final label = htmlToText(m[2]!).replaceAll(RegExp(r'\s+'), ' ').trim();
        if (label.isNotEmpty) tocTitles.putIfAbsent(target, () => label);
      }
    } catch (_) {
      // mục lục hỏng thì bỏ qua
    }
  }

  final ncxItem = manifest.values.where((i) => i.mediaType == 'application/x-dtbncx+xml').firstOrNull ??
      manifest.values.where((i) => i.href.toLowerCase().endsWith('.ncx')).firstOrNull;
  if (ncxItem != null && files.containsKey(ncxItem.href)) {
    try {
      final xml = readText(ncxItem.href);
      for (final m in RegExp(r'<navPoint\b[\s\S]*?</navPoint>', caseSensitive: false).allMatches(xml)) {
        final block = m[0]!;
        final label =
            htmlToText(RegExp(r'<text\b[^>]*>([\s\S]*?)</text>', caseSensitive: false).firstMatch(block)?[1] ?? '')
                .trim();
        final contentTag = RegExp(r'<content\b[^>]*>', caseSensitive: false).firstMatch(block)?[0];
        final src = contentTag == null ? null : _attr(contentTag, 'src');
        if (label.isNotEmpty && src != null) {
          tocTitles.putIfAbsent(_resolveHref(ncxItem.href, src), () => label);
        }
      }
    } catch (_) {
      // bỏ qua
    }
  }

  final hrefs = spineIds.isNotEmpty
      ? spineIds.map((id) => manifest[id]?.href).whereType<String>().toList()
      : manifest.values.where((i) => RegExp('xhtml|html').hasMatch(i.mediaType)).map((i) => i.href).toList();

  final chapters = <RawChapter>[];
  for (var i = 0; i < hrefs.length; i++) {
    final href = hrefs[i];
    onChapter?.call(i + 1, hrefs.length);
    if (!files.containsKey(href)) continue;
    String html;
    try {
      html = readText(href);
    } catch (_) {
      continue;
    }

    final text = htmlToText(html);
    if (text.replaceAll(RegExp(r'\s'), '').length < 30) continue; // bỏ trang bìa, trang trắng

    var title = tocTitles[href] ?? '';
    if (title.isEmpty) {
      final heading = RegExp(r'<h[1-6]\b[^>]*>([\s\S]*?)</h[1-6]>', caseSensitive: false).firstMatch(html);
      if (heading != null) title = htmlToText(heading[1]!).replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    if (title.isEmpty) {
      final firstLine = text.split('\n').first;
      title = firstLine.length > 80 ? firstLine.substring(0, 80) : firstLine;
    }

    chapters.add(RawChapter(title.length > 200 ? title.substring(0, 200) : title, text));
  }

  if (chapters.isEmpty) {
    throw const FormatException('Không trích xuất được nội dung văn bản nào từ EPUB');
  }

  return ParsedBook(
    title: metaText('dc:title').isNotEmpty ? metaText('dc:title') : metaText('title'),
    author: metaText('dc:creator').isNotEmpty ? metaText('dc:creator') : metaText('creator'),
    language: metaText('dc:language').isNotEmpty ? metaText('dc:language') : 'vi',
    chapters: chapters,
  );
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
