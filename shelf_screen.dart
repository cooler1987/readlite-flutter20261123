import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'models.dart';
import 'storage.dart';
import 'tts_service.dart';
import 'reader_screen.dart';

class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key});

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  List<Book> _books = [];
  bool _einkMode = false;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    await Storage.init();
    final books = Storage.getBooks();
    final eink = Storage.getEinkMode();
    final currentTts = Storage.getActiveTtsEngine();
    TtsService().updateConfig(currentTts);
    setState(() {
      _books = books;
      _einkMode = eink;
    });
  }

  /// 导入书籍并持久化拷贝到私有文档目录（彻底避免 Android/iOS 缓存被清理导致文件丢失）
  Future<void> _importBook() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub'],
    );

    if (result != null && result.files.single.path != null) {
      final srcPath = result.files.single.path!;
      final filename = result.files.single.name;
      final format = filename.toLowerCase().endsWith('.epub') ? 'epub' : 'txt';
      final title = filename.replaceAll(RegExp(r'\.(txt|epub)$', caseSensitive: false), '');

      // 持久化存储至 App Documents/books 目录
      final appDir = await getApplicationDocumentsDirectory();
      final booksDir = Directory('${appDir.path}/books');
      if (!await booksDir.exists()) {
        await booksDir.create(recursive: true);
      }

      final targetPath = '${booksDir.path}/${DateTime.now().millisecondsSinceEpoch}_$filename';
      await File(srcPath).copy(targetPath);

      final newBook = Book(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        author: '本地导入',
        filePath: targetPath,
        format: format,
      );

      await Storage.saveBook(newBook);
      _loadData();
    }
  }

  void _showTtsSettingsDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
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
        title: Text('本地书架 (Dual Lite)', style: TextStyle(color: textColor)),
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
              setState(() => _einkMode = next);
            },
          ),
          IconButton(
            icon: const Icon(Icons.record_voice_over),
            tooltip: 'TTS 引擎设置 (含 Fish.Audio)',
            onPressed: _showTtsSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '导入本地图书 (TXT/EPUB)',
            onPressed: _importBook,
          ),
        ],
      ),
      body: _books.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.menu_book, size: 64, color: _einkMode ? Colors.black54 : Colors.grey),
                  const SizedBox(height: 16),
                  Text('书架暂无图书', style: TextStyle(fontSize: 18, color: textColor ?? Colors.grey)),
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.file_open),
                    label: const Text('导入 TXT 或 EPUB 文件'),
                    onPressed: _importBook,
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _books.length,
              separatorBuilder: (_, __) => Divider(height: 1, color: _einkMode ? Colors.black26 : null),
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
                    style: TextStyle(color: _einkMode ? Colors.black87 : Colors.grey.shade600),
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
                        content: const Text('将从书架移除，并清理本地私有存储副本。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                          ElevatedButton(
                            onPressed: () async {
                              final f = File(book.filePath);
                              if (await f.exists()) {
                                try { await f.delete(); } catch (_) {}
                              }
                              await Storage.removeBook(book.id);
                              Navigator.pop(ctx);
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

/// 独立的 TTS 配置对话框组件（规范管理 TextEditingController 生命周期）
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
  late TextEditingController _endpointCtrl;
  late TextEditingController _bodyTemplateCtrl;

  @override
  void initState() {
    super.initState();
    _engines = Storage.getTtsEngines();
    _current = Storage.getActiveTtsEngine();
    _initControllers();
  }

  void _initControllers() {
    _nameCtrl = TextEditingController(text: _current.name);
    _apiKeyCtrl = TextEditingController(text: _current.apiKey);
    _voiceIdCtrl = TextEditingController(text: _current.voiceId);
    _endpointCtrl = TextEditingController(text: _current.apiEndpoint);
    _bodyTemplateCtrl = TextEditingController(text: _current.customBodyTemplate);
  }

  void _updateControllers() {
    _nameCtrl.text = _current.name;
    _apiKeyCtrl.text = _current.apiKey;
    _voiceIdCtrl.text = _current.voiceId;
    _endpointCtrl.text = _current.apiEndpoint;
    _bodyTemplateCtrl.text = _current.customBodyTemplate;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _apiKeyCtrl.dispose();
    _voiceIdCtrl.dispose();
    _endpointCtrl.dispose();
    _bodyTemplateCtrl.dispose();
    super.dispose();
  }

  void _syncCurrentFromControllers() {
    _current = _current.copyWith(
      name: _nameCtrl.text,
      apiKey: _apiKeyCtrl.text,
      voiceId: _voiceIdCtrl.text,
      apiEndpoint: _endpointCtrl.text,
      customBodyTemplate: _bodyTemplateCtrl.text,
    );
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
                      items: _engines.map((e) {
                        return DropdownMenuItem(value: e.id, child: Text(e.name));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          _syncCurrentFromControllers();
                          final idx = _engines.indexWhere((e) => e.id == _current.id);
                          if (idx >= 0) _engines[idx] = _current;

                          setState(() {
                            _current = _engines.firstWhere((e) => e.id == val);
                            _updateControllers();
                          });
                        }
                      },
                    ),
                  ),
                  if (_current.type != TtsEngineType.system && _engines.length > 1)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      tooltip: '删除此自定义引擎',
                      onPressed: () {
                        setState(() {
                          _engines.removeWhere((e) => e.id == _current.id);
                          _current = _engines.first;
                          _updateControllers();
                        });
                      },
                    ),
                ],
              ),
              const Divider(height: 24),
              TextField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: '引擎显示名称', border: OutlineInputBorder()),
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
                    labelText: 'Reference ID (声音模型ID)',
                    hintText: '留空使用官方推荐声音，也可输入音色ID',
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
                const Text('自定义通用 HTTP / OpenAI TTS', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: _endpointCtrl,
                  decoration: const InputDecoration(
                    labelText: '接口完整地址 (支持 {text}, {voice_id})',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _apiKeyCtrl,
                  decoration: const InputDecoration(
                    labelText: 'API Key / Bearer Token (可选)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _voiceIdCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Voice 模型名称 / ID (可选)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _bodyTemplateCtrl,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'POST JSON 模板 (留空走 GET 请求)',
                    hintText: '{"model":"tts-1","input":"{text}"}',
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
                  const Text('语速调节：'),
                  Expanded(
                    child: Slider(
                      value: _current.speed,
                      min: 0.5,
                      max: 2.0,
                      divisions: 15,
                      label: '${_current.speed.toStringAsFixed(1)}x',
                      onChanged: (v) => setState(() => _current = _current.copyWith(speed: v)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            _syncCurrentFromControllers();
            final newEng = TtsEngineConfig(
              id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
              name: '自定义引擎 ${_engines.length + 1}',
              type: TtsEngineType.customHttp,
            );
            setState(() {
              _engines.add(newEng);
              _current = newEng;
              _updateControllers();
            });
          },
          child: const Text('新增自定义引擎'),
        ),
        ElevatedButton(
          onPressed: () async {
            _syncCurrentFromControllers();
            final idx = _engines.indexWhere((e) => e.id == _current.id);
            if (idx >= 0) _engines[idx] = _current;

            await Storage.saveTtsEngines(_engines);
            await Storage.setActiveTtsEngine(_current.id);
            TtsService().updateConfig(_current);
            if (mounted) Navigator.pop(context);
          },
          child: const Text('保存生效'),
        ),
      ],
    );
  }
}
