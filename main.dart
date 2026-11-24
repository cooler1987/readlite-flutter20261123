import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'package:archive/archive.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

const String kDefaultFishVoiceId = 'cf71d823861b4e0eadff1672d646da36';

void _writeStartupErrorLog(Object error, StackTrace? stack) {
  try {
    if (Platform.isWindows) {
      final exeDir = File(Platform.resolvedExecutable).parent;
      final logDir = Directory('${exeDir.path}${Platform.pathSeparator}userdata');
      if (!logDir.existsSync()) {
        logDir.createSync(recursive: true);
      }
      final logFile = File('${logDir.path}${Platform.pathSeparator}startup_error.log');
      logFile.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $error\n${stack ?? ''}\n\n',
        mode: FileMode.append,
      );
    }
  } catch (_) {}
}

void main() {
  runZonedGuarded(() {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      _writeStartupErrorLog(details.exception, details.stack);
    };
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      _writeStartupErrorLog(error, stack);
      return true;
    };
    runApp(const WereadLiteApp());
  }, (error, stack) {
    _writeStartupErrorLog(error, stack);
  });
}

class WereadLiteApp extends StatelessWidget {
  const WereadLiteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Weread Lite (Local)',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        scaffoldBackgroundColor: const Color(0xFFFAF9F6), // 米白色纸质护眼底色
      ),
      home: const ShelfScreen(),
    );
  }
}

// ==================== 数据模型 ====================

enum TtsEngineType { system, fishAudio, customHttp }

class TtsEngineConfig {
  final String id;
  final String name;
  final TtsEngineType type;
  final String apiEndpoint;
  final String apiKey;
  final String voiceId;
  final String model;
  final String method; // 'GET' | 'POST'
  final double speed;
  final double pitch;
  final Map<String, String> customHeaders;
  final String customBodyTemplate;

  TtsEngineConfig({
    required this.id,
    required this.name,
    this.type = TtsEngineType.system,
    this.apiEndpoint = 'https://api.fish.audio/v1/tts',
    this.apiKey = '',
    this.voiceId = '',
    this.model = '',
    this.method = 'POST',
    this.speed = 1.0,
    this.pitch = 1.0,
    this.customHeaders = const {},
    this.customBodyTemplate = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'apiEndpoint': apiEndpoint,
        'apiKey': apiKey,
        'voiceId': voiceId,
        'model': model,
        'method': method,
        'speed': speed,
        'pitch': pitch,
        'customHeaders': customHeaders,
        'customBodyTemplate': customBodyTemplate,
      };

  factory TtsEngineConfig.fromJson(Map<String, dynamic> json) {
    final type = TtsEngineType.values.firstWhere(
      (e) => e.name == json['type'],
      orElse: () => TtsEngineType.system,
    );
    final bodyTpl = json['customBodyTemplate'] ?? '';
    final rawMethod = (json['method'] as String?)?.toUpperCase().trim();
    final resolvedMethod = (rawMethod == 'GET' || rawMethod == 'POST')
        ? rawMethod!
        : (type == TtsEngineType.customHttp && bodyTpl.trim().isEmpty ? 'GET' : 'POST');

    return TtsEngineConfig(
      id: json['id'] ?? '',
      name: json['name'] ?? '默认引擎',
      type: type,
      apiEndpoint: json['apiEndpoint'] ?? 'https://api.fish.audio/v1/tts',
      apiKey: json['apiKey'] ?? '',
      voiceId: json['voiceId'] ?? '',
      model: json['model'] ?? (type == TtsEngineType.fishAudio ? 's2.1-pro' : ''),
      method: resolvedMethod,
      speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
      pitch: (json['pitch'] as num?)?.toDouble() ?? 1.0,
      customHeaders: Map<String, String>.from(json['customHeaders'] ?? {}),
      customBodyTemplate: bodyTpl,
    );
  }

  TtsEngineConfig copyWith({
    String? name,
    TtsEngineType? type,
    String? apiEndpoint,
    String? apiKey,
    String? voiceId,
    String? model,
    String? method,
    double? speed,
    double? pitch,
    Map<String, String>? customHeaders,
    String? customBodyTemplate,
  }) {
    return TtsEngineConfig(
      id: id,
      name: name ?? this.name,
      type: type ?? this.type,
      apiEndpoint: apiEndpoint ?? this.apiEndpoint,
      apiKey: apiKey ?? this.apiKey,
      voiceId: voiceId ?? this.voiceId,
      model: model ?? this.model,
      method: method ?? this.method,
      speed: speed ?? this.speed,
      pitch: pitch ?? this.pitch,
      customHeaders: customHeaders ?? this.customHeaders,
      customBodyTemplate: customBodyTemplate ?? this.customBodyTemplate,
    );
  }
}

class Chapter {
  final int index;
  final String title;
  final String content;
  final int wordCount;

  Chapter({
    required this.index,
    required this.title,
    required this.content,
    required this.wordCount,
  });

  Map<String, dynamic> toJson() => {
        'index': index,
        'title': title,
        'content': content,
        'wordCount': wordCount,
      };

  factory Chapter.fromJson(Map<String, dynamic> json) => Chapter(
        index: json['index'] ?? 0,
        title: json['title'] ?? '',
        content: json['content'] ?? '',
        wordCount: json['wordCount'] ?? 0,
      );
}

class Book {
  final String id;
  final String title;
  final String author;
  final String filePath;
  final String format; // 'txt' | 'epub'
  int currentChapterIndex;
  int currentOffset;
  double progress;
  DateTime lastReadTime;

  Book({
    required this.id,
    required this.title,
    required this.author,
    required this.filePath,
    required this.format,
    this.currentChapterIndex = 0,
    this.currentOffset = 0,
    this.progress = 0.0,
    DateTime? lastReadTime,
  }) : lastReadTime = lastReadTime ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'filePath': filePath,
        'format': format,
        'currentChapterIndex': currentChapterIndex,
        'currentOffset': currentOffset,
        'progress': progress,
        'lastReadTime': lastReadTime.toIso8601String(),
      };

  factory Book.fromJson(Map<String, dynamic> json) => Book(
        id: json['id'] ?? '',
        title: json['title'] ?? '未命名书籍',
        author: json['author'] ?? '未知作者',
        filePath: json['filePath'] ?? '',
        format: json['format'] ?? 'txt',
        currentChapterIndex: json['currentChapterIndex'] ?? 0,
        currentOffset: json['currentOffset'] ?? 0,
        progress: (json['progress'] as num?)?.toDouble() ?? 0.0,
        lastReadTime: json['lastReadTime'] != null
            ? DateTime.tryParse(json['lastReadTime']) ?? DateTime.now()
            : DateTime.now(),
      );
}

class Bookmark {
  final String id;
  final String bookId;
  final int chapterIndex;
  final int offset;
  final String text;
  final DateTime createTime;

  Bookmark({
    required this.id,
    required this.bookId,
    required this.chapterIndex,
    required this.offset,
    required this.text,
    DateTime? createTime,
  }) : createTime = createTime ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'id': id,
        'bookId': bookId,
        'chapterIndex': chapterIndex,
        'offset': offset,
        'text': text,
        'createTime': createTime.toIso8601String(),
      };

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        id: json['id'] ?? '',
        bookId: json['bookId'] ?? '',
        chapterIndex: json['chapterIndex'] ?? 0,
        offset: json['offset'] ?? 0,
        text: json['text'] ?? '',
        createTime: json['createTime'] != null
            ? DateTime.tryParse(json['createTime']) ?? DateTime.now()
            : DateTime.now(),
      );
}

class TtsSentence {
  final String text;
  final int chapterIndex;
  final int startOffset;
  final int endOffset;

  TtsSentence({
    required this.text,
    required this.chapterIndex,
    required this.startOffset,
    required this.endOffset,
  });
}

// ==================== 本地持久化存储 (支持 Windows Portable 便携模式) ====================

class Storage {
  static const String _keyBooks = 'weread_lite_books';
  static const String _keyBookmarks = 'weread_lite_bookmarks';
  static const String _keyTtsEngines = 'weread_lite_tts_engines';
  static const String _keyCurrentTtsId = 'weread_lite_current_tts_id';
  static const String _keyNodeLunesInjected = 'weread_lite_node_lunes_injected';
  static const String _keyFontSize = 'weread_lite_font_size';
  static const String _keyLineHeight = 'weread_lite_line_height';
  static const String _keyMargin = 'weread_lite_margin';
  static const String _keyEinkMode = 'weread_lite_eink_mode';

  static SharedPreferences? _prefs;
  static bool _isPortable = false;
  static Directory? _portableDataDir;
  static Map<String, dynamic> _portableData = {};
  static Future<void> _writeQueue = Future.value();

  static bool get isPortableMode => _isPortable;

  static Future<void> init() async {
    if (_prefs != null || _portableDataDir != null) return;

    if (Platform.isWindows) {
      try {
        final exeDir = File(Platform.resolvedExecutable).parent;
        // 使用独立的 userdata 目录，避免与 Flutter 引擎自带的 data/ 资源目录冲突
        final userDataDir = Directory('${exeDir.path}${Platform.pathSeparator}userdata');
        if (!await userDataDir.exists()) {
          await userDataDir.create(recursive: true);
        }
        final probeFile = File('${userDataDir.path}${Platform.pathSeparator}.write_test');
        await probeFile.writeAsString('ok');
        await probeFile.delete();

        _portableDataDir = userDataDir;
        _isPortable = true;

        final settingsFile = File('${userDataDir.path}${Platform.pathSeparator}settings.json');
        if (await settingsFile.exists()) {
          final raw = await settingsFile.readAsString();
          if (raw.trim().isNotEmpty) {
            final decoded = jsonDecode(raw);
            if (decoded is Map<String, dynamic>) {
              _portableData = decoded;
            }
          }
        } else {
          // 兼容迁移旧版 data/settings.json
          final legacyFile = File(
            '${exeDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}settings.json',
          );
          if (await legacyFile.exists()) {
            final raw = await legacyFile.readAsString();
            if (raw.trim().isNotEmpty) {
              final decoded = jsonDecode(raw);
              if (decoded is Map<String, dynamic>) {
                _portableData = decoded;
                await _flushPortable();
              }
            }
          }
        }
        return;
      } catch (_) {
        _isPortable = false;
        _portableDataDir = null;
      }
    }

    try {
      _prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
      );
    } catch (_) {}
  }

  static Future<Directory> getBooksDir() async {
    if (_isPortable && _portableDataDir != null) {
      final booksDir = Directory('${_portableDataDir!.path}${Platform.pathSeparator}books');
      if (!await booksDir.exists()) {
        await booksDir.create(recursive: true);
      }
      return booksDir;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final booksDir = Directory('${appDir.path}${Platform.pathSeparator}books');
    if (!await booksDir.exists()) {
      await booksDir.create(recursive: true);
    }
    return booksDir;
  }

  static Future<void> _flushPortable() {
    final dir = _portableDataDir;
    if (!_isPortable || dir == null) return Future.value();
    final snapshot = jsonEncode(_portableData);
    _writeQueue = _writeQueue.then((_) async {
      final file = File('${dir.path}${Platform.pathSeparator}settings.json');
      await file.writeAsString(snapshot);
    }).catchError((_) {});
    return _writeQueue;
  }

  static String? _getString(String key) {
    if (_isPortable) {
      final val = _portableData[key];
      return val is String ? val : null;
    }
    return _prefs?.getString(key);
  }

  static Future<void> _setString(String key, String value) async {
    if (_isPortable) {
      _portableData[key] = value;
      await _flushPortable();
      return;
    }
    await _prefs?.setString(key, value);
  }

  static Future<void> _removeKey(String key) async {
    if (_isPortable) {
      _portableData.remove(key);
      await _flushPortable();
      return;
    }
    await _prefs?.remove(key);
  }

  static double? _getDouble(String key) {
    if (_isPortable) {
      final val = _portableData[key];
      return val is num ? val.toDouble() : null;
    }
    return _prefs?.getDouble(key);
  }

  static Future<void> _setDouble(String key, double value) async {
    if (_isPortable) {
      _portableData[key] = value;
      await _flushPortable();
      return;
    }
    await _prefs?.setDouble(key, value);
  }

  static bool? _getBool(String key) {
    if (_isPortable) {
      final val = _portableData[key];
      return val is bool ? val : null;
    }
    return _prefs?.getBool(key);
  }

  static Future<void> _setBool(String key, bool value) async {
    if (_isPortable) {
      _portableData[key] = value;
      await _flushPortable();
      return;
    }
    await _prefs?.setBool(key, value);
  }

  // ---------- 书籍管理 ----------

  static List<Book> getBooks() {
    final raw = _getString(_keyBooks);
    if (raw == null || raw.isEmpty) return [];
    try {
      final List list = jsonDecode(raw);
      return list.map((e) => Book.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveBooks(List<Book> books) async {
    final raw = jsonEncode(books.map((e) => e.toJson()).toList());
    await _setString(_keyBooks, raw);
  }

  static Future<void> saveBook(Book book) async {
    final books = getBooks();
    final idx = books.indexWhere((b) => b.id == book.id);
    if (idx >= 0) {
      books[idx] = book;
    } else {
      books.insert(0, book);
    }
    await saveBooks(books);
  }

  static Future<void> removeBook(String id) async {
    final books = getBooks()..removeWhere((b) => b.id == id);
    await saveBooks(books);
    await _removeKey('${_keyBookmarks}_$id');
  }

  // ---------- 书签管理 ----------

  static List<Bookmark> getBookmarks(String bookId) {
    final raw = _getString('${_keyBookmarks}_$bookId');
    if (raw == null || raw.isEmpty) return [];
    try {
      final List list = jsonDecode(raw);
      return list.map((e) => Bookmark.fromJson(Map<String, dynamic>.from(e))).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> addBookmark(Bookmark bookmark) async {
    final list = getBookmarks(bookmark.bookId)..add(bookmark);
    await _setString(
      '${_keyBookmarks}_${bookmark.bookId}',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> removeBookmark(String bookId, String bookmarkId) async {
    final list = getBookmarks(bookId)..removeWhere((b) => b.id == bookmarkId);
    await _setString(
      '${_keyBookmarks}_$bookId',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  // ---------- TTS 引擎配置 ----------

  static TtsEngineConfig _defaultNodeLunesEngine() => TtsEngineConfig(
        id: 'builtin_node_lunes',
        name: '自建云端容器 (node55)',
        type: TtsEngineType.customHttp,
        method: 'GET',
        apiEndpoint:
            'http://node55.lunes.host:3001/?text={{text}}&speed={{speed}}&voice={{voice}}&model=s2.1-pro-free',
        apiKey: '',
        voiceId: kDefaultFishVoiceId,
        customBodyTemplate: '',
      );

  static List<TtsEngineConfig> _defaultTtsEngines() => [
        TtsEngineConfig(
          id: 'system',
          name: '系统原生 TTS',
          type: TtsEngineType.system,
        ),
        TtsEngineConfig(
          id: 'fish_audio',
          name: 'Fish.Audio 引擎',
          type: TtsEngineType.fishAudio,
          apiEndpoint: 'https://api.fish.audio/v1/tts',
          apiKey: '',
          voiceId: kDefaultFishVoiceId,
          model: 's2.1-pro',
          method: 'POST',
        ),
        _defaultNodeLunesEngine(),
      ];

  static List<TtsEngineConfig> getTtsEngines() {
    final raw = _getString(_keyTtsEngines);
    if (raw == null || raw.isEmpty) {
      return _defaultTtsEngines();
    }
    try {
      final List list = jsonDecode(raw);
      final res = list
          .map((e) => TtsEngineConfig.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (res.isEmpty) return _defaultTtsEngines();

      bool dirty = false;
      // 迁移：为旧版未填默认发音人的 Fish.Audio 补充默认 voiceId
      for (int i = 0; i < res.length; i++) {
        if (res[i].id == 'fish_audio' && res[i].voiceId.trim().isEmpty) {
          res[i] = res[i].copyWith(voiceId: kDefaultFishVoiceId);
          dirty = true;
        }
      }
      // 迁移：首次升级自动注入可编辑的 node55 中转引擎
      final hasNodeLunes = res.any((e) => e.id == 'builtin_node_lunes');
      if (!hasNodeLunes && _getBool(_keyNodeLunesInjected) != true) {
        res.add(_defaultNodeLunesEngine());
        _setBool(_keyNodeLunesInjected, true);
        dirty = true;
      }
      if (dirty) {
        saveTtsEngines(res);
      }
      return res;
    } catch (_) {
      return _defaultTtsEngines();
    }
  }

  static Future<void> saveTtsEngines(List<TtsEngineConfig> engines) async {
    final raw = jsonEncode(engines.map((e) => e.toJson()).toList());
    await _setString(_keyTtsEngines, raw);
    await _setBool(_keyNodeLunesInjected, true);
  }

  static TtsEngineConfig getActiveTtsEngine() {
    final engines = getTtsEngines();
    final currentId = _getString(_keyCurrentTtsId);
    if (currentId != null) {
      final found = engines.where((e) => e.id == currentId);
      if (found.isNotEmpty) return found.first;
    }
    return engines.isNotEmpty ? engines.first : _defaultTtsEngines().first;
  }

  static Future<void> setActiveTtsEngine(String engineId) async {
    await _setString(_keyCurrentTtsId, engineId);
  }

  // ---------- 阅读排版配置 ----------

  static double getFontSize() => _getDouble(_keyFontSize) ?? 20.0;
  static Future<void> setFontSize(double size) => _setDouble(_keyFontSize, size);

  static double getLineHeight() => _getDouble(_keyLineHeight) ?? 1.6;
  static Future<void> setLineHeight(double height) => _setDouble(_keyLineHeight, height);

  static double getMargin() => _getDouble(_keyMargin) ?? 16.0;
  static Future<void> setMargin(double margin) => _setDouble(_keyMargin, margin);

  static bool getEinkMode() => _getBool(_keyEinkMode) ?? false;
  static Future<void> setEinkMode(bool val) => _setBool(_keyEinkMode, val);
}

// ==================== 书籍解析器 (Isolate 后台线程) ====================

class BookParser {
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

  static String _decodeBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';

    // UTF-8 BOM
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    // UTF-16 LE BOM
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      final codeUnits = <int>[];
      for (int i = 2; i + 1 < bytes.length; i += 2) {
        codeUnits.add(bytes[i] | (bytes[i + 1] << 8));
      }
      return String.fromCharCodes(codeUnits);
    }
    // UTF-16 BE BOM
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      final codeUnits = <int>[];
      for (int i = 2; i + 1 < bytes.length; i += 2) {
        codeUnits.add((bytes[i] << 8) | bytes[i + 1]);
      }
      return String.fromCharCodes(codeUnits);
    }

    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        try {
          return const GbkCodec(allowMalformed: true).decode(bytes);
        } catch (_) {
          return utf8.decode(bytes, allowMalformed: true);
        }
      }
    }
  }

  static List<Chapter> _parseTxtSync(File file) {
    final bytes = file.readAsBytesSync();
    final content = _decodeBytes(bytes)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    final chapterRegex = RegExp(
      r'^[ \t]*(第[0-9零〇一二两三四五六七八九十百千万]+[章回节卷集部篇][^\n]{0,35}|Chapter\s+\d+[^\n]{0,35}|楔子|序章|引子|尾声|后记)[ \t]*$',
      multiLine: true,
      caseSensitive: false,
    );

    final matches = chapterRegex.allMatches(content).toList();
    final List<Chapter> chapters = [];

    if (matches.isEmpty) {
      const targetChunk = 5000;
      int i = 0;
      while (i < content.length) {
        int end = (i + targetChunk < content.length) ? i + targetChunk : content.length;
        if (end < content.length) {
          final nlPos = content.indexOf('\n', end);
          if (nlPos != -1 && nlPos - end < 400) {
            end = nlPos + 1;
          } else if (_isLowSurrogate(content.codeUnitAt(end))) {
            end++;
          }
        }
        final part = content.substring(i, end).trim();
        if (part.isNotEmpty) {
          chapters.add(Chapter(
            index: chapters.length,
            title: '第 ${chapters.length + 1} 部分',
            content: part,
            wordCount: part.length,
          ));
        }
        i = end;
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

      if (body.isEmpty) continue;

      chapters.add(Chapter(
        index: chapters.length,
        title: title,
        content: body,
        wordCount: body.length,
      ));
    }

    if (chapters.isEmpty && content.trim().isNotEmpty) {
      final fallback = content.trim();
      chapters.add(Chapter(
        index: 0,
        title: '正文',
        content: fallback,
        wordCount: fallback.length,
      ));
    }

    return chapters;
  }

  static bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  static ArchiveFile? _findArchiveFile(Archive archive, String path) {
    final normalized = _normalizePath(path.replaceAll('\\', '/'));
    final direct = archive.findFile(normalized);
    if (direct != null) return direct;

    final lowerTarget = normalized.toLowerCase();
    for (final file in archive.files) {
      if (!file.isFile) continue;
      final fNorm = _normalizePath(file.name.replaceAll('\\', '/'));
      if (fNorm == normalized || fNorm.toLowerCase() == lowerTarget) {
        return file;
      }
    }
    return null;
  }

  static String _safeDecodeUri(String raw) {
    try {
      return Uri.decodeFull(raw);
    } catch (_) {
      return raw;
    }
  }

  static List<Chapter> _parseEpubSync(File file) {
    final bytes = file.readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);

    final containerFile = _findArchiveFile(archive, 'META-INF/container.xml');
    if (containerFile == null) {
      throw Exception('无效的 EPUB 格式：缺少 container.xml');
    }

    final containerXml = XmlDocument.parse(
      utf8.decode(containerFile.content as List<int>, allowMalformed: true),
    );
    final rootfile = containerXml.findAllElements('rootfile', namespace: '*').firstOrNull ??
        containerXml.findAllElements('rootfile').firstOrNull;
    final rawOpfPath = rootfile?.getAttribute('full-path');
    if (rawOpfPath == null || rawOpfPath.isEmpty) {
      throw Exception('无法解析 OPF 文件路径');
    }

    final opfPath = _normalizePath(_safeDecodeUri(rawOpfPath));
    final opfFile = _findArchiveFile(archive, opfPath);
    if (opfFile == null) {
      throw Exception('未找到 OPF 描述文件: $opfPath');
    }

    final opfDir = opfPath.contains('/')
        ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1)
        : '';
    final opfXml = XmlDocument.parse(
      utf8.decode(opfFile.content as List<int>, allowMalformed: true),
    );

    final manifestMap = <String, String>{};
    for (final item in opfXml.findAllElements('item', namespace: '*')) {
      final id = item.getAttribute('id');
      final href = item.getAttribute('href');
      if (id != null && href != null) {
        manifestMap[id] = _safeDecodeUri(href.split('#').first);
      }
    }

    final spineItems = <String>[];
    for (final itemref in opfXml.findAllElements('itemref', namespace: '*')) {
      final idref = itemref.getAttribute('idref');
      if (idref != null && manifestMap.containsKey(idref)) {
        spineItems.add(manifestMap[idref]!);
      }
    }

    final List<Chapter> chapters = [];
    for (final relHref in spineItems) {
      final rawPath = opfDir + relHref;
      final chapterFile = _findArchiveFile(archive, rawPath);
      if (chapterFile == null) continue;

      final htmlContent = _decodeBytes(chapterFile.content as List<int>);
      final text = _cleanHtml(htmlContent);
      if (text.isEmpty) continue;

      String title = '';
      final hMatch = RegExp(
        r'<h[1-3][^>]*>([\s\S]*?)</h[1-3]>',
        caseSensitive: false,
      ).firstMatch(htmlContent);
      if (hMatch != null) {
        title = _cleanHtml(hMatch.group(1)!).replaceAll('\n', ' ').trim();
      }
      if (title.isEmpty) {
        final titleMatch = RegExp(
          r'<title[^>]*>([\s\S]*?)</title>',
          caseSensitive: false,
        ).firstMatch(htmlContent);
        if (titleMatch != null) {
          title = _cleanHtml(titleMatch.group(1)!).replaceAll('\n', ' ').trim();
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

  static String _normalizePath(String path) {
    final parts = path.split('/');
    final result = <String>[];
    for (final p in parts) {
      if (p.isEmpty || p == '.') continue;
      if (p == '..') {
        if (result.isNotEmpty) result.removeLast();
      } else {
        result.add(p);
      }
    }
    return result.join('/');
  }

  static String _cleanHtml(String html) {
    var text = html
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<script[^>]*>[\s\S]*?</script>', caseSensitive: false), '')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</(p|div|h[1-6]|li|tr|blockquote)>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]*>'), '');

    text = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&ensp;', ' ')
        .replaceAll('&emsp;', '　')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#39;', "'")
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&ldquo;', '“')
        .replaceAll('&rdquo;', '”')
        .replaceAll('&lsquo;', '‘')
        .replaceAll('&rsquo;', '’')
        .replaceAll('&hellip;', '…');

    text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      return (code != null && code > 0 && code <= 0x10FFFF)
          ? String.fromCharCode(code)
          : m.group(0)!;
    });
    text = text.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '', radix: 16);
      return (code != null && code > 0 && code <= 0x10FFFF)
          ? String.fromCharCode(code)
          : m.group(0)!;
    });

    text = text
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'^[ \t]+|[ \t]+$'), ''))
        .join('\n');

    return text.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }
}

// ==================== 分页与断句引擎 ====================

class PageEngine {
  static List<int> paginate({
    required String text,
    required TextStyle style,
    required Size contentAreaSize,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    if (text.isEmpty || contentAreaSize.width <= 0 || contentAreaSize.height <= 0) {
      return [0];
    }

    final fontSize = (style.fontSize ?? 18.0).clamp(10.0, 60.0);
    final lineHeight = (style.height ?? 1.5).clamp(1.0, 3.0);
    final scaledFontSize = textScaler.scale(fontSize);
    final estCharsPerLine = (contentAreaSize.width / scaledFontSize).ceil() + 4;
    final estLines = (contentAreaSize.height / (scaledFontSize * lineHeight)).ceil() + 2;
    final windowSize = math.max(400, math.min(2600, estCharsPerLine * estLines * 2));

    final List<int> pageStarts = [0];
    int currentOffset = 0;

    while (currentOffset < text.length) {
      int searchLimit = (currentOffset + windowSize).clamp(0, text.length);
      if (searchLimit < text.length && _isLowSurrogate(text.codeUnitAt(searchLimit))) {
        searchLimit++;
      }

      final chunk = text.substring(currentOffset, searchLimit);
      final tp = TextPainter(
        text: TextSpan(text: chunk, style: style),
        textDirection: TextDirection.ltr,
        textScaler: textScaler,
      )..layout(maxWidth: contentAreaSize.width);

      final lines = tp.computeLineMetrics();
      double usedHeight = 0;
      int lastVisibleLineEnd = 0;

      for (final line in lines) {
        if (usedHeight + line.height > contentAreaSize.height && lastVisibleLineEnd > 0) {
          break;
        }
        usedHeight += line.height;
        final pos = tp.getPositionForOffset(Offset(contentAreaSize.width, line.baseline));
        if (pos.offset > lastVisibleLineEnd) {
          lastVisibleLineEnd = pos.offset;
        }
        if (lastVisibleLineEnd < chunk.length && chunk.codeUnitAt(lastVisibleLineEnd) == 0x0A) {
          lastVisibleLineEnd++;
        }
      }

      final int pageChars = lastVisibleLineEnd > 0 ? lastVisibleLineEnd : 1;
      int nextOffset = currentOffset + pageChars;
      if (nextOffset < text.length && _isLowSurrogate(text.codeUnitAt(nextOffset))) {
        nextOffset++;
      }

      if (nextOffset < text.length) {
        pageStarts.add(nextOffset);
        currentOffset = nextOffset;
      } else {
        break;
      }
    }

    return pageStarts;
  }

  static bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xDC00 && codeUnit <= 0xDFFF;

  static int findPageIndexForOffset(List<int> pageStarts, int charOffset) {
    if (pageStarts.isEmpty) return 0;
    for (int i = pageStarts.length - 1; i >= 0; i--) {
      if (charOffset >= pageStarts[i]) {
        return i;
      }
    }
    return 0;
  }

  static List<TtsSentence> splitSentences(String text, int chapterIndex) {
    final sentencePattern = RegExp(
      r'(?:[^。！？!?;；\n\r.]|(?<=\d)\.(?=\d))+[。！？!?;；\n\r.]*[”’"\x27）)』」]*',
    );
    final List<TtsSentence> result = [];
    const maxLen = 360;

    for (final m in sentencePattern.allMatches(text)) {
      final raw = m.group(0)!;
      if (raw.trim().isEmpty) continue;

      if (raw.length <= maxLen) {
        result.add(TtsSentence(
          text: raw.trim(),
          chapterIndex: chapterIndex,
          startOffset: m.start,
          endOffset: m.end,
        ));
      } else {
        int i = 0;
        while (i < raw.length) {
          int end = math.min(i + maxLen, raw.length);
          if (end < raw.length && _isLowSurrogate(raw.codeUnitAt(end))) {
            end++;
          }
          final sub = raw.substring(i, end).trim();
          if (sub.isNotEmpty) {
            result.add(TtsSentence(
              text: sub,
              chapterIndex: chapterIndex,
              startOffset: m.start + i,
              endOffset: m.start + end,
            ));
          }
          i = end;
        }
      }
    }
    return result;
  }
}

// ==================== TTS 朗读服务 (完全懒加载) ====================

class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  FlutterTts? _flutterTts;
  AudioPlayer? _audioPlayer;

  TtsEngineConfig _config = TtsEngineConfig(id: 'system', name: '系统原生 TTS');
  List<TtsSentence> _queue = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  bool _isPaused = false;
  bool _isTesting = false;
  bool _systemTtsReady = false;
  bool _audioPlayerReady = false;
  int _requestToken = 0;
  int _consecutiveErrors = 0;
  String _lastLang = '';
  String? _lastPlayerLogError;

  VoidCallback? onChapterComplete;

  bool get isPlaying => _isPlaying;
  bool get isPaused => _isPaused;
  TtsSentence? get currentSentence =>
      (_queue.isNotEmpty && _currentIndex < _queue.length) ? _queue[_currentIndex] : null;

  final StreamController<TtsSentence> _sentenceController =
      StreamController<TtsSentence>.broadcast();
  Stream<TtsSentence> get onSentenceChange => _sentenceController.stream;

  final StreamController<bool> _stateController = StreamController<bool>.broadcast();
  Stream<bool> get onPlayStateChange => _stateController.stream;

  final StreamController<String> _errorController = StreamController<String>.broadcast();
  Stream<String> get onError => _errorController.stream;

  Future<void> init() async {}

  Future<FlutterTts> _ensureSystemTts() async {
    final tts = _flutterTts ??= FlutterTts();
    if (!_systemTtsReady) {
      _systemTtsReady = true;
      tts.setCompletionHandler(() {
        if (_isTesting) {
          stop();
          return;
        }
        if (_isPlaying && !_isPaused) {
          _consecutiveErrors = 0;
          _playNext();
        }
      });
      tts.setErrorHandler((msg) {
        if (_isPlaying && !_isPaused) {
          _handlePlaybackError('系统语音报错: $msg', _requestToken);
        }
      });
      try {
        await tts.awaitSpeakCompletion(false);
      } catch (_) {}
      try {
        await tts.setSpeechRate((_config.speed * 0.5).clamp(0.0, 1.0));
        await tts.setPitch(_config.pitch.clamp(0.5, 2.0));
      } catch (_) {}
    }
    return tts;
  }

  AudioPlayer _ensureAudioPlayer() {
    final player = _audioPlayer ??= AudioPlayer();
    if (!_audioPlayerReady) {
      _audioPlayerReady = true;
      try {
        player.setReleaseMode(ReleaseMode.stop);
      } catch (_) {}
      player.onPlayerComplete.listen((_) {
        if (_isTesting) {
          stop();
          return;
        }
        if (_isPlaying && !_isPaused) {
          _consecutiveErrors = 0;
          _playNext();
        }
      });
      player.onLog.listen((logMsg) {
        final lower = logMsg.toLowerCase();
        if (lower.contains('error') || lower.contains('exception') || lower.contains('failed')) {
          _lastPlayerLogError = logMsg;
          debugPrint('AudioPlayer log error: $logMsg');
          if (_isPlaying && !_isPaused && !_isTesting) {
            _handlePlaybackError('音频播放异常: $logMsg', _requestToken);
          }
        }
      });
    }
    return player;
  }

  Future<void> updateConfig(TtsEngineConfig config) async {
    _config = config;
    if (_flutterTts != null) {
      try {
        await _flutterTts!.setSpeechRate((config.speed * 0.5).clamp(0.0, 1.0));
        await _flutterTts!.setPitch(config.pitch.clamp(0.5, 2.0));
      } catch (_) {}
    }
  }

  Future<void> startReading({
    required Chapter chapter,
    required int startOffset,
  }) async {
    await stop();
    await init();

    _queue = PageEngine.splitSentences(chapter.content, chapter.index);
    if (_queue.isEmpty) {
      onChapterComplete?.call();
      return;
    }

    _currentIndex = 0;
    for (int i = 0; i < _queue.length; i++) {
      if (startOffset <= _queue[i].endOffset) {
        _currentIndex = i;
        break;
      }
    }

    _consecutiveErrors = 0;
    _isTesting = false;
    _isPlaying = true;
    _isPaused = false;
    _stateController.add(true);
    _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    final token = ++_requestToken;
    if (!_isPlaying || _isPaused) return;

    if (_currentIndex >= _queue.length) {
      if (onChapterComplete != null) {
        onChapterComplete!();
      } else {
        await stop();
      }
      return;
    }

    final sentence = _queue[_currentIndex];
    _sentenceController.add(sentence);

    try {
      if (_config.type == TtsEngineType.system) {
        final tts = await _ensureSystemTts();
        final targetLang = RegExp(r'[\u4e00-\u9fa5]').hasMatch(sentence.text) ? 'zh-CN' : 'en-US';
        if (_lastLang != targetLang) {
          _lastLang = targetLang;
          await tts.setLanguage(targetLang);
        }
        if (token == _requestToken && _isPlaying && !_isPaused) {
          await tts.speak(sentence.text);
        }
      } else if (_config.type == TtsEngineType.fishAudio) {
        await _callFishAudio(sentence.text, token);
      } else if (_config.type == TtsEngineType.customHttp) {
        await _callCustomHttp(sentence.text, token);
      }
    } catch (e) {
      _handlePlaybackError(e.toString(), token);
    }
  }

  void _handlePlaybackError(String message, int token) {
    if (token != _requestToken || !_isPlaying || _isPaused) return;
    _consecutiveErrors++;
    debugPrint('TTS 朗读出错 ($_consecutiveErrors): $message');

    if (_consecutiveErrors >= 3) {
      _errorController.add('TTS 连续失败 3 次已自动停止：$message');
      stop();
      return;
    }

    Future.delayed(const Duration(milliseconds: 1200), () {
      if (token == _requestToken && _isPlaying && !_isPaused) {
        _playNext();
      }
    });
  }

  String _detectAudioExtension(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return 'wav';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x4F &&
        bytes[1] == 0x67 &&
        bytes[2] == 0x67 &&
        bytes[3] == 0x53) {
      return 'ogg';
    }
    return 'mp3';
  }

  Future<void> _playAudioBytes(
    Uint8List bytes,
    double speed,
    int token, {
    bool serverAppliedSpeed = false,
  }) async {
    if (bytes.isEmpty) {
      throw Exception('接口返回的音频数据为空');
    }
    if (token != _requestToken || !_isPlaying || _isPaused) return;
    final player = _ensureAudioPlayer();
    _lastPlayerLogError = null;

    try {
      await player.stop();
    } catch (_) {}
    if (token != _requestToken || !_isPlaying || _isPaused) return;

    final ext = _detectAudioExtension(bytes);
    bool played = false;
    try {
      // 优先落盘为临时文件并通过 DeviceFileSource 播放，避免 Android BytesSource 兼容性问题
      final tmpDir = await getTemporaryDirectory();
      final tmpFile = File(
        '${tmpDir.path}${Platform.pathSeparator}tts_cache_${token % 6}.$ext',
      );
      await tmpFile.writeAsBytes(bytes, flush: true);
      if (token != _requestToken || !_isPlaying || _isPaused) return;
      await player.play(DeviceFileSource(tmpFile.path));
      played = true;
    } catch (_) {}

    if (!played) {
      if (token != _requestToken || !_isPlaying || _isPaused) return;
      await player.play(
        BytesSource(
          bytes,
          mimeType: ext == 'wav' ? 'audio/wav' : (ext == 'ogg' ? 'audio/ogg' : 'audio/mpeg'),
        ),
      );
    }

    if (!serverAppliedSpeed && (speed - 1.0).abs() >= 0.05) {
      try {
        await player.setPlaybackRate(speed.clamp(0.5, 2.5));
      } catch (_) {}
    }
  }

  String _cleanApiKey(String raw) {
    var s = raw.trim();
    if (s.toLowerCase().startsWith('bearer ')) {
      s = s.substring(7).trim();
    }
    return s;
  }

  String _extractHttpErrorBody(http.Response resp) {
    try {
      final text = utf8.decode(resp.bodyBytes, allowMalformed: true).trim();
      if (text.isEmpty) return '';
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        final msg = decoded['message'] ?? decoded['detail'] ?? decoded['error'];
        if (msg != null) return msg.toString();
      }
      return text.length > 160 ? '${text.substring(0, 160)}...' : text;
    } catch (_) {
      return '';
    }
  }

  void _validateAudioResponse(http.Response resp, String label) {
    if (resp.statusCode != 200) {
      final detail = _extractHttpErrorBody(resp);
      throw Exception(
        detail.isEmpty ? '$label 错误 HTTP ${resp.statusCode}' : '$label 错误 ${resp.statusCode}: $detail',
      );
    }
    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    if (ct.contains('application/json') || ct.startsWith('text/')) {
      final detail = _extractHttpErrorBody(resp);
      throw Exception('$label 返回了非音频内容: ${detail.isEmpty ? ct : detail}');
    }
    if (resp.bodyBytes.isEmpty) {
      throw Exception('$label 返回了空音频');
    }
  }

  Future<void> _callFishAudio(String text, int token) async {
    final endpoint = _config.apiEndpoint.trim().isNotEmpty
        ? _config.apiEndpoint.trim()
        : 'https://api.fish.audio/v1/tts';
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme) {
      throw Exception('Fish.Audio 接口地址无效');
    }

    final apiKey = _cleanApiKey(_config.apiKey);
    if (apiKey.isEmpty) {
      throw Exception('请先填写 Fish.Audio API Key');
    }

    final voiceId = _config.voiceId.trim();
    final model = _config.model.trim().isNotEmpty ? _config.model.trim() : 's2.1-pro';

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $apiKey',
      'model': model,
      ..._config.customHeaders,
    };

    final body = jsonEncode({
      'text': text,
      if (voiceId.isNotEmpty) 'reference_id': voiceId,
      'format': 'mp3',
      'prosody': {
        'speed': double.parse(_config.speed.clamp(0.5, 2.0).toStringAsFixed(2)),
      },
    });

    final resp = await http
        .post(uri, headers: headers, body: body)
        .timeout(const Duration(seconds: 30));

    if (token != _requestToken || !_isPlaying || _isPaused) return;

    _validateAudioResponse(resp, 'Fish.Audio');
    _consecutiveErrors = 0;
    await _playAudioBytes(resp.bodyBytes, _config.speed, token, serverAppliedSpeed: true);
  }

  String _escapeJsonInner(String raw) {
    final encoded = jsonEncode(raw);
    return encoded.substring(1, encoded.length - 1);
  }

  String _formatSpeed(double speed) {
    return double.parse(speed.clamp(0.5, 2.5).toStringAsFixed(2)).toString();
  }

  String _applyTemplate(String template, String text, {required bool urlEncode}) {
    final speedStr = _formatSpeed(_config.speed);
    final voiceStr = _config.voiceId.trim();
    final keyStr = _cleanApiKey(_config.apiKey);

    String encode(String val) => urlEncode ? Uri.encodeComponent(val) : _escapeJsonInner(val);

    return template
        .replaceAll('{{text}}', encode(text))
        .replaceAll('{text}', encode(text))
        .replaceAll('{{speed}}', encode(speedStr))
        .replaceAll('{speed}', encode(speedStr))
        .replaceAll('{{voice}}', encode(voiceStr))
        .replaceAll('{voice}', encode(voiceStr))
        .replaceAll('{{voice_id}}', encode(voiceStr))
        .replaceAll('{voice_id}', encode(voiceStr))
        .replaceAll('{{token}}', encode(keyStr))
        .replaceAll('{token}', encode(keyStr))
        .replaceAll('{{api_key}}', encode(keyStr))
        .replaceAll('{api_key}', encode(keyStr));
  }

  Future<void> _callCustomHttp(String text, int token) async {
    final rawUrl = _config.apiEndpoint.trim();
    if (rawUrl.isEmpty) {
      throw Exception('请先配置自定义 HTTP 接口地址');
    }

    final urlStr = _applyTemplate(rawUrl, text, urlEncode: true);
    final uri = Uri.tryParse(urlStr);
    if (uri == null || !uri.hasScheme) {
      throw Exception('自定义接口 URL 格式无效');
    }

    final apiKey = _cleanApiKey(_config.apiKey);
    final headers = Map<String, String>.from(_config.customHeaders);
    final hasAuthHeader = headers.keys.any((k) => k.toLowerCase() == 'authorization');
    if (apiKey.isNotEmpty && !hasAuthHeader) {
      headers['Authorization'] = 'Bearer $apiKey';
    }

    final bodyStr = _applyTemplate(_config.customBodyTemplate, text, urlEncode: false);
    final usePost = _config.method.toUpperCase() == 'POST' ||
        (_config.method.toUpperCase() != 'GET' && bodyStr.trim().isNotEmpty);

    final http.Response resp;
    try {
      if (usePost) {
        if (!headers.keys.any((k) => k.toLowerCase() == 'content-type')) {
          headers['Content-Type'] = 'application/json';
        }
        resp = await http
            .post(uri, headers: headers, body: bodyStr)
            .timeout(const Duration(seconds: 30));
      } else {
        resp = await http.get(uri, headers: headers).timeout(const Duration(seconds: 30));
      }
    } catch (e) {
      final msg = e.toString();
      if (uri.scheme == 'http' && msg.toLowerCase().contains('cleartext')) {
        throw Exception('Android 拦截了 http 明文请求，请在 AndroidManifest.xml 开启 usesCleartextTraffic');
      }
      rethrow;
    }

    if (token != _requestToken || !_isPlaying || _isPaused) return;

    _validateAudioResponse(resp, 'HTTP');
    _consecutiveErrors = 0;
    final hasSpeedInTemplate =
        rawUrl.contains('speed') || _config.customBodyTemplate.contains('speed');
    await _playAudioBytes(
      resp.bodyBytes,
      _config.speed,
      token,
      serverAppliedSpeed: hasSpeedInTemplate,
    );
  }

  Future<String?> testConfig(TtsEngineConfig config) async {
    await stop();
    await init();
    await updateConfig(config);

    const sample = '这是一段语音测试，欢迎使用本地听书阅读器。';
    _queue = [];
    _currentIndex = 0;
    _isTesting = true;
    final token = ++_requestToken;
    _isPlaying = true;
    _isPaused = false;
    _lastPlayerLogError = null;

    try {
      if (config.type == TtsEngineType.system) {
        final tts = await _ensureSystemTts();
        await tts.setLanguage('zh-CN');
        _lastLang = 'zh-CN';
        await tts.speak(sample);
      } else if (config.type == TtsEngineType.fishAudio) {
        await _callFishAudio(sample, token);
      } else {
        await _callCustomHttp(sample, token);
      }

      await Future.delayed(const Duration(milliseconds: 250));
      if (_lastPlayerLogError != null) {
        final err = _lastPlayerLogError!;
        await stop();
        return '音频播放器报错: $err';
      }
      return null;
    } catch (e) {
      await stop();
      return e.toString();
    }
  }

  void _playNext() {
    if (!_isPlaying || _isPaused || _isTesting) return;
    _currentIndex++;
    _speakCurrent();
  }

  Future<void> nextSentence() async {
    if (!_isPlaying) return;
    _requestToken++;
    await _stopMedia();
    if (!_isPlaying) return;
    _isPaused = false;
    _stateController.add(true);
    _currentIndex++;
    _speakCurrent();
  }

  Future<void> prevSentence() async {
    if (!_isPlaying) return;
    _requestToken++;
    await _stopMedia();
    if (!_isPlaying) return;
    _isPaused = false;
    _stateController.add(true);
    _currentIndex = (_currentIndex > 0) ? _currentIndex - 1 : 0;
    _speakCurrent();
  }

  Future<void> pause() async {
    _isPaused = true;
    _requestToken++;
    _stateController.add(false);
    await _stopMedia();
  }

  Future<void> resume() async {
    if (!_isPlaying) return;
    _isPaused = false;
    _stateController.add(true);
    _speakCurrent();
  }

  Future<void> stop() async {
    _isPlaying = false;
    _isPaused = false;
    _isTesting = false;
    _requestToken++;
    _stateController.add(false);
    await _stopMedia();
  }

  Future<void> _stopMedia() async {
    if (_flutterTts != null) {
      try {
        await _flutterTts!.stop();
      } catch (_) {}
    }
    if (_audioPlayer != null) {
      try {
        await _audioPlayer!.stop();
      } catch (_) {}
    }
  }
}

// ==================== 书架主界面 ====================

class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key});

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  List<Book> _books = [];
  bool _einkMode = false;
  bool _importing = false;
  bool _loading = true;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      await Storage.init();
      final books = Storage.getBooks();
      final eink = Storage.getEinkMode();
      final currentTts = Storage.getActiveTtsEngine();
      await TtsService().updateConfig(currentTts);
      if (!mounted) return;
      setState(() {
        _books = books;
        _einkMode = eink;
        _loading = false;
        _initError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _initError = e.toString();
      });
    }
  }

  Future<void> _importBook() async {
    if (_importing) return;
    setState(() => _importing = true);

    try {
      final PlatformFile? picked = await FilePicker.pickFile(
        type: FileType.any,
      );

      if (picked != null) {
        final filename = picked.name;
        final lowerName = filename.toLowerCase();
        if (!lowerName.endsWith('.txt') && !lowerName.endsWith('.epub')) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('仅支持导入 TXT 或 EPUB 格式文件')),
            );
          }
          return;
        }

        final format = lowerName.endsWith('.epub') ? 'epub' : 'txt';
        final title = filename.replaceAll(RegExp(r'\.(txt|epub)$', caseSensitive: false), '');
        final safeName = filename.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

        final booksDir = await Storage.getBooksDir();
        final targetPath =
            '${booksDir.path}${Platform.pathSeparator}${DateTime.now().millisecondsSinceEpoch}_$safeName';

        bool copied = false;
        if (picked.path != null) {
          try {
            final srcFile = File(picked.path!);
            if (await srcFile.exists()) {
              await srcFile.copy(targetPath);
              copied = true;
            }
          } catch (_) {}
        }
        if (!copied) {
          final targetFile = File(targetPath);
          try {
            final sink = targetFile.openWrite();
            try {
              await sink.addStream(picked.readAsByteStream());
            } finally {
              await sink.close();
            }
          } catch (_) {
            final bytes = await picked.readAsBytes();
            await targetFile.writeAsBytes(bytes, flush: true);
          }
        }

        final newBook = Book(
          id: DateTime.now().millisecondsSinceEpoch.toString(),
          title: title,
          author: '本地导入',
          filePath: targetPath,
          format: format,
        );

        await Storage.saveBook(newBook);
        await _loadData();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入书籍失败: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _importing = false);
      }
    }
  }

  void _showTtsSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => const TtsSettingsDialog(),
    ).then((_) => _loadData());
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _einkMode ? Colors.white : Theme.of(context).scaffoldBackgroundColor;
    final cardColor = _einkMode ? Colors.white : Theme.of(context).cardColor;
    final textColor = _einkMode ? Colors.black : null;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          Storage.isPortableMode ? '本地书架 (便携版)' : '本地书架',
          style: TextStyle(color: textColor),
        ),
        backgroundColor: _einkMode ? Colors.white : null,
        foregroundColor: textColor,
        elevation: _einkMode ? 0 : 2,
        actions: [
          IconButton(
            icon: Icon(_einkMode ? Icons.contrast : Icons.contrast_outlined),
            tooltip: '墨水屏高对比度模式',
            onPressed: () async {
              final next = !_einkMode;
              await Storage.setEinkMode(next);
              if (mounted) setState(() => _einkMode = next);
            },
          ),
          IconButton(
            icon: const Icon(Icons.record_voice_over),
            tooltip: 'TTS 引擎设置 (含 Fish.Audio / 中转)',
            onPressed: _showTtsSettingsDialog,
          ),
          IconButton(
            icon: _importing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            tooltip: '导入本地图书 (TXT/EPUB)',
            onPressed: _importing ? null : _importBook,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _initError != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('初始化异常: $_initError', style: const TextStyle(color: Colors.red)),
                  ),
                )
              : _books.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.menu_book,
                            size: 64,
                            color: _einkMode ? Colors.black54 : Colors.grey,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '书架暂无图书',
                            style: TextStyle(fontSize: 18, color: textColor ?? Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.file_open),
                            label: const Text('导入 TXT 或 EPUB 文件'),
                            onPressed: _importing ? null : _importBook,
                          ),
                        ],
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: _books.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: _einkMode ? Colors.black26 : null),
                      itemBuilder: (context, index) {
                        final book = _books[index];
                        return ListTile(
                          tileColor: cardColor,
                          leading: Container(
                            width: 44,
                            height: 56,
                            decoration: BoxDecoration(
                              color: _einkMode ? Colors.white : Colors.blueGrey.shade50,
                              border: Border.all(color: _einkMode ? Colors.black : Colors.black26),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              book.format.toUpperCase(),
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 12,
                                color: _einkMode ? Colors.black : Colors.blueGrey.shade800,
                              ),
                            ),
                          ),
                          title: Text(
                            book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontWeight: FontWeight.w600, color: textColor),
                          ),
                          subtitle: Text(
                            '读至第 ${book.currentChapterIndex + 1} 章 · 进度 ${(book.progress * 100).toStringAsFixed(1)}%',
                            style:
                                TextStyle(color: _einkMode ? Colors.black87 : Colors.grey.shade600),
                          ),
                          trailing: Icon(Icons.chevron_right, color: textColor),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => ReaderScreen(book: book)),
                            );
                            _loadData();
                          },
                          onLongPress: () {
                            showDialog(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text('删除 《${book.title}》？'),
                                content: const Text('将从书架移除，并清理本地副本及关联书签。'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx),
                                    child: const Text('取消'),
                                  ),
                                  ElevatedButton(
                                    onPressed: () async {
                                      final f = File(book.filePath);
                                      if (await f.exists()) {
                                        try {
                                          await f.delete();
                                        } catch (_) {}
                                      }
                                      await Storage.removeBook(book.id);
                                      if (ctx.mounted) Navigator.pop(ctx);
                                      _loadData();
                                    },
                                    child: const Text('删除'),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
    );
  }
}

// ==================== TTS 引擎设置对话框 ====================

class TtsSettingsDialog extends StatefulWidget {
  const TtsSettingsDialog({super.key});

  @override
  State<TtsSettingsDialog> createState() => _TtsSettingsDialogState();
}

class _TtsSettingsDialogState extends State<TtsSettingsDialog> {
  late List<TtsEngineConfig> _engines;
  late TtsEngineConfig _current;

  late TextEditingController _nameCtrl;
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _voiceIdCtrl;
  late TextEditingController _modelCtrl;
  late TextEditingController _endpointCtrl;
  late TextEditingController _bodyTemplateCtrl;

  bool _testing = false;
  String? _testMessage;
  bool _testSuccess = false;

  @override
  void initState() {
    super.initState();
    _engines = Storage.getTtsEngines();
    _current = Storage.getActiveTtsEngine();
    _nameCtrl = TextEditingController(text: _current.name);
    _apiKeyCtrl = TextEditingController(text: _current.apiKey);
    _voiceIdCtrl = TextEditingController(text: _current.voiceId);
    _modelCtrl = TextEditingController(text: _current.model);
    _endpointCtrl = TextEditingController(text: _current.apiEndpoint);
    _bodyTemplateCtrl = TextEditingController(text: _current.customBodyTemplate);
  }

  void _updateControllers() {
    _nameCtrl.text = _current.name;
    _apiKeyCtrl.text = _current.apiKey;
    _voiceIdCtrl.text = _current.voiceId;
    _modelCtrl.text = _current.model;
    _endpointCtrl.text = _current.apiEndpoint;
    _bodyTemplateCtrl.text = _current.customBodyTemplate;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _apiKeyCtrl.dispose();
    _voiceIdCtrl.dispose();
    _modelCtrl.dispose();
    _endpointCtrl.dispose();
    _bodyTemplateCtrl.dispose();
    super.dispose();
  }

  void _syncCurrentFromControllers() {
    _current = _current.copyWith(
      name: _nameCtrl.text,
      apiKey: _apiKeyCtrl.text,
      voiceId: _voiceIdCtrl.text,
      model: _modelCtrl.text,
      apiEndpoint: _endpointCtrl.text,
      customBodyTemplate: _bodyTemplateCtrl.text,
    );
  }

  Future<void> _testCurrentEngine() async {
    _syncCurrentFromControllers();
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    final err = await TtsService().testConfig(_current);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testSuccess = err == null;
      _testMessage = err == null ? '测试请求成功，正在播放试听语音' : '测试失败: $err';
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('TTS 朗读引擎配置'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('选择当前使用的引擎：', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _current.id,
                      items: _engines
                          .map((e) => DropdownMenuItem(value: e.id, child: Text(e.name)))
                          .toList(),
                      onChanged: (val) {
                        if (val != null) {
                          _syncCurrentFromControllers();
                          final idx = _engines.indexWhere((e) => e.id == _current.id);
                          if (idx >= 0) _engines[idx] = _current;
                          setState(() {
                            _current = _engines.firstWhere((e) => e.id == val);
                            _updateControllers();
                            _testMessage = null;
                          });
                        }
                      },
                    ),
                  ),
                  if (_current.type != TtsEngineType.system && _engines.length > 1)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      tooltip: '删除此引擎',
                      onPressed: () {
                        setState(() {
                          _engines.removeWhere((e) => e.id == _current.id);
                          _current = _engines.first;
                          _updateControllers();
                          _testMessage = null;
                        });
                      },
                    ),
                ],
              ),
              const Divider(height: 24),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(
                  labelText: '引擎显示名称',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              if (_current.type == TtsEngineType.fishAudio) ...[
                const Text('Fish.Audio 专属参数', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: _apiKeyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Fish.Audio API Key',
                    hintText: '填入你的 Fish.Audio Token',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _voiceIdCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Reference ID (发音人 ID)',
                    hintText: kDefaultFishVoiceId,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _modelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Model 请求头 (如 s2.1-pro / s2.1-pro-free / s1)',
                    hintText: 's2.1-pro',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _endpointCtrl,
                  decoration: const InputDecoration(
                    labelText: 'API 端点',
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else if (_current.type == TtsEngineType.customHttp) ...[
                const Text('自定义通用 HTTP / 中转引擎',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('请求方式：'),
                    const SizedBox(width: 8),
                    DropdownButton<String>(
                      value: _current.method == 'POST' ? 'POST' : 'GET',
                      items: const [
                        DropdownMenuItem(value: 'GET', child: Text('GET')),
                        DropdownMenuItem(value: 'POST', child: Text('POST')),
                      ],
                      onChanged: (m) {
                        if (m != null) {
                          setState(() => _current = _current.copyWith(method: m));
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _endpointCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: '接口地址 (支持 {{text}}, {{speed}}, {{voice}}, {{token}})',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _apiKeyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Token / API Key (可选，自动附加 Bearer)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _voiceIdCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Voice 发音人 ID (替换 {{voice}})',
                    hintText: kDefaultFishVoiceId,
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _bodyTemplateCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'POST JSON 模板 (GET 请求留空)',
                    hintText: '{"model":"tts-1","input":"{{text}}"}',
                    border: OutlineInputBorder(),
                  ),
                ),
              ] else ...[
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('使用系统内置 TTS 语音库，无需联网，离线可用。'),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('语速：'),
                  Expanded(
                    child: Slider(
                      value: _current.speed.clamp(0.5, 2.0),
                      min: 0.5,
                      max: 2.0,
                      divisions: 15,
                      label: '${_current.speed.toStringAsFixed(1)}x',
                      onChanged: (v) => setState(() => _current = _current.copyWith(speed: v)),
                    ),
                  ),
                  Text('${_current.speed.toStringAsFixed(1)}x'),
                ],
              ),
              if (_current.type == TtsEngineType.system)
                Row(
                  children: [
                    const Text('音调：'),
                    Expanded(
                      child: Slider(
                        value: _current.pitch.clamp(0.5, 2.0),
                        min: 0.5,
                        max: 2.0,
                        divisions: 15,
                        label: _current.pitch.toStringAsFixed(1),
                        onChanged: (v) => setState(() => _current = _current.copyWith(pitch: v)),
                      ),
                    ),
                    Text(_current.pitch.toStringAsFixed(1)),
                  ],
                ),
              if (_testMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(
                    _testMessage!,
                    style: TextStyle(
                      fontSize: 12,
                      color: _testSuccess ? Colors.green.shade700 : Colors.red,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await TtsService().stop();
            await TtsService().updateConfig(Storage.getActiveTtsEngine());
            if (mounted) Navigator.pop(context);
          },
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _testing ? null : _testCurrentEngine,
          child: Text(_testing ? '测试中...' : '测试朗读'),
        ),
        TextButton(
          onPressed: () {
            _syncCurrentFromControllers();
            final idx = _engines.indexWhere((e) => e.id == _current.id);
            if (idx >= 0) _engines[idx] = _current;

            final suffix = DateTime.now().millisecondsSinceEpoch % 10000;
            final newEng = TtsEngineConfig(
              id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
              name: '自定义引擎 $suffix',
              type: TtsEngineType.customHttp,
              method: 'GET',
              voiceId: kDefaultFishVoiceId,
            );
            setState(() {
              _engines.add(newEng);
              _current = newEng;
              _updateControllers();
              _testMessage = null;
            });
          },
          child: const Text('新增引擎'),
        ),
        ElevatedButton(
          onPressed: () async {
            _syncCurrentFromControllers();
            final idx = _engines.indexWhere((e) => e.id == _current.id);
            if (idx >= 0) _engines[idx] = _current;

            await Storage.saveTtsEngines(_engines);
            await Storage.setActiveTtsEngine(_current.id);
            await TtsService().updateConfig(_current);
            if (mounted) Navigator.pop(context);
          },
          child: const Text('保存生效'),
        ),
      ],
    );
  }
}

// ==================== 阅读器界面 ====================

class ReaderScreen extends StatefulWidget {
  final Book book;
  const ReaderScreen({super.key, required this.book});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  final FocusNode _readerFocusNode = FocusNode();

  List<Chapter> _chapters = [];
  bool _loading = true;
  String _error = '';

  int _chapterIndex = 0;
  int _pageIndex = 0;
  List<int> _pageStarts = [0];
  Size _lastContentSize = Size.zero;
  TextStyle _lastTextStyle = const TextStyle(fontSize: 20.0, height: 1.6);
  TextScaler _lastTextScaler = TextScaler.noScaling;
  bool _initialPaginated = false;

  double _fontSize = 20.0;
  double _lineHeight = 1.6;
  double _margin = 16.0;
  bool _einkMode = false;
  bool _showMenu = false;

  final TtsService _tts = TtsService();
  bool _isTtsActive = false;
  TtsSentence? _currentTtsSentence;
  StreamSubscription? _ttsSub;
  StreamSubscription? _ttsStateSub;
  StreamSubscription? _ttsErrorSub;

  @override
  void initState() {
    super.initState();
    _chapterIndex = widget.book.currentChapterIndex;
    _fontSize = Storage.getFontSize();
    _lineHeight = Storage.getLineHeight();
    _margin = Storage.getMargin();
    _einkMode = Storage.getEinkMode();
    _initTts();
    _loadBook();
  }

  void _initTts() {
    _ttsSub = _tts.onSentenceChange.listen((sentence) {
      if (!mounted) return;
      setState(() {
        _currentTtsSentence = sentence;
      });
      if (sentence.chapterIndex == _chapterIndex) {
        final targetPage = PageEngine.findPageIndexForOffset(_pageStarts, sentence.startOffset);
        if (targetPage != _pageIndex) {
          setState(() {
            _pageIndex = targetPage;
          });
          _saveProgress();
        }
      }
    });

    _ttsStateSub = _tts.onPlayStateChange.listen((_) {
      if (!mounted) return;
      setState(() {
        _isTtsActive = _tts.isPlaying;
      });
    });

    _ttsErrorSub = _tts.onError.listen((msg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    });

    _tts.onChapterComplete = () {
      if (!mounted) return;
      int nextIdx = _chapterIndex + 1;
      while (nextIdx < _chapters.length && _chapters[nextIdx].content.trim().isEmpty) {
        nextIdx++;
      }
      if (nextIdx < _chapters.length) {
        setState(() {
          _chapterIndex = nextIdx;
          _pageIndex = 0;
          _recomputePagination(
            _lastContentSize,
            style: _lastTextStyle,
            textScaler: _lastTextScaler,
            targetOffset: 0,
          );
        });
        _saveProgress();
        _tts.startReading(chapter: _chapters[_chapterIndex], startOffset: 0);
      } else {
        _tts.stop();
      }
    };
  }

  @override
  void dispose() {
    _readerFocusNode.dispose();
    _ttsSub?.cancel();
    _ttsStateSub?.cancel();
    _ttsErrorSub?.cancel();
    _tts.onChapterComplete = null;
    _tts.stop();
    _saveProgress();
    super.dispose();
  }

  Future<void> _loadBook() async {
    try {
      final chapters = await BookParser.parse(widget.book.filePath, widget.book.format);
      if (chapters.isEmpty) throw Exception('书籍内容为空');
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _chapterIndex = _chapterIndex.clamp(0, chapters.length - 1);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  TextStyle _resolvedTextStyle(BuildContext context) {
    return DefaultTextStyle.of(context).style.merge(
          TextStyle(fontSize: _fontSize, height: _lineHeight),
        );
  }

  void _recomputePagination(
    Size contentSize, {
    required TextStyle style,
    required TextScaler textScaler,
    int? targetOffset,
  }) {
    if (_chapters.isEmpty || contentSize.width <= 0 || contentSize.height <= 0) return;

    final chapter = _chapters[_chapterIndex];
    final offsetToRestore = targetOffset ??
        ((_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : widget.book.currentOffset);

    final starts = PageEngine.paginate(
      text: chapter.content,
      style: style,
      contentAreaSize: contentSize,
      textScaler: textScaler,
    );

    _pageStarts = starts;
    _pageIndex = PageEngine.findPageIndexForOffset(starts, offsetToRestore);
    _lastContentSize = contentSize;
    _lastTextStyle = style;
    _lastTextScaler = textScaler;
  }

  void _saveProgress() {
    if (_chapters.isEmpty) return;
    final currentOffset = (_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : 0;
    widget.book.currentChapterIndex = _chapterIndex;
    widget.book.currentOffset = currentOffset;

    final totalChapters = _chapters.length;
    final double chapterFraction;
    if (_pageStarts.length <= 1 || _pageIndex >= _pageStarts.length - 1) {
      chapterFraction = 1.0;
    } else {
      chapterFraction = _pageIndex / (_pageStarts.length - 1);
    }

    widget.book.progress = ((_chapterIndex + chapterFraction) / totalChapters).clamp(0.0, 1.0);
    widget.book.lastReadTime = DateTime.now();

    Storage.saveBook(widget.book);
  }

  void _prevPage() {
    if (_pageIndex > 0) {
      setState(() => _pageIndex--);
      _saveProgress();
    } else if (_chapterIndex > 0) {
      setState(() {
        _chapterIndex--;
        final prevChapter = _chapters[_chapterIndex];
        final prevStarts = PageEngine.paginate(
          text: prevChapter.content,
          style: _lastTextStyle,
          contentAreaSize: _lastContentSize,
          textScaler: _lastTextScaler,
        );
        _pageStarts = prevStarts;
        _pageIndex = (prevStarts.length > 1) ? prevStarts.length - 1 : 0;
      });
      _saveProgress();
    }
  }

  void _nextPage() {
    if (_pageIndex < _pageStarts.length - 1) {
      setState(() => _pageIndex++);
      _saveProgress();
    } else if (_chapterIndex < _chapters.length - 1) {
      setState(() {
        _chapterIndex++;
        _pageIndex = 0;
        _recomputePagination(
          _lastContentSize,
          style: _lastTextStyle,
          textScaler: _lastTextScaler,
          targetOffset: 0,
        );
      });
      _saveProgress();
    }
  }

  void _toggleTts() {
    if (_isTtsActive) {
      _tts.stop();
      setState(() => _isTtsActive = false);
    } else {
      final currentOffset = (_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : 0;
      _tts.startReading(chapter: _chapters[_chapterIndex], startOffset: currentOffset);
      setState(() => _isTtsActive = true);
    }
  }

  void _addBookmark() {
    final currentOffset = (_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : 0;
    final chapter = _chapters[_chapterIndex];
    final preview = chapter.content
        .substring(
          currentOffset,
          (currentOffset + 40).clamp(0, chapter.content.length),
        )
        .replaceAll('\n', ' ');

    final bookmark = Bookmark(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      bookId: widget.book.id,
      chapterIndex: _chapterIndex,
      offset: currentOffset,
      text: preview.isEmpty ? chapter.title : preview,
    );

    Storage.addBookmark(bookmark);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已添加当前书签'), duration: Duration(seconds: 1)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('加载失败')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error, style: const TextStyle(color: Colors.red)),
          ),
        ),
      );
    }

    final chapter = _chapters[_chapterIndex];
    final pageStart = (_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : 0;
    final pageEnd = (_pageIndex + 1 < _pageStarts.length)
        ? _pageStarts[_pageIndex + 1]
        : chapter.content.length;
    final pageText = chapter.content.substring(pageStart, pageEnd);

    final bgColor = _einkMode ? Colors.white : Theme.of(context).scaffoldBackgroundColor;
    final textColor = _einkMode ? Colors.black : Theme.of(context).textTheme.bodyMedium?.color;
    final baseStyle = _resolvedTextStyle(context);
    final textScaler = MediaQuery.textScalerOf(context);

    return Focus(
      focusNode: _readerFocusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.pageUp) {
            _prevPage();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
              event.logicalKey == LogicalKeyboardKey.pageDown ||
              event.logicalKey == LogicalKeyboardKey.space) {
            _nextPage();
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (_showMenu) {
              setState(() => _showMenu = false);
              return KeyEventResult.handled;
            }
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: bgColor,
        body: SafeArea(
          child: Stack(
            children: [
              // 主内容排版区
              Column(
                children: [
                  // 页眉
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: _margin, vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            chapter.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: _einkMode ? Colors.black87 : Colors.grey.shade600,
                            ),
                          ),
                        ),
                        Text(
                          '${_chapterIndex + 1}/${_chapters.length} 章',
                          style: TextStyle(
                            fontSize: 12,
                            color: _einkMode ? Colors.black87 : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // 页面正文
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: _margin),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final currentSize = Size(constraints.maxWidth, constraints.maxHeight);
                          if (!_initialPaginated ||
                              _lastContentSize != currentSize ||
                              _lastTextStyle != baseStyle ||
                              _lastTextScaler != textScaler) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                setState(() {
                                  final target =
                                      !_initialPaginated ? widget.book.currentOffset : null;
                                  _initialPaginated = true;
                                  _recomputePagination(
                                    currentSize,
                                    style: baseStyle,
                                    textScaler: textScaler,
                                    targetOffset: target,
                                  );
                                });
                              }
                            });
                          }
                          if (!_initialPaginated) {
                            return const Center(child: CircularProgressIndicator());
                          }
                          return _buildPageContent(
                            pageText,
                            pageStart,
                            baseStyle.copyWith(color: textColor),
                          );
                        },
                      ),
                    ),
                  ),

                  // 页脚
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: _margin, vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            widget.book.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: _einkMode ? Colors.black87 : Colors.grey.shade600,
                            ),
                          ),
                        ),
                        Text(
                          '${_pageIndex + 1}/${_pageStarts.length} 页',
                          style: TextStyle(
                            fontSize: 12,
                            color: _einkMode ? Colors.black87 : Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // 触控与滑动翻页区域（菜单展开时点击任意处关闭菜单）
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  if (_showMenu) return;
                  if (details.primaryVelocity != null) {
                    if (details.primaryVelocity! < -100) {
                      _nextPage();
                    } else if (details.primaryVelocity! > 100) {
                      _prevPage();
                    }
                  }
                },
                child: _showMenu
                    ? GestureDetector(
                        behavior: HitTestBehavior.translucent,
                        onTap: () => setState(() => _showMenu = false),
                        child: const SizedBox.expand(),
                      )
                    : Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: _prevPage,
                            ),
                          ),
                          Expanded(
                            flex: 4,
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: () => setState(() => _showMenu = true),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: GestureDetector(
                              behavior: HitTestBehavior.translucent,
                              onTap: _nextPage,
                            ),
                          ),
                        ],
                      ),
              ),

              // 顶部菜单栏
              if (_showMenu)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black87,
                    child: AppBar(
                      backgroundColor: Colors.transparent,
                      foregroundColor: Colors.white,
                      title: Text(widget.book.title, overflow: TextOverflow.ellipsis),
                      actions: [
                        IconButton(
                          icon: const Icon(Icons.record_voice_over),
                          tooltip: 'TTS 引擎设置',
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (ctx) => const TtsSettingsDialog(),
                            ).then((_) {
                              _readerFocusNode.requestFocus();
                            });
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.bookmark_add_outlined),
                          tooltip: '添加书签',
                          onPressed: _addBookmark,
                        ),
                        IconButton(
                          icon: const Icon(Icons.bookmarks),
                          tooltip: '书签列表',
                          onPressed: _showBookmarks,
                        ),
                        IconButton(
                          icon: const Icon(Icons.list),
                          tooltip: '目录',
                          onPressed: _showCatalog,
                        ),
                      ],
                    ),
                  ),
                ),

              // 底部控制与排版面板
              if (_showMenu)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    color: Colors.black87,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.text_decrease, color: Colors.white),
                              tooltip: '缩小字号',
                              onPressed: () {
                                setState(() {
                                  _fontSize = (_fontSize - 2).clamp(14.0, 36.0);
                                  _recomputePagination(
                                    _lastContentSize,
                                    style: _resolvedTextStyle(context),
                                    textScaler: textScaler,
                                  );
                                });
                                Storage.setFontSize(_fontSize);
                              },
                            ),
                            Text(
                              '${_fontSize.toInt()}sp',
                              style: const TextStyle(color: Colors.white),
                            ),
                            IconButton(
                              icon: const Icon(Icons.text_increase, color: Colors.white),
                              tooltip: '放大字号',
                              onPressed: () {
                                setState(() {
                                  _fontSize = (_fontSize + 2).clamp(14.0, 36.0);
                                  _recomputePagination(
                                    _lastContentSize,
                                    style: _resolvedTextStyle(context),
                                    textScaler: textScaler,
                                  );
                                });
                                Storage.setFontSize(_fontSize);
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                _einkMode ? Icons.contrast : Icons.contrast_outlined,
                                color: Colors.white,
                              ),
                              tooltip: '墨水屏模式',
                              onPressed: () {
                                setState(() => _einkMode = !_einkMode);
                                Storage.setEinkMode(_einkMode);
                              },
                            ),
                            IconButton(
                              icon: Icon(
                                _isTtsActive ? Icons.volume_up : Icons.volume_off,
                                color: Colors.white,
                              ),
                              tooltip: '朗读听书',
                              onPressed: _toggleTts,
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            const Text('行距',
                                style: TextStyle(color: Colors.white70, fontSize: 12)),
                            Expanded(
                              child: Slider(
                                value: _lineHeight.clamp(1.2, 2.4),
                                min: 1.2,
                                max: 2.4,
                                divisions: 12,
                                onChanged: (v) {
                                  setState(() {
                                    _lineHeight = double.parse(v.toStringAsFixed(1));
                                    _recomputePagination(
                                      _lastContentSize,
                                      style: _resolvedTextStyle(context),
                                      textScaler: textScaler,
                                    );
                                  });
                                  Storage.setLineHeight(_lineHeight);
                                },
                              ),
                            ),
                            const Text('边距',
                                style: TextStyle(color: Colors.white70, fontSize: 12)),
                            Expanded(
                              child: Slider(
                                value: _margin.clamp(8.0, 40.0),
                                min: 8.0,
                                max: 40.0,
                                divisions: 8,
                                onChanged: (v) {
                                  setState(() {
                                    _margin = v;
                                  });
                                  Storage.setMargin(_margin);
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),

              // TTS 朗读悬浮控制胶囊
              if (_isTtsActive)
                Positioned(
                  bottom: _showMenu ? 128 : 24,
                  left: 20,
                  right: 20,
                  child: Card(
                    elevation: 6,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                    color: _einkMode ? Colors.white : Colors.blueGrey.shade900,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            icon: Icon(
                              Icons.skip_previous,
                              color: _einkMode ? Colors.black : Colors.white,
                            ),
                            onPressed: () => _tts.prevSentence(),
                          ),
                          IconButton(
                            icon: Icon(
                              _tts.isPaused ? Icons.play_arrow : Icons.pause,
                              color: _einkMode ? Colors.black : Colors.white,
                            ),
                            onPressed: () {
                              if (_tts.isPaused) {
                                _tts.resume();
                              } else {
                                _tts.pause();
                              }
                              setState(() {});
                            },
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.skip_next,
                              color: _einkMode ? Colors.black : Colors.white,
                            ),
                            onPressed: () => _tts.nextSentence(),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.close,
                              color: _einkMode ? Colors.black : Colors.white,
                            ),
                            onPressed: () => _tts.stop(),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPageContent(String pageText, int pageStart, TextStyle style) {
    if (!_isTtsActive ||
        _currentTtsSentence == null ||
        _currentTtsSentence!.chapterIndex != _chapterIndex) {
      return Text.rich(TextSpan(text: pageText, style: style));
    }

    final sStart = _currentTtsSentence!.startOffset - pageStart;
    final sEnd = _currentTtsSentence!.endOffset - pageStart;

    if (sEnd <= 0 || sStart >= pageText.length) {
      return Text.rich(TextSpan(text: pageText, style: style));
    }

    final hlStart = sStart.clamp(0, pageText.length);
    final hlEnd = sEnd.clamp(0, pageText.length);

    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: pageText.substring(0, hlStart)),
          TextSpan(
            text: pageText.substring(hlStart, hlEnd),
            style: TextStyle(
              backgroundColor: _einkMode ? Colors.black12 : Colors.amber.withAlpha(90),
              decoration: _einkMode ? TextDecoration.underline : TextDecoration.none,
            ),
          ),
          TextSpan(text: pageText.substring(hlEnd)),
        ],
      ),
    );
  }

  void _showCatalog() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return ListView.builder(
          itemCount: _chapters.length,
          itemBuilder: (context, idx) {
            final ch = _chapters[idx];
            final selected = idx == _chapterIndex;
            return ListTile(
              title: Text(
                ch.title,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                  color: selected ? Colors.blue : null,
                ),
              ),
              trailing: Text(
                '${ch.wordCount} 字',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _chapterIndex = idx;
                  _pageIndex = 0;
                  _showMenu = false;
                  _recomputePagination(
                    _lastContentSize,
                    style: _lastTextStyle,
                    textScaler: _lastTextScaler,
                    targetOffset: 0,
                  );
                });
                _saveProgress();
                _readerFocusNode.requestFocus();
                if (_isTtsActive) {
                  _tts.startReading(chapter: _chapters[idx], startOffset: 0);
                }
              },
            );
          },
        );
      },
    );
  }

  void _showBookmarks() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final bookmarks = Storage.getBookmarks(widget.book.id);
            if (bookmarks.isEmpty) {
              return const Center(child: Text('当前书籍暂无书签'));
            }
            return ListView.builder(
              itemCount: bookmarks.length,
              itemBuilder: (context, idx) {
                final bm = bookmarks[idx];
                return ListTile(
                  leading: const Icon(Icons.bookmark),
                  title: Text(bm.text, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '第 ${bm.chapterIndex + 1} 章 · ${bm.createTime.toString().substring(0, 16)}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.grey),
                    tooltip: '删除书签',
                    onPressed: () async {
                      await Storage.removeBookmark(widget.book.id, bm.id);
                      setSheetState(() {});
                    },
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    setState(() {
                      _chapterIndex = bm.chapterIndex.clamp(0, _chapters.length - 1);
                      _showMenu = false;
                      _recomputePagination(
                        _lastContentSize,
                        style: _lastTextStyle,
                        textScaler: _lastTextScaler,
                        targetOffset: bm.offset,
                      );
                    });
                    _saveProgress();
                    _readerFocusNode.requestFocus();
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
