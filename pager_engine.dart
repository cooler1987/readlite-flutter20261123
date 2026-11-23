import 'package:flutter/material.dart';

class PageEngine {
  /// 计算章节的分页切点（返回每一页在章节内容中的字符起始下标）
  static List<int> paginate({
    required String text,
    required double fontSize,
    required double lineHeight,
    required Size contentAreaSize,
  }) {
    if (text.isEmpty) return [0];

    final List<int> pageStarts = [0];
    final textStyle = TextStyle(fontSize: fontSize, height: lineHeight);
    int currentOffset = 0;

    while (currentOffset < text.length) {
      // 预估单页字符上限（避免对超长章节做全量测量，提升性能）
      int searchLimit = currentOffset + 1500;
      if (searchLimit > text.length) searchLimit = text.length;

      final chunk = text.substring(currentOffset, searchLimit);
      final textSpan = TextSpan(text: chunk, style: textStyle);

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
        maxLines: null,
      )..layout(maxWidth: contentAreaSize.width);

      // 获取当前可视高度能容纳的最后一个字符位置
      final position = textPainter.getPositionForOffset(
        Offset(contentAreaSize.width, contentAreaSize.height),
      );

      int pageChars = position.offset;

      // 防止异常死循环
      if (pageChars <= 0) {
        pageChars = 1;
      }

      final nextOffset = currentOffset + pageChars;
      if (nextOffset < text.length) {
        pageStarts.add(nextOffset);
        currentOffset = nextOffset;
      } else {
        break;
      }
    }

    return pageStarts;
  }

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

  /// 切分自然句子（用于 TTS 朗读与断句高亮）
  static List<RegExpMatch> splitSentences(String text) {
    // 匹配包含标点结尾的句子或段落
    final sentencePattern = RegExp(r'[^。！？!?;；\n\r]+[。！？!?;；\n\r]?');
    return sentencePattern.allMatches(text).toList();
  }
}
