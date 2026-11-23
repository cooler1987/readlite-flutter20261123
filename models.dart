import 'dart:convert';

enum TtsEngineType { system, fishAudio, customHttp }

class TtsEngineConfig {
  final String id;
  final String name;
  final TtsEngineType type;
  final String apiEndpoint;
  final String apiKey;
  final String voiceId;
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
    'speed': speed,
    'pitch': pitch,
    'customHeaders': customHeaders,
    'customBodyTemplate': customBodyTemplate,
  };

  factory TtsEngineConfig.fromJson(Map<String, dynamic> json) => TtsEngineConfig(
    id: json['id'] ?? '',
    name: json['name'] ?? '默认引擎',
    type: TtsEngineType.values.firstWhere(
      (e) => e.name == json['type'],
      orElse: () => TtsEngineType.system,
    ),
    apiEndpoint: json['apiEndpoint'] ?? 'https://api.fish.audio/v1/tts',
    apiKey: json['apiKey'] ?? '',
    voiceId: json['voiceId'] ?? '',
    speed: (json['speed'] as num?)?.toDouble() ?? 1.0,
    pitch: (json['pitch'] as num?)?.toDouble() ?? 1.0,
    customHeaders: Map<String, String>.from(json['customHeaders'] ?? {}),
    customBodyTemplate: json['customBodyTemplate'] ?? '',
  );

  TtsEngineConfig copyWith({
    String? name,
    TtsEngineType? type,
    String? apiEndpoint,
    String? apiKey,
    String? voiceId,
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
