import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/common.dart';

/// 分区标题的回归测试。
///
/// 曾经这里有个 `keepLastTwoTogether()`，想在最后两字之间塞 NBSP 防止
/// "最后一行只剩一个字"。但它写成了 `substring(0, len-2)` + 最后一个字，
/// **中间那个字被直接丢掉**：
///   「数据管理」→「数据 理」
///   「分类预算（可选）」→「分类预算（可 ）」
/// 37 处分区标题全部中招，肉眼一眼能看出、但没有任何测试盯着。
void main() {
  testWidgets('分区标题一个字都不能少', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionLabel('数据管理'),
            SectionLabel('分类预算（可选）'),
            SectionLabel('三'),
          ],
        ),
      ),
    ));

    expect(find.text('数据管理'), findsOneWidget);
    expect(find.text('分类预算（可选）'), findsOneWidget);
    expect(find.text('三'), findsOneWidget);
    // 别再出现被"吃掉一个字"的形态
    expect(find.textContaining('数据 '), findsNothing);
  });

  testWidgets('分区标题不换行（单行 + 省略号）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SectionLabel('一个非常非常长的分区标题不应该换行把最后一个字挤下去'),
      ),
    ));
    final text = tester.widget<Text>(find.byType(Text));
    expect(text.maxLines, 1);
    expect(text.softWrap, isFalse);
    expect(text.overflow, TextOverflow.ellipsis);
  });
}
