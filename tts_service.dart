import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;
import 'models.dart';
import 'pager_engine.dart';

class TtsService {
  static final TtsService _instance = TtsService._internal();
  factory TtsService() => _instance;
  TtsService._internal();

  final FlutterTts _flutterTts = FlutterTts();
  final AudioPlayer _audioPlayer = AudioPlayer();

  TtsEngineConfig _config = TtsEngineConfig(id: 'system', name: '系统原生 TTS');
  List<TtsSentence> _queue = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  bool _isPaused = false;
  bool _initialized = false;
  int _requestToken = 0; // 用于丢弃过期的异步网络回调

  // 跨章回调：当整章读完时通知外部切到下一章
  VoidCallback? onChapterComplete;

  bool get isPlaying => _isPlaying;
  bool get isPaused => _isPaused;
  TtsSentence? get currentSentence =>
      (_queue.isNotEmpty && _currentIndex < _queue.length) ? _queue[_currentIndex] : null;

  final StreamController<TtsSentence> _sentenceController =
      StreamController<TtsSentence>.broadcast();
  Stream<TtsSentence> get onSentenceChange => _sentenceController.stream;

  final StreamController<bool> _stateController =
      StreamController<bool>.broadcast();
  Stream<bool> get onPlayStateChange => _stateController.stream;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // 系统 TTS 播放完成监听 (防重入)
    _flutterTts.setCompletionHandler(() {
      if (_isPlaying && !_isPaused) {
        _playNext();
      }
    });

    // 网络音频播放完成监听 (防重入)
    _audioPlayer.onPlayerComplete.listen((_) {
      if (_isPlaying && !_isPaused) {
        _playNext();
      }
    });
  }

  void updateConfig(TtsEngineConfig config) {
    _config = config;
    _flutterTts.setSpeechRate((config.speed * 0.5).clamp(0.0, 1.0));
    _flutterTts.setPitch(config.pitch.clamp(0.5, 2.0));
    _audioPlayer.setPlaybackRate(config.speed.clamp(0.5, 2.5));
  }

  /// 从指定偏移量开始朗读整个章节
  Future<void> startReading({
    required Chapter chapter,
    required int startOffset,
  }) async {
    await stop();

    final matches = PageEngine.splitSentences(chapter.content);
    _queue = matches.map((m) {
      return TtsSentence(
        text: m.group(0)!.trim(),
        chapterIndex: chapter.index,
        startOffset: m.start,
        endOffset: m.end,
      );
    }).where((s) => s.text.isNotEmpty).toList();

    if (_queue.isEmpty) return;

    // 找到包含当前偏移量的句子
    _currentIndex = 0;
    for (int i = 0; i < _queue.length; i++) {
      if (startOffset >= _queue[i].startOffset && startOffset <= _queue[i].endOffset) {
        _currentIndex = i;
        break;
      }
    }

    _isPlaying = true;
    _isPaused = false;
    _stateController.add(true);
    _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    final token = ++_requestToken;

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
        await _flutterTts.setLanguage("zh-CN");
        await _flutterTts.setSpeechRate((_config.speed * 0.5).clamp(0.0, 1.0));
        await _flutterTts.setPitch(_config.pitch.clamp(0.5, 2.0));
        if (token == _requestToken && _isPlaying && !_isPaused) {
          await _flutterTts.speak(sentence.text);
        }
      } else if (_config.type == TtsEngineType.fishAudio) {
        await _callFishAudio(sentence.text, token);
      } else if (_config.type == TtsEngineType.customHttp) {
        await _callCustomHttp(sentence.text, token);
      }
    } catch (e) {
      debugPrint("TTS 朗读出错: $e");
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (token == _requestToken && _isPlaying && !_isPaused) {
          _playNext();
        }
      });
    }
  }

  /// 调用 Fish.Audio API (带 Token 校验防混音)
  Future<void> _callFishAudio(String text, int token) async {
    final endpoint = _config.apiEndpoint.isNotEmpty
        ? _config.apiEndpoint
        : 'https://api.fish.audio/v1/tts';

    final headers = {
      'Content-Type': 'application/json',
      if (_config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${_config.apiKey}',
      ..._config.customHeaders,
    };

    final body = jsonEncode({
      'text': text,
      if (_config.voiceId.isNotEmpty) 'reference_id': _config.voiceId,
      'format': 'mp3',
    });

    final resp = await http
        .post(Uri.parse(endpoint), headers: headers, body: body)
        .timeout(const Duration(seconds: 15));

    if (token != _requestToken || !_isPlaying || _isPaused) return;

    if (resp.statusCode == 200) {
      await _audioPlayer.setPlaybackRate(_config.speed.clamp(0.5, 2.5));
      await _audioPlayer.play(BytesSource(resp.bodyBytes));
    } else {
      throw Exception("Fish.Audio 返回错误: ${resp.statusCode} ${resp.body}");
    }
  }

  /// 调用自定义 HTTP / OpenAI 兼容接口 (安全 JSON 转义防崩溃)
  Future<void> _callCustomHttp(String text, int token) async {
    // 对 text 做标准 JSON 内部转义，防止破坏模板结构
    final jsonEscaped = jsonEncode(text);
    final safeText = jsonEscaped.substring(1, jsonEscaped.length - 1);

    String url = _config.apiEndpoint
        .replaceAll('{text}', Uri.encodeComponent(text))
        .replaceAll('{voice_id}', _config.voiceId)
        .replaceAll('{api_key}', _config.apiKey);

    final headers = Map<String, String>.from(_config.customHeaders);
    if (_config.apiKey.isNotEmpty && !headers.containsKey('Authorization')) {
      headers['Authorization'] = 'Bearer ${_config.apiKey}';
    }

    String bodyStr = _config.customBodyTemplate
        .replaceAll('{text}', safeText)
        .replaceAll('{voice_id}', _config.voiceId)
        .replaceAll('{api_key}', _config.apiKey);

    http.Response resp;
    if (bodyStr.trim().isNotEmpty) {
      headers['Content-Type'] ??= 'application/json';
      resp = await http
          .post(Uri.parse(url), headers: headers, body: bodyStr)
          .timeout(const Duration(seconds: 15));
    } else {
      resp = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));
    }

    if (token != _requestToken || !_isPlaying || _isPaused) return;

    if (resp.statusCode == 200) {
      await _audioPlayer.setPlaybackRate(_config.speed.clamp(0.5, 2.5));
      await _audioPlayer.play(BytesSource(resp.bodyBytes));
    } else {
      throw Exception("自定义 TTS 接口错误: ${resp.statusCode}");
    }
  }

  void _playNext() {
    if (!_isPlaying || _isPaused) return;
    _currentIndex++;
    _speakCurrent();
  }

  Future<void> nextSentence() async {
    if (!_isPlaying) return;
    await _stopMedia();
    _currentIndex++;
    _speakCurrent();
  }

  Future<void> prevSentence() async {
    if (!_isPlaying) return;
    await _stopMedia();
    _currentIndex = (_currentIndex > 0) ? _currentIndex - 1 : 0;
    _speakCurrent();
  }

  Future<void> pause() async {
    _isPaused = true;
    _stateController.add(false);
    await _stopMedia();
  }

  Future<void> resume() async {
    _isPaused = false;
    _stateController.add(true);
    _speakCurrent();
  }

  Future<void> stop() async {
    _isPlaying = false;
    _isPaused = false;
    _requestToken++;
    _stateController.add(false);
    await _stopMedia();
  }

  Future<void> _stopMedia() async {
    await _flutterTts.stop();
    await _audioPlayer.stop();
  }
}
