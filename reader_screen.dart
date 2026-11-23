import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  Size _lastContentSize = Size.zero;

  double _fontSize = 20.0;
  double _lineHeight = 1.6;
  double _margin = 16.0;
  bool _einkMode = false;
  bool _showMenu = false;

  // TTS 状态
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
      // 检查当前句子是否需要翻页
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

    // 读完本章后自动连播下一章
    _tts.onChapterComplete = () {
      if (_chapterIndex < _chapters.length - 1) {
        setState(() {
          _chapterIndex++;
          _pageIndex = 0;
          _recomputePagination(_lastContentSize, targetOffset: 0);
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
    _ttsSub?.cancel();
    _ttsStateSub?.cancel();
    _tts.onChapterComplete = null;
    _tts.stop();
    _saveProgress();
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

  /// 仅在尺寸或排版参数改变时触发的分页计算（杜绝在 build 中全量死循环测量）
  void _recomputePagination(Size contentSize, {int? targetOffset}) {
    if (_chapters.isEmpty || contentSize.width <= 0 || contentSize.height <= 0) return;

    final chapter = _chapters[_chapterIndex];
    final offsetToRestore = targetOffset ??
        ((_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : widget.book.currentOffset);

    final starts = PageEngine.paginate(
      text: chapter.content,
      style: TextStyle(fontSize: _fontSize, height: _lineHeight),
      contentAreaSize: contentSize,
    );

    _pageStarts = starts;
    _pageIndex = PageEngine.findPageIndexForOffset(starts, offsetToRestore);
    _lastContentSize = contentSize;
  }

  void _saveProgress() {
    if (_chapters.isEmpty) return;
    final currentOffset = (_pageIndex < _pageStarts.length) ? _pageStarts[_pageIndex] : 0;
    widget.book.currentChapterIndex = _chapterIndex;
    widget.book.currentOffset = currentOffset;

    // 结合章节与页码精确计算进度
    final totalChapters = _chapters.length;
    final chapterFraction = (_pageStarts.isNotEmpty && _pageStarts.length > 1)
        ? (_pageIndex / (_pageStarts.length - 1))
        : 0.0;
    widget.book.progress = ((_chapterIndex + chapterFraction) / totalChapters).clamp(0.0, 1.0);
    widget.book.lastReadTime = DateTime.now();

    Storage.saveBook(widget.book);
  }

  void _prevPage() {
    if (_pageIndex > 0) {
      setState(() => _pageIndex--);
      _saveProgress();
    } else if (_chapterIndex > 0) {
      // 向上翻章：跳到上一章的最后一页
      setState(() {
        _chapterIndex--;
        final prevChapter = _chapters[_chapterIndex];
        final prevStarts = PageEngine.paginate(
          text: prevChapter.content,
          style: TextStyle(fontSize: _fontSize, height: _lineHeight),
          contentAreaSize: _lastContentSize,
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
      // 向下翻章：跳到下一章第一页
      setState(() {
        _chapterIndex++;
        _pageIndex = 0;
        _recomputePagination(_lastContentSize, targetOffset: 0);
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
    final preview = chapter.content.substring(
      currentOffset,
      (currentOffset + 40).clamp(0, chapter.content.length),
    ).replaceAll('\n', ' ');

    final bookmark = Bookmark(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      bookId: widget.book.id,
      chapterIndex: _chapterIndex,
      offset: currentOffset,
      text: preview,
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
        body: Center(child: Text(_error, style: const TextStyle(color: Colors.red))),
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

    return Focus(
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
                            style: TextStyle(fontSize: 12, color: _einkMode ? Colors.black87 : Colors.grey.shade600),
                          ),
                        ),
                        Text(
                          '${_chapterIndex + 1}/${_chapters.length} 章',
                          style: TextStyle(fontSize: 12, color: _einkMode ? Colors.black87 : Colors.grey.shade600),
                        ),
                      ],
                    ),
                  ),

                  // 页面正文 (使用 LayoutBuilder 严格保证按渲染尺寸精准分页)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: _margin),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final currentSize = Size(constraints.maxWidth, constraints.maxHeight);
                          if (_lastContentSize != currentSize) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) {
                                setState(() {
                                  _recomputePagination(currentSize);
                                });
                              }
                            });
                          }
                          return _buildPageContent(pageText, pageStart, textColor);
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
                        Text(widget.book.title, style: TextStyle(fontSize: 12, color: _einkMode ? Colors.black87 : Colors.grey.shade600)),
                        Text('${_pageIndex + 1}/${_pageStarts.length} 页',
                            style: TextStyle(fontSize: 12, color: _einkMode ? Colors.black87 : Colors.grey.shade600)),
                      ],
                    ),
                  ),
                ],
              ),

              // 三等分触控区 + 左右手势滑动手势支持
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  if (details.primaryVelocity != null) {
                    if (details.primaryVelocity! < -100) {
                      _nextPage(); // 向左滑 -> 下一页
                    } else if (details.primaryVelocity! > 100) {
                      _prevPage(); // 向右滑 -> 上一页
                    }
                  }
                },
                child: Row(
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                                  _recomputePagination(_lastContentSize);
                                });
                                Storage.setFontSize(_fontSize);
                              },
                            ),
                            Text('${_fontSize.toInt()}sp', style: const TextStyle(color: Colors.white)),
                            IconButton(
                              icon: const Icon(Icons.text_increase, color: Colors.white),
                              tooltip: '放大字号',
                              onPressed: () {
                                setState(() {
                                  _fontSize = (_fontSize + 2).clamp(14.0, 36.0);
                                  _recomputePagination(_lastContentSize);
                                });
                                Storage.setFontSize(_fontSize);
                              },
                            ),
                            IconButton(
                              icon: Icon(_einkMode ? Icons.contrast : Icons.contrast_outlined, color: Colors.white),
                              tooltip: '墨水屏模式',
                              onPressed: () {
                                setState(() => _einkMode = !_einkMode);
                                Storage.setEinkMode(_einkMode);
                              },
                            ),
                            IconButton(
                              icon: Icon(_isTtsActive ? Icons.volume_up : Icons.volume_off, color: Colors.white),
                              tooltip: '朗读听书',
                              onPressed: _toggleTts,
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
                  bottom: _showMenu ? 80 : 24,
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
      ),
    );
  }

  /// 统一使用 Text.rich 构建正文与朗读高亮（彻底解决 Text 与 RichText 换行抖动）
  Widget _buildPageContent(String pageText, int pageStart, Color? defaultColor) {
    final style = TextStyle(fontSize: _fontSize, height: _lineHeight, color: defaultColor);

    if (!_isTtsActive || _currentTtsSentence == null || _currentTtsSentence!.chapterIndex != _chapterIndex) {
      return Text.rich(TextSpan(text: pageText, style: style));
    }

    final sStart = _currentTtsSentence!.startOffset - pageStart;
    final sEnd = _currentTtsSentence!.endOffset - pageStart;

    if (sEnd <= 0 || sStart >= pageText.length) {
      return Text.rich(TextSpan(text: pageText, style: style));
    }

    final hlStart = sStart.clamp(0, pageText.length);
    final hlEnd = sEnd.clamp(0, pageText.length);

    final before = pageText.substring(0, hlStart);
    final highlight = pageText.substring(hlStart, hlEnd);
    final after = pageText.substring(hlEnd);

    return Text.rich(
      TextSpan(
        style: style,
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
                  _recomputePagination(_lastContentSize, targetOffset: 0);
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

  void _showBookmarks() {
    final bookmarks = Storage.getBookmarks(widget.book.id);
    showModalBottomSheet(
      context: context,
      builder: (ctx) {
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
              subtitle: Text('第 ${bm.chapterIndex + 1} 章 · ${bm.createTime.toString().substring(0, 16)}'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _chapterIndex = bm.chapterIndex;
                  _showMenu = false;
                  _recomputePagination(_lastContentSize, targetOffset: bm.offset);
                });
                _saveProgress();
              },
            );
          },
        );
      },
    );
  }
}
