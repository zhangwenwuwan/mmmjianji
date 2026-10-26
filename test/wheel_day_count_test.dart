import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jianji/ui/wheel_date_picker.dart';

/// 2026-10-26 用户要求：月份变了以后，日期列的天数要自动跟着变
/// （2 月只有 28 天或 29 天，30 天的月份不能出现 31）。
///
/// 这里不靠拖月份轮（拖几格不确定），而是把初始日期直接放在月末：
/// 日列只会渲染到当月最后一天，所以「下一日」在不在，就等于天数对不对。
void main() {
  Future<void> pump(WidgetTester t, DateTime initial) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WheelDateSheet(initial: initial, includeDay: true),
      ),
    ));
    await t.pumpAndSettle();
  }

  testWidgets('平年 2 月：到 28 日为止，没有 29 日', (tester) async {
    await pump(tester, DateTime(2026, 2, 28));
    expect(find.text('28 日'), findsWidgets);
    expect(find.text('29 日'), findsNothing);
  });

  testWidgets('闰年 2 月：有 29 日，但没有 30 日', (tester) async {
    await pump(tester, DateTime(2028, 2, 29));
    expect(find.text('29 日'), findsWidgets);
    expect(find.text('30 日'), findsNothing);
  });

  testWidgets('4 月只有 30 天：没有 31 日', (tester) async {
    await pump(tester, DateTime(2026, 4, 30));
    expect(find.text('30 日'), findsWidgets);
    expect(find.text('31 日'), findsNothing);
  });
}
