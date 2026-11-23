import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:xml/xml.dart';
import 'models.dart';

class BookParser {
  /// 解析本地书籍（自动判断 TXT 或 EPUB）
  static Future<List<Chapter>> parse(String filePath, String format) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('书籍文件不存在: $filePath');
    }

    if (format.toLowerCase() == 'epub' || filePath.toLowerCase().endsWith('.epub')) {
      return _parseEpub(file);
    } else {
      return _parseTxt(file);
    }
  }

  // ==================== TXT 解析 ====================

  static Future<List<Chapter>> _parseTxt(File file) async {
    final bytes = await file.readAsBytes();
    String content;

    // 智能编码探测：优先 UTF-8，失败尝试 Latin1/GBK 容错
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      try {
        content = latin1.decode(bytes); // 兜底解码
      } catch (e) {
        content = String.fromCharCodes(bytes);
      }
    }

    // 常用中文章节正则模式
    final chapterRegex = RegExp(
      r'^\s*(第[0-9一二三四五六七八九十百千万]+[章回节卷集部篇][^\n\r]{0,35}|Chapter\s+\d+[^\n\r]{0,35}|楔子|序章|引子|尾声|后记)\s*$',
      multiLine: true,
    );

    final matches = chapterRegex.allMatches(content).toList();
    final List<Chapter> chapters = [];

    if (matches.isEmpty) {
      // 未匹配到章节时，按固定字数切块（每章约 5000 字）
      const chunkSize = 5000;
      int chunkIdx = 0;
      for (int i = 0; i < content.length; i += chunkSize) {
        final end = (i + chunkSize < content.length) ? i + chunkSize : content.length;
        final part = content.substring(i, end).trim();
        if (part.isNotEmpty) {
          chapters.add(Chapter(
            index: chunkIdx,
            title: '第 ${chunkIdx + 1} 部分',
            content: part,
            wordCount: part.length,
          ));
          chunkIdx++;
        }
      }
      return chapters;
    }

    // 提取正文前言（第一章之前的内容）
    if (matches.first.start > 0) {
      final intro = content.substring(0, matches.first.start).trim();
      if (intro.isNotEmpty) {
        chapters.add(Chapter(
          index: 0,
          title: '序章 / 前言',
          content: intro,
          wordCount: intro.length,
        ));
      }
    }

    // 按正则切分各章节
    for (int i = 0; i < matches.length; i++) {
      final match = matches[i];
      final title = match.group(1)?.trim() ?? '第 ${chapters.length + 1} 章';
      final start = match.end;
      final end = (i + 1 < matches.length) ? matches[i + 1].start : content.length;
      final body = content.substring(start, end).trim();

      chapters.add(Chapter(
        index: chapters.length,
        title: title,
        content: body,
        wordCount: body.length,
      ));
    }

    return chapters;
  }

  // ==================== EPUB 解析 ====================

  static Future<List<Chapter>> _parseEpub(File file) async {
    final bytes = await file.readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);

    // 1. 读取 META-INF/container.xml 寻找 OPF 路径
    final containerFile = archive.findFile('META-INF/container.xml');
    if (containerFile == null) {
      throw Exception('无效的 EPUB 格式：缺少 container.xml');
    }

    final containerXml = XmlDocument.parse(utf8.decode(containerFile.content as List<int>));
    final rootfile = containerXml.findAllElements('rootfile').firstOrNull;
    final opfPath = rootfile?.getAttribute('full-path');
    if (opfPath == null) {
      throw Exception('无法解析 OPF 文件路径');
    }

    // 2. 读取 OPF 文件
    final opfFile = archive.findFile(opfPath);
    if (opfFile == null) {
      throw Exception('未找到 OPF 描述文件: $opfPath');
    }

    final opfDir = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';
    final opfXml = XmlDocument.parse(utf8.decode(opfFile.content as List<int>));

    // 3. 解析 manifest (id -> href)
    final manifestMap = <String, String>{};
    for (var item in opfXml.findAllElements('item')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        manifestMap[id] = href;
      }
    }

    // 4. 解析 spine 顺序
    final spineItems = <String>[];
    for (var itemref in opfXml.findAllElements('itemref')) {
      final idref = itemref.getAttribute('idref');
      if (idref != null && manifestMap.containsKey(idref)) {
        spineItems.add(manifestMap[idref]!);
      }
    }

    // 5. 提取章节 HTML 并清洗纯文本
    final List<Chapter> chapters = [];
    for (int i = 0; i < spineItems.length; i++) {
      final relativePath = Uri.decodeFull(opfDir + spineItems[i]);
      final chapterFile = archive.findFile(relativePath);
      if (chapterFile == null) continue;

      final htmlContent = utf8.decode(chapterFile.content as List<int>, allowMalformed: true);
      final text = _cleanHtml(htmlContent);
      if (text.isEmpty) continue;

      final titleMatch = RegExp(r'<title>(.*?)</title>', caseSensitive: false).firstMatch(htmlContent);
      final title = titleMatch?.group(1)?.trim() ?? '第 ${chapters.length + 1} 节';

      chapters.add(Chapter(
        index: chapters.length,
        title: title,
        content: text,
        wordCount: text.length,
      ));
    }

    return chapters;
  }

  /// 剥离 HTML 标签与实体字符
  static String _cleanHtml(String html) {
    var text = html
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'");

    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }
}
