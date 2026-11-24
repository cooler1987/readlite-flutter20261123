import 'dart:async';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsPlatformBackend {
  FlutterTts? _flutterTts;
  AudioPlayer? _audioPlayer;
  bool _systemTtsReady = false;
  bool _audioPlayerReady = false;
  String _lastLang = '';
  String? _lastPlayerLogError;

  void Function()? _currentSystemComplete;
  void Function(String err)? _currentSystemError;
  void Function()? _currentAudioComplete;
  void Function(String err)? _currentAudioError;

  Future<void> init() async {}

  Future<FlutterTts> _ensureSystemTts(double speed, double pitch) async {
    final tts = _flutterTts ??= FlutterTts();
    if (!_systemTtsReady) {
      _systemTtsReady = true;
      tts.setCompletionHandler(() {
        _currentSystemComplete?.call();
      });
      tts.setErrorHandler((msg) {
        _currentSystemError?.call('系统语音报错: $msg');
      });
      try {
        await tts.awaitSpeakCompletion(false);
      } catch (_) {}
      try {
        await tts.setSpeechRate((speed * 0.5).clamp(0.0, 1.0));
        await tts.setPitch(pitch.clamp(0.5, 2.0));
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
        _currentAudioComplete?.call();
      });
      player.onLog.listen((logMsg) {
        final lower = logMsg.toLowerCase();
        if (lower.contains('error') || lower.contains('exception') || lower.contains('failed')) {
          _lastPlayerLogError = logMsg;
          debugPrint('AudioPlayer log error: $logMsg');
          _currentAudioError?.call('音频播放异常: $logMsg');
        }
      });
    }
    return player;
  }

  Future<void> configureSystemTts({required double speed, required double pitch}) async {
    if (_flutterTts != null) {
      try {
        await _flutterTts!.setSpeechRate((speed * 0.5).clamp(0.0, 1.0));
        await _flutterTts!.setPitch(pitch.clamp(0.5, 2.0));
      } catch (_) {}
    }
  }

  Future<void> speakSystemText({
    required String text,
    required String lang,
    required double speed,
    required double pitch,
    required void Function() onComplete,
    required void Function(String err) onError,
  }) async {
    _currentSystemComplete = onComplete;
    _currentSystemError = onError;
    final tts = await _ensureSystemTts(speed, pitch);
    if (_lastLang != lang) {
      _lastLang = lang;
      await tts.setLanguage(lang);
    }
    await tts.speak(text);
  }

  Future<void> playAudioFile({
    required String filePath,
    required Uint8List bytes,
    required String mimeType,
    required double speed,
    required bool serverAppliedSpeed,
    required void Function() onComplete,
    required void Function(String err) onError,
  }) async {
    _currentAudioComplete = onComplete;
    _currentAudioError = onError;
    final player = _ensureAudioPlayer();
    _lastPlayerLogError = null;

    try {
      await player.stop();
    } catch (_) {}

    bool played = false;
    try {
      await player.play(DeviceFileSource(filePath));
      played = true;
    } catch (_) {}

    if (!played) {
      await player.play(BytesSource(bytes, mimeType: mimeType));
    }

    if (!serverAppliedSpeed && (speed - 1.0).abs() >= 0.05) {
      try {
        await player.setPlaybackRate(speed.clamp(0.5, 2.5));
      } catch (_) {}
    }
  }

  String? consumeLastPlayerError() {
    final err = _lastPlayerLogError;
    _lastPlayerLogError = null;
    return err;
  }

  Future<void> stopAll() async {
    _currentSystemComplete = null;
    _currentSystemError = null;
    _currentAudioComplete = null;
    _currentAudioError = null;
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

  Future<void> dispose() async {
    await stopAll();
  }
}
