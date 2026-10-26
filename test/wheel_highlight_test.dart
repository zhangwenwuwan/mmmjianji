import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jianji/ui/wheel_date_picker.dart';

/// 2026-10-26 真机实测的 bug：
/// 三列滚轮用 `pixels / itemExtent` 硬算「离中心几格」，在 squeeze / 透视下
/// 不是线性的，结果高亮整体偏了一行 —— 顶部写 2026 年 10 月 26 日，
/// 滚轮里加粗的却是 2025 / 9 / 25，中间那格反而是空的。
///
/// 修法：改成用「离已选中项的格数」（index - selectedIndex）做离散渐变。
/// 这条测试就钉住：只有选中项是 w700，相邻项必须 w400。
void main() {
  testWidgets('只有选中的 年/月/日 是粗体，相邻行不许抢高亮', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WheelDateSheet(
          initial: DateTime(2026, 10, 26),
          includeDay: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    FontWeight? weightOf(String text) {
      final finder = find.text(text);
      expect(finder, findsWidgets, reason: '滚轮里应该渲染出「$text」');
      return tester.widget<Text>(finder.first).style?.fontWeight;
    }

    // 选中项：粗体
    expect(weightOf('2026 年'), FontWeight.w700);
    expect(weightOf('10 月'), FontWeight.w700);
    expect(weightOf('26 日'), FontWeight.w700);

    // 相邻项：不能是粗体（回归点）
    expect(weightOf('2025 年'), FontWeight.w400);
    expect(weightOf('2027 年'), FontWeight.w400);
    expect(weightOf('9 月'), FontWeight.w400);
    expect(weightOf('27 日'), FontWeight.w400);
  });
}
