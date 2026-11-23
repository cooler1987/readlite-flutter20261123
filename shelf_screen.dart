import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
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

  Future<void> _importBook() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'epub'],
    );

    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final filename = result.files.single.name;
      final format = filename.endsWith('.epub') ? 'epub' : 'txt';
      final title = filename.replaceAll(RegExp(r'\.(txt|epub)$', caseSensitive: false), '');

      final newBook = Book(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        author: '本地导入',
        filePath: file.path,
        format: format,
      );

      await Storage.saveBook(newBook);
      _loadData();
    }
  }

  void _showTtsSettingsDialog() {
    final engines = Storage.getTtsEngines();
    TtsEngineConfig current = Storage.getActiveTtsEngine();

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('TTS 朗读引擎配置'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('选择当前引擎：', style: TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    DropdownButton<String>(
                      isExpanded: true,
                      value: current.id,
                      items: engines.map((e) {
                        return DropdownMenuItem(value: e.id, child: Text(e.name));
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setDialogState(() {
                            current = engines.firstWhere((e) => e.id == val);
                          });
                        }
                      },
                    ),
                    const Divider(height: 24),
                    if (current.type == TtsEngineType.fishAudio) ...[
                      const Text('Fish.Audio 参数设置', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: TextEditingController(text: current.apiKey),
                        decoration: const InputDecoration(
                          labelText: 'API Key (密钥)',
                          hintText: '填入你的 Fish.Audio Token',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => current = current.copyWith(apiKey: v),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: TextEditingController(text: current.voiceId),
                        decoration: const InputDecoration(
                          labelText: 'Reference ID (声音模型ID)',
                          hintText: '可选，默认使用系统推荐音色',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => current = current.copyWith(voiceId: v),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: TextEditingController(text: current.apiEndpoint),
                        decoration: const InputDecoration(
                          labelText: 'API 地址',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => current = current.copyWith(apiEndpoint: v),
                      ),
                    ] else if (current.type == TtsEngineType.customHttp) ...[
                      const Text('自定义 HTTP / OpenAI TTS', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      TextField(
                        controller: TextEditingController(text: current.apiEndpoint),
                        decoration: const InputDecoration(
                          labelText: '接口地址 (支持 {text}, {voice_id})',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => current = current.copyWith(apiEndpoint: v),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: TextEditingController(text: current.apiKey),
                        decoration: const InputDecoration(
                          labelText: 'Bearer Token (可选)',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => current = current.copyWith(apiKey: v),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: TextEditingController(text: current.customBodyTemplate),
                        maxLines: 3,
                        decoration: const InputDecoration(
                          labelText: 'POST JSON 模板 (留空走 GET)',
                          hintText: '{"model":"tts-1","input":"{text}"}',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (v) => current = current.copyWith(customBodyTemplate: v),
                      ),
                    ] else ...[
                      const Text('已选用本地系统原生 TTS 引擎，离线可用，无需联网。'),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    // 新建自定义引擎
                    final newEng = TtsEngineConfig(
                      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
                      name: '自定义引擎 ${engines.length + 1}',
                      type: TtsEngineType.customHttp,
                    );
                    engines.add(newEng);
                    setDialogState(() {
                      current = newEng;
                    });
                  },
                  child: const Text('新增自定义'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final idx = engines.indexWhere((e) => e.id == current.id);
                    if (idx >= 0) engines[idx] = current;
                    await Storage.saveTtsEngines(engines);
                    await Storage.setActiveTtsEngine(current.id);
                    TtsService().updateConfig(current);
                    if (mounted) Navigator.pop(ctx);
                  },
                  child: const Text('保存生效'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('本地书架 (Lite)'),
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
            tooltip: 'TTS 引擎设置',
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
                mainAxisAlignment: MainTestAxisAlignment.center,
                children: [
                  const Icon(Icons.menu_book, size: 64, color: Colors.grey),
                  const SizedBox(height: 16),
                  const Text('书架暂无图书', style: TextStyle(fontSize: 18, color: Colors.grey)),
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
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final book = _books[index];
                return ListTile(
                  leading: Container(
                    width: 44,
                    height: 56,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black54),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      book.format.toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                  ),
                  title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    '读至第 ${book.currentChapterIndex + 1} 章 · 进度 ${(book.progress * 100).toStringAsFixed(1)}%',
                  ),
                  trailing: const Icon(Icons.chevron_right),
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
                        content: const Text('仅从书架移除记录，不会删除手机原始文件。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
                          ElevatedButton(
                            onPressed: () async {
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
