import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:xml/xml.dart';
import 'models.dart';

class BookParser {
  /// 在后台 Isolate 中解析书籍，避免大文件阻塞 UI 线程
  static Future<List<Chapter>> parse(String filePath, String format) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('书籍文件不存在: $filePath');
    }

    return await Isolate.run(() {
      if (format.toLowerCase() == 'epub' || filePath.toLowerCase().endsWith('.epub')) {
        return _parseEpubSync(file);
      } else {
        return _parseTxtSync(file);
      }
    });
  }

  // ==================== TXT 解析 (支持 UTF-8 / GBK / GB18030) ====================

  static List<Chapter> _parseTxtSync(File file) {
    final bytes = file.readAsBytesSync();
    String content;

    // 优先尝试 UTF-8 解码，失败时回退至中文标准的 GBK / GB18030 解码
    try {
      content = utf8.decode(bytes);
    } catch (_) {
      try {
        content = gbk.decode(bytes);
      } catch (e) {
        content = String.fromCharCodes(bytes);
      }
    }

    // 优化后的章节匹配正则
    final chapterRegex = RegExp(
      r'^\s*(第[0-9一二三四五六七八九十百千万]+[章回节卷集部篇][^\n\r]{0,35}|Chapter\s+\d+[^\n\r]{0,35}|楔子|序章|引子|尾声|后记)\s*$',
      multiLine: true,
    );

    final matches = chapterRegex.allMatches(content).toList();
    final List<Chapter> chapters = [];

    if (matches.isEmpty) {
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

  // ==================== EPUB 解析 (支持命名空间通配与路径规范化) ====================

  static List<Chapter> _parseEpubSync(File file) {
    final bytes = file.readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);

    final containerFile = archive.findFile('META-INF/container.xml');
    if (containerFile == null) {
      throw Exception('无效的 EPUB 格式：缺少 container.xml');
    }

    final containerXml = XmlDocument.parse(utf8.decode(containerFile.content as List<int>));
    final rootfile = containerXml.findAllElements('rootfile', namespace: '*').firstOrNull ??
        containerXml.findAllElements('rootfile').firstOrNull;
    final opfPath = rootfile?.getAttribute('full-path');
    if (opfPath == null) {
      throw Exception('无法解析 OPF 文件路径');
    }

    final opfFile = archive.findFile(opfPath);
    if (opfFile == null) {
      throw Exception('未找到 OPF 描述文件: $opfPath');
    }

    final opfDir = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';
    final opfXml = XmlDocument.parse(utf8.decode(opfFile.content as List<int>, allowMalformed: true));

    // 解析 manifest (支持命名空间通配)
    final manifestMap = <String, String>{};
    final items = opfXml.findAllElements('item', namespace: '*');
    for (var item in items) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        // 剥除 href 中可能存在的 #fragment 锚点
        manifestMap[id] = href.split('#').first;
      }
    }

    // 解析 spine 顺序
    final spineItems = <String>[];
    final itemrefs = opfXml.findAllElements('itemref', namespace: '*');
    for (var itemref in itemrefs) {
      final idref = itemref.getAttribute('idref');
      if (idref != null && manifestMap.containsKey(idref)) {
        spineItems.add(manifestMap[idref]!);
      }
    }

    final List<Chapter> chapters = [];
    for (int i = 0; i < spineItems.length; i++) {
      final rawPath = opfDir + spineItems[i];
      final normalizedPath = _normalizePath(rawPath);
      final chapterFile = archive.findFile(normalizedPath);
      if (chapterFile == null) continue;

      final htmlContent = utf8.decode(chapterFile.content as List<int>, allowMalformed: true);
      final text = _cleanHtml(htmlContent);
      if (text.isEmpty) continue;

      // 提取标题，优先读取 title 标签，空则用 h1-h3，再空则用序号兜底
      String title = '';
      final titleMatch = RegExp(r'<title>(.*?)</title>', caseSensitive: false).firstMatch(htmlContent);
      if (titleMatch != null && titleMatch.group(1)!.trim().isNotEmpty) {
        title = titleMatch.group(1)!.trim();
      }
      if (title.isEmpty) {
        final hMatch = RegExp(r'<h[1-3][^>]*>(.*?)</h[1-3]>', caseSensitive: false).firstMatch(htmlContent);
        if (hMatch != null) {
          title = _cleanHtml(hMatch.group(1)!).trim();
        }
      }
      if (title.isEmpty) {
        title = '第 ${chapters.length + 1} 节';
      }

      chapters.add(Chapter(
        index: chapters.length,
        title: title,
        content: text,
        wordCount: text.length,
      ));
    }

    return chapters;
  }

  /// 规范化 POSIX 路径 (处理 ./ 和 ../)
  static String _normalizePath(String path) {
    final parts = path.split('/');
    final result = <String>[];
    for (var p in parts) {
      if (p == '' || p == '.') continue;
      if (p == '..') {
        if (result.isNotEmpty) result.removeLast();
      } else {
        result.add(p);
      }
    }
    return result.join('/');
  }

  /// 完整清洗 HTML 标签与常见 HTML 实体
  static String _cleanHtml(String html) {
    var text = html
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|h[1-6]|li)>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&quot;', '"')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'")
        .replaceAll('&mdash;', '—')
        .replaceAll('&ldquo;', '“')
        .replaceAll('&rdquo;', '”')
        .replaceAll('&lsquo;', '‘')
        .replaceAll('&rsquo;', '’')
        .replaceAll('&hellip;', '…');

    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }
}
