import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class Storage {
  static const String _keyBooks = 'weread_lite_books';
  static const String _keyBookmarks = 'weread_lite_bookmarks';
  static const String _keyTtsEngines = 'weread_lite_tts_engines';
  static const String _keyCurrentTtsId = 'weread_lite_current_tts_id';
  static const String _keyFontSize = 'weread_lite_font_size';
  static const String _keyLineHeight = 'weread_lite_line_height';
  static const String _keyMargin = 'weread_lite_margin';
  static const String _keyEinkMode = 'weread_lite_eink_mode';

  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  // ---------- 书籍管理 ----------

  static List<Book> getBooks() {
    final raw = _prefs?.getString(_keyBooks);
    if (raw == null || raw.isEmpty) return [];
    try {
      final List list = jsonDecode(raw);
      return list.map((e) => Book.fromJson(e)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveBooks(List<Book> books) async {
    final raw = jsonEncode(books.map((e) => e.toJson()).toList());
    await _prefs?.setString(_keyBooks, raw);
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
  }

  // ---------- 书签管理 ----------

  static List<Bookmark> getBookmarks(String bookId) {
    final raw = _prefs?.getString('${_keyBookmarks}_$bookId');
    if (raw == null || raw.isEmpty) return [];
    try {
      final List list = jsonDecode(raw);
      return list.map((e) => Bookmark.fromJson(e)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> addBookmark(Bookmark bookmark) async {
    final list = getBookmarks(bookmark.bookId)..add(bookmark);
    await _prefs?.setString(
      '${_keyBookmarks}_${bookmark.bookId}',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> removeBookmark(String bookId, String bookmarkId) async {
    final list = getBookmarks(bookId)..removeWhere((b) => b.id == bookmarkId);
    await _prefs?.setString(
      '${_keyBookmarks}_$bookId',
      jsonEncode(list.map((e) => e.toJson()).toList()),
    );
  }

  // ---------- TTS 引擎配置 ----------

  static List<TtsEngineConfig> _defaultTtsEngines() => [
    TtsEngineConfig(
      id: 'system',
      name: '系统原生 TTS',
      type: TtsEngineType.system,
    ),
    TtsEngineConfig(
      id: 'fish_audio',
      name: 'Fish.Audio 免费/API引擎',
      type: TtsEngineType.fishAudio,
      apiEndpoint: 'https://api.fish.audio/v1/tts',
      apiKey: '',
      voiceId: '',
    ),
  ];

  static List<TtsEngineConfig> getTtsEngines() {
    final raw = _prefs?.getString(_keyTtsEngines);
    if (raw == null || raw.isEmpty) {
      return _defaultTtsEngines();
    }
    try {
      final List list = jsonDecode(raw);
      final res = list.map((e) => TtsEngineConfig.fromJson(e)).toList();
      return res.isEmpty ? _defaultTtsEngines() : res;
    } catch (_) {
      return _defaultTtsEngines();
    }
  }

  static Future<void> saveTtsEngines(List<TtsEngineConfig> engines) async {
    final raw = jsonEncode(engines.map((e) => e.toJson()).toList());
    await _prefs?.setString(_keyTtsEngines, raw);
  }

  static TtsEngineConfig getActiveTtsEngine() {
    final engines = getTtsEngines();
    final currentId = _prefs?.getString(_keyCurrentTtsId);
    if (currentId != null) {
      final found = engines.where((e) => e.id == currentId);
      if (found.isNotEmpty) return found.first;
    }
    return engines.isNotEmpty ? engines.first : _defaultTtsEngines().first;
  }

  static Future<void> setActiveTtsEngine(String engineId) async {
    await _prefs?.setString(_keyCurrentTtsId, engineId);
  }

  // ---------- 阅读排版配置 ----------

  static double getFontSize() => _prefs?.getDouble(_keyFontSize) ?? 20.0;
  static Future<void> setFontSize(double size) =>
      _prefs?.setDouble(_keyFontSize, size) ?? Future.value();

  static double getLineHeight() => _prefs?.getDouble(_keyLineHeight) ?? 1.6;
  static Future<void> setLineHeight(double height) =>
      _prefs?.setDouble(_keyLineHeight, height) ?? Future.value();

  static double getMargin() => _prefs?.getDouble(_keyMargin) ?? 16.0;
  static Future<void> setMargin(double margin) =>
      _prefs?.setDouble(_keyMargin, margin) ?? Future.value();

  static bool getEinkMode() => _prefs?.getBool(_keyEinkMode) ?? false;
  static Future<void> setEinkMode(bool val) =>
      _prefs?.setBool(_keyEinkMode, val) ?? Future.value();
}
