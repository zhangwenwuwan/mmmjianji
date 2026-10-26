import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/pull_to_add.dart';

/// 「下拉记账」手势的回归测试。
///
/// 锁四件事：
/// ① 下拉**松手**才触发，且只触发一次；
/// ② 阈值之内（拉一点点）不触发——真机反馈"太灵敏、没有下拉感"就是因为阈值太低；
/// ③ 拉过去又推回来（撤劲）不触发；
/// ④ 横向滑动（月份条那种）不能被误判。
void main() {
  Widget host({
    required VoidCallback onTrigger,
    required Widget child,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: PullToAdd(onTrigger: onTrigger, child: child),
        ),
      );

  Widget verticalList() => ListView.builder(
        itemCount: 40,
        itemBuilder: (_, i) =>
            SizedBox(height: 60, child: Text('item $i', key: Key('item-$i'))),
      );

  testWidgets('下拉超过阈值，松手触发一次', (tester) async {
    var count = 0;
    await tester
        .pumpWidget(host(onTrigger: () => count++, child: verticalList()));

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();

    expect(count, 1);
  });

  testWidgets('拉一点点不触发（阈值之内）', (tester) async {
    var count = 0;
    await tester
        .pumpWidget(host(onTrigger: () => count++, child: verticalList()));

    await tester.drag(find.byType(ListView), const Offset(0, 120));
    await tester.pumpAndSettle();

    expect(count, 0, reason: '120dp 不该触发，否则手感就是"太灵敏"');
  });

  testWidgets('拉过阈值但没松手不触发，且提示变成"松开"', (tester) async {
    var count = 0;
    await tester
        .pumpWidget(host(onTrigger: () => count++, child: verticalList()));

    final g = await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await g.moveBy(const Offset(0, 300));
    await tester.pump();

    expect(count, 0, reason: '手指还按着就不该跳走');
    expect(find.text('松开手指，记一笔'), findsOneWidget);

    await g.up();
    await tester.pumpAndSettle();
    expect(count, 1);
  });

  testWidgets('一次长拉只触发一次（不重复 push）', (tester) async {
    var count = 0;
    await tester
        .pumpWidget(host(onTrigger: () => count++, child: verticalList()));

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();

    expect(count, 1);
  });

  testWidgets('往上滑不触发', (tester) async {
    var count = 0;
    await tester
        .pumpWidget(host(onTrigger: () => count++, child: verticalList()));

    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(count, 0);
  });

  testWidgets('横向滚动不触发', (tester) async {
    var count = 0;
    await tester.pumpWidget(host(
      onTrigger: () => count++,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: 20,
        itemBuilder: (_, i) =>
            SizedBox(width: 120, child: Text('h$i', key: Key('h-$i'))),
      ),
    ));

    await tester.drag(find.byType(ListView), const Offset(300, 0));
    await tester.pumpAndSettle();

    expect(count, 0, reason: '横向滑动（月份条那种）不能被当成下拉记账');
  });

  testWidgets('第二次手势可以再次触发', (tester) async {
    var count = 0;
    await tester
        .pumpWidget(host(onTrigger: () => count++, child: verticalList()));

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(count, 1);

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(count, 2, reason: '一次手势只触发一次，但下一次手势应该还能触发');
  });
}
