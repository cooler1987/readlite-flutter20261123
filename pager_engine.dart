import 'package:flutter/material.dart';

class PageEngine {
  /// 基于 computeLineMetrics 计算精确分页切点（彻底杜绝底行被截断或文字重叠）
  static List<int> paginate({
    required String text,
    required TextStyle style,
    required Size contentAreaSize,
    TextScaler textScaler = TextScaler.noScaling,
  }) {
    if (text.isEmpty || contentAreaSize.width <= 0 || contentAreaSize.height <= 0) {
      return [0];
    }

    final List<int> pageStarts = [0];
    int currentOffset = 0;

    while (currentOffset < text.length) {
      // 适度扩大单次测量窗口，并保护 UTF-16 低位代理对（防止切裂 Emoji 或生僻汉字）
      int searchLimit = (currentOffset + 3500).clamp(0, text.length);
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
        // 如果加入当前行会导致高度超出可视区，则截断换页
        if (usedHeight + line.height > contentAreaSize.height && lastVisibleLineEnd > 0) {
          break;
        }
        usedHeight += line.height;
        // 获取该行基线处的末尾字符偏移
        final pos = tp.getPositionForOffset(Offset(contentAreaSize.width, line.baseline));
        lastVisibleLineEnd = pos.offset;
      }

      int pageChars = lastVisibleLineEnd > 0 ? lastVisibleLineEnd : 1;

      // 确保切分点不落在 UTF-16 代理对中间
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

  /// 根据字符在章节中的绝对偏移量，寻找其对应的页码下标
  static int findPageIndexForOffset(List<int> pageStarts, int charOffset) {
    if (pageStarts.isEmpty) return 0;
    for (int i = pageStarts.length - 1; i >= 0; i--) {
      if (charOffset >= pageStarts[i]) {
        return i;
      }
    }
    return 0;
  }

  /// 切分自然句子（用于 TTS 朗读与断句高亮，支持中英文常见标点与后置引号包含）
  static List<RegExpMatch> splitSentences(String text) {
    final sentencePattern = RegExp(
      r'[^。！？!?;；\n\r.]+[。！？!?;；\n\r.]*[”’"\x27）)』」]*',
    );
    return sentencePattern.allMatches(text).toList();
  }
}
