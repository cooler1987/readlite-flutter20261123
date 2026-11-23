import 'dart:async';
import 'package:flutter/material.dart';
import 'models.dart';
import 'storage.dart';
import 'book_parser.dart';
import 'pager_engine.dart';
import 'tts_service.dart';

class ReaderScreen extends StatefulWidget {
  final Book book;
  const ReaderScreen({super.key, required this.book});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  List<Chapter> _chapters = [];
  bool _loading = true;
  String _error = '';

  int _chapterIndex = 0;
  int _pageIndex = 0;
  List<int> _pageStarts = [0];

  double _fontSize = 20.0;
  double _lineHeight = 1.6;
  double _margin = 16.0;
  bool _einkMode = false;
  bool _showMenu = false;

  // TTS 状态同步
  final TtsService _tts = TtsService();
  bool _isTtsActive = false;
  TtsSentence? _currentTtsSentence;
  StreamSubscription? _ttsSub;
  StreamSubscription? _ttsStateSub;

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
    _tts.init();
    _ttsSub = _tts.onSentenceChange.listen((sentence) {
      if (!mounted) return;
      setState(() {
        _currentTtsSentence = sentence;
      });
      // 检查当前句子是否需要跨章或跨页联动
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

    _ttsStateSub = _tts.onPlayStateChange.listen((playing) {
      if (!mounted) return;
      setState(() {
        _isTtsActive = _tts.isPlaying;
      });
    });
  }

  @override
  void dispose() {
    _ttsSub?.cancel();
    _ttsStateSub?.cancel();
    _tts.stop();
    super.dispose();
  }

  Future<void> _loadBook() async {
    try {
      final chapters = await BookParser.parse(widget.book.filePath, widget.book.format);
      if (chapters.isEmpty) throw Exception('书籍内容为空');
      setState(() {
        _chapters = chapters;
        _chapterIndex = _chapterIndex.clamp(0, chapters.length - 1);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _repaginate(Size size) {
    if (_chapters.isEmpty) return;
    final currentOffset = (_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : 0;
    final chapter = _chapters[_chapterIndex];

    final contentArea = Size(
      size.width - _margin * 2,
      size.height - _margin * 2 - 60, // 预留上下页眉页脚
    );

    final starts = PageEngine.paginate(
      text: chapter.content,
      fontSize: _fontSize,
      lineHeight: _lineHeight,
      contentAreaSize: contentArea,
    );

    _pageStarts = starts;
    _pageIndex = PageEngine.findPageIndexForOffset(starts, currentOffset);
  }

  void _saveProgress() {
    if (_chapters.isEmpty) return;
    final currentOffset = (_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : 0;
    widget.book.currentChapterIndex = _chapterIndex;
    widget.book.currentOffset = currentOffset;
    widget.book.progress = (_chapters.length > 1) ? (_chapterIndex / (_chapters.length - 1)) : 1.0;
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
        _pageIndex = 0; // 跳转至上一章
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
        _pageIndex = 0; // 下一章第一页
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

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error.isNotEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('加载失败')),
        body: Center(child: Text(_error, style: const TextStyle(color: Colors.red))),
      );
    }

    final media = MediaQuery.of(context);
    _repaginate(media.size);

    final chapter = _chapters[_chapterIndex];
    final pageStart = (_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : 0;
    final pageEnd = (_pageIndex + 1 < _pageStarts.length)
        ? _pageStarts[_pageIndex + 1]
        : chapter.content.length;
    final pageText = chapter.content.substring(pageStart, pageEnd);

    // 墨水屏配色控制
    final bgColor = _einkMode ? Colors.white : Theme.of(context).scaffoldBackgroundColor;
    final textColor = _einkMode ? Colors.black : Theme.of(context).textTheme.bodyMedium?.color;

    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Stack(
          children: [
            // 正文绘制及点击热区
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
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                        ),
                      ),
                      Text('${_chapterIndex + 1}/${_chapters.length} 章',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
                // 页面正文
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: _margin),
                    child: _buildPageContent(pageText, pageStart, textColor),
                  ),
                ),
                // 页脚
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: _margin, vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(widget.book.title, style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                      Text('${_pageIndex + 1}/${_pageStarts.length} 页',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                    ],
                  ),
                ),
              ],
            ),

            // 三等分触控区 (左30% 上一页，中40% 菜单，右30% 下一页)
            Row(
              children: [
                Expanded(flex: 3, child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _prevPage)),
                Expanded(
                  flex: 4,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () => setState(() => _showMenu = !_showMenu),
                  ),
                ),
                Expanded(flex: 3, child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _nextPage)),
              ],
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
                    title: Text(widget.book.title),
                    actions: [
                      IconButton(
                        icon: const Icon(Icons.list),
                        tooltip: '目录',
                        onPressed: _showCatalog,
                      ),
                    ],
                  ),
                ),
              ),

            // 底部设置栏
            if (_showMenu)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  color: Colors.black87,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove, color: Colors.white),
                        tooltip: '缩小字号',
                        onPressed: () {
                          setState(() => _fontSize = (_fontSize - 2).clamp(14.0, 36.0));
                          Storage.setFontSize(_fontSize);
                        },
                      ),
                      Text('${_fontSize.toInt()}sp', style: const TextStyle(color: Colors.white)),
                      IconButton(
                        icon: const Icon(Icons.add, color: Colors.white),
                        tooltip: '放大字号',
                        onPressed: () {
                          setState(() => _fontSize = (_fontSize + 2).clamp(14.0, 36.0));
                          Storage.setFontSize(_fontSize);
                        },
                      ),
                      IconButton(
                        icon: Icon(_isTtsActive ? Icons.volume_up : Icons.volume_off, color: Colors.white),
                        tooltip: '朗读听书',
                        onPressed: _toggleTts,
                      ),
                    ],
                  ),
                ),
              ),

            // TTS 朗读悬浮控制胶囊
            if (_isTtsActive)
              Positioned(
                bottom: _showMenu ? 70 : 20,
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
                          icon: Icon(Icons.skip_previous, color: _einkMode ? Colors.black : Colors.white),
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
                          icon: Icon(Icons.skip_next, color: _einkMode ? Colors.black : Colors.white),
                          onPressed: () => _tts.nextSentence(),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, color: _einkMode ? Colors.black : Colors.white),
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
    );
  }

  /// 构建带朗读高亮跟随的正文
  Widget _buildPageContent(String pageText, int pageStart, Color? defaultColor) {
    if (!_isTtsActive || _currentTtsSentence == null || _currentTtsSentence!.chapterIndex != _chapterIndex) {
      return Text(
        pageText,
        style: TextStyle(fontSize: _fontSize, height: _lineHeight, color: defaultColor),
      );
    }

    // 测量朗读句子在当前页内的相交区间
    final sStart = _currentTtsSentence!.startOffset - pageStart;
    final sEnd = _currentTtsSentence!.endOffset - pageStart;

    if (sEnd <= 0 || sStart >= pageText.length) {
      return Text(
        pageText,
        style: TextStyle(fontSize: _fontSize, height: _lineHeight, color: defaultColor),
      );
    }

    final hlStart = sStart.clamp(0, pageText.length);
    final hlEnd = sEnd.clamp(0, pageText.length);

    final before = pageText.substring(0, hlStart);
    final highlight = pageText.substring(hlStart, hlEnd);
    final after = pageText.substring(hlEnd);

    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: _fontSize, height: _lineHeight, color: defaultColor),
        children: [
          TextSpan(text: before),
          TextSpan(
            text: highlight,
            style: TextStyle(
              backgroundColor: _einkMode ? Colors.black12 : Colors.amber.withOpacity(0.35),
              decoration: _einkMode ? TextDecoration.underline : TextDecoration.none,
            ),
          ),
          TextSpan(text: after),
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
              trailing: Text('${ch.wordCount} 字', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _chapterIndex = idx;
                  _pageIndex = 0;
                  _showMenu = false;
                });
                _saveProgress();
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
}
