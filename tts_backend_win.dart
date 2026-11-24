import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

typedef _GetProcessHeapNative = Pointer<Void> Function();
typedef _GetProcessHeapDart = Pointer<Void> Function();

typedef _HeapAllocNative = Pointer<Uint16> Function(Pointer<Void> hHeap, Uint32 dwFlags, IntPtr dwBytes);
typedef _HeapAllocDart = Pointer<Uint16> Function(Pointer<Void> hHeap, int dwFlags, int dwBytes);

typedef _HeapFreeNative = Int32 Function(Pointer<Void> hHeap, Uint32 dwFlags, Pointer<Uint16> lpMem);
typedef _HeapFreeDart = int Function(Pointer<Void> hHeap, int dwFlags, Pointer<Uint16> lpMem);

typedef _MciSendStringWNative = Uint32 Function(
  Pointer<Uint16> lpszCommand,
  Pointer<Uint16> lpszReturnString,
  Uint32 cchReturn,
  Pointer<Void> hwndCallback,
);
typedef _MciSendStringWDart = int Function(
  Pointer<Uint16> lpszCommand,
  Pointer<Uint16> lpszReturnString,
  int cchReturn,
  Pointer<Void> hwndCallback,
);

typedef _MciGetErrorStringWNative = Int32 Function(
  Uint32 fdwError,
  Pointer<Uint16> lpszErrorText,
  Uint32 cchErrorText,
);
typedef _MciGetErrorStringWDart = int Function(
  int fdwError,
  Pointer<Uint16> lpszErrorText,
  int cchErrorText,
);

class TtsPlatformBackend {
  static const String _mciAlias = 'weread_lite_tts';

  _GetProcessHeapDart? _getProcessHeap;
  _HeapAllocDart? _heapAlloc;
  _HeapFreeDart? _heapFree;
  _MciSendStringWDart? _mciSendStringW;
  _MciGetErrorStringWDart? _mciGetErrorStringW;
  bool _ffiReady = false;

  Timer? _pollTimer;
  Process? _sapiProcess;
  int _sessionToken = 0;
  String? _lastPlayerError;

  Future<void> init() async {}

  void _ensureFfi() {
    if (_ffiReady) return;
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final winmm = DynamicLibrary.open('winmm.dll');

    _getProcessHeap = kernel32.lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>('GetProcessHeap');
    _heapAlloc = kernel32.lookupFunction<_HeapAllocNative, _HeapAllocDart>('HeapAlloc');
    _heapFree = kernel32.lookupFunction<_HeapFreeNative, _HeapFreeDart>('HeapFree');
    _mciSendStringW = winmm.lookupFunction<_MciSendStringWNative, _MciSendStringWDart>('mciSendStringW');
    _mciGetErrorStringW =
        winmm.lookupFunction<_MciGetErrorStringWNative, _MciGetErrorStringWDart>('mciGetErrorStringW');
    _ffiReady = true;
  }

  Pointer<Uint16> _toUtf16(String str) {
    final heap = _getProcessHeap!();
    final units = str.codeUnits;
    final ptr = _heapAlloc!(heap, 0x00000008, (units.length + 1) * 2);
    for (int i = 0; i < units.length; i++) {
      ptr[i] = units[i];
    }
    ptr[units.length] = 0;
    return ptr;
  }

  String _fromUtf16(Pointer<Uint16> ptr, int maxChars) {
    final units = <int>[];
    for (int i = 0; i < maxChars; i++) {
      final ch = ptr[i];
      if (ch == 0) break;
      units.add(ch);
    }
    return String.fromCharCodes(units);
  }

  (int code, String output) _mciExec(String command, {bool wantReturn = false}) {
    _ensureFfi();
    final heap = _getProcessHeap!();
    final cmdPtr = _toUtf16(command);
    final retPtr = wantReturn ? _heapAlloc!(heap, 0x00000008, 256 * 2) : nullptr;
    try {
      final code = _mciSendStringW!(cmdPtr, retPtr, wantReturn ? 255 : 0, nullptr);
      final out = wantReturn ? _fromUtf16(retPtr, 255) : '';
      return (code, out);
    } finally {
      _heapFree!(heap, 0, cmdPtr);
      if (wantReturn && retPtr != nullptr) {
        _heapFree!(heap, 0, retPtr);
      }
    }
  }

  String _mciErrorText(int code) {
    if (code == 0) return '';
    _ensureFfi();
    final heap = _getProcessHeap!();
    final buf = _heapAlloc!(heap, 0x00000008, 256 * 2);
    try {
      final ok = _mciGetErrorStringW!(code, buf, 255);
      if (ok != 0) {
        final msg = _fromUtf16(buf, 255).trim();
        if (msg.isNotEmpty) return '$msg (code=$code)';
      }
      return 'MCI error code=$code';
    } finally {
      _heapFree!(heap, 0, buf);
    }
  }

  Future<void> configureSystemTts({required double speed, required double pitch}) async {}

  Future<void> speakSystemText({
    required String text,
    required String lang,
    required double speed,
    required double pitch,
    required void Function() onComplete,
    required void Function(String err) onError,
  }) async {
    await stopAll();
    final token = ++_sessionToken;

    final rate = ((speed - 1.0) * 6.0).round().clamp(-10, 10);
    final textB64 = base64Encode(utf8.encode(text));

    final psScript = '''
\$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Speech
\$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
\$synth.Rate = $rate
\$txt = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('$textB64'))
\$synth.Speak(\$txt)
\$synth.Dispose()
''';

    try {
      final proc = await Process.start(
        'powershell',
        ['-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-Command', psScript],
        runInShell: false,
      );
      if (token != _sessionToken) {
        proc.kill();
        return;
      }
      _sapiProcess = proc;

      final stderrFuture = utf8.decoder.bind(proc.stderr).join();
      final exitCode = await proc.exitCode;
      if (token != _sessionToken) return;
      _sapiProcess = null;

      if (exitCode == 0) {
        onComplete();
      } else {
        final errOut = (await stderrFuture).trim();
        onError(errOut.isNotEmpty ? errOut : 'Windows SAPI 退出码 $exitCode');
      }
    } catch (e) {
      if (token == _sessionToken) {
        onError('系统语音启动失败: $e');
      }
    }
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
    await stopAll();
    final token = ++_sessionToken;
    _lastPlayerError = null;

    if (!File(filePath).existsSync()) {
      await File(filePath).writeAsBytes(bytes, flush: true);
    }

    _mciExec('close $_mciAlias');

    var openRes = _mciExec('open "$filePath" alias $_mciAlias');
    if (openRes.$1 != 0) {
      openRes = _mciExec('open "$filePath" type mpegvideo alias $_mciAlias');
    }
    if (openRes.$1 != 0) {
      final err = _mciErrorText(openRes.$1);
      _lastPlayerError = err;
      throw Exception('Windows 音频打开失败: $err');
    }

    final playRes = _mciExec('play $_mciAlias');
    if (playRes.$1 != 0) {
      final err = _mciErrorText(playRes.$1);
      _mciExec('close $_mciAlias');
      _lastPlayerError = err;
      throw Exception('Windows 音频播放失败: $err');
    }

    if (token != _sessionToken) {
      _mciExec('close $_mciAlias');
      return;
    }

    _pollTimer = Timer.periodic(const Duration(milliseconds: 180), (timer) {
      if (token != _sessionToken) {
        timer.cancel();
        return;
      }
      final st = _mciExec('status $_mciAlias mode', wantReturn: true);
      final mode = st.$2.trim().toLowerCase();
      if (st.$1 != 0 || mode == 'stopped' || mode.isEmpty) {
        timer.cancel();
        _mciExec('close $_mciAlias');
        if (token == _sessionToken) {
          onComplete();
        }
      }
    });
  }

  String? consumeLastPlayerError() {
    final err = _lastPlayerError;
    _lastPlayerError = null;
    return err;
  }

  Future<void> stopAll() async {
    _sessionToken++;
    _pollTimer?.cancel();
    _pollTimer = null;

    if (_sapiProcess != null) {
      try {
        _sapiProcess!.kill();
      } catch (_) {}
      _sapiProcess = null;
    }

    if (_ffiReady) {
      try {
        _mciExec('stop $_mciAlias');
        _mciExec('close $_mciAlias');
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await stopAll();
  }
}
