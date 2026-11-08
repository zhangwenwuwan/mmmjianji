import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/shell.dart';

/// 2026-11-08 液态玻璃底栏交互回归。
///
/// 独立于数据库：LiquidBottomBar 只吃 Theme.of(context)，不需要 ProviderScope
/// / sqflite，所以可以单独 pump，断言精确到「回调收到了哪个槽位」。
///
/// 钉住三件事：
/// 1. 横向拖拽选中块能切 tab（原来只有点击）；
/// 2. 拖到中间的 + 槽不会误触发记账动作；
/// 3. 点击仍然完全可用，且按压时**玻璃层不跟着缩放**（官方 layerBlock 坑：
///    把 backdrop 一起缩放会错位，这里只缩 Glass 的 child）。
void main() {
  Widget host({
    required int selectedSlot,
    required ValueChanged<int> onSelect,
  }) =>
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: LiquidBottomBar(
            selectedSlot: selectedSlot,
            onSelect: onSelect,
          ),
          body: const SizedBox.expand(),
        ),
      );

  Future<void> prepare(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  /// 胶囊内部一格的宽度：SafeArea 左右各 14，五个槽平分。
  double slotWidth(WidgetTester tester) =>
      (tester.getRect(find.byType(LiquidBottomBar)).width - 28) / 5;

  testWidgets('横向拖拽一格切到统计，且不会误触中间的记账键', (tester) async {
    final picked = <int>[];
    await prepare(tester, host(selectedSlot: 0, onSelect: picked.add));

    await tester.drag(
        find.byType(LiquidBottomBar), Offset(slotWidth(tester), 0));
    await tester.pumpAndSettle();

    expect(picked, [1], reason: '拖拽一格应选中槽位 1（统计）');
    expect(picked.contains(2), isFalse, reason: '中间的 + 是动作键，不能被拖拽选中');
  });

  testWidgets('拖过两格落在 + 槽时按方向吸附到有效页面', (tester) async {
    final picked = <int>[];
    await prepare(tester, host(selectedSlot: 0, onSelect: picked.add));

    await tester.drag(find.byType(LiquidBottomBar),
        Offset(slotWidth(tester) * 2, 0));
    await tester.pumpAndSettle();

    expect(picked, isNot(contains(2)), reason: '+ 槽永远不能成为选中态');
    expect(picked, isNotEmpty, reason: '松手仍要落到某个有效页面');
    expect(picked.first == 3 || picked.first == 1, isTrue,
        reason: '按拖动方向就近吸附到 3（资产）或 1（统计）');
  });

  testWidgets('点击仍可用；按压只缩内容，玻璃层保持原位', (tester) async {
    final picked = <int>[];
    await prepare(tester, host(selectedSlot: 0, onSelect: picked.add));

    // ① 点「我的」照旧切页
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expect(picked.last, 4, reason: '点击 tab 的原有行为不能被手势层吃掉');

    // ② 按住玻璃空白处：内容缩放，但 BackdropFilter 的矩形一动不动。
    final bar = tester.getRect(find.byType(LiquidBottomBar));
    final glassRect = tester.getRect(find.byType(BackdropFilter));
    final gesture = await tester.startGesture(bar.topLeft + const Offset(4, 4));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.getRect(find.byType(BackdropFilter)), glassRect,
        reason: '玻璃层不能被按压缩放连带放大（官方 layerBlock 要修的错位）');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('按下最右格同帧高光立即切到触点，松手才淡出', (tester) async {
    final picked = <int>[];
    await prepare(tester, host(selectedSlot: 0, onSelect: picked.add));
    final bar = tester.getRect(find.byType(LiquidBottomBar));

    // 找装饰层 painter。类在 shell.dart 里是库私有，用 dynamic 读字段。
    final overlay = find.byWidgetPredicate((w) =>
        w is CustomPaint &&
        w.painter != null &&
        w.painter.runtimeType.toString().contains('LiquidOverlay'));
    expect(overlay, findsOneWidget);
    dynamic painter() => tester.widget<CustomPaint>(overlay).painter;

    // ① 当前选中在首页（槽 0），但手指按在最右边的「我的」格。
    final gesture = await tester.startGesture(
        Offset(bar.right - 60, bar.center.dy));
    await tester.pump(); // 只走一帧，不给任何渐入时间
    expect(painter().glow, greaterThan(0.9),
        reason: '高光必须按下同帧就满亮，不能等 170ms 渐入');
    expect((painter().touch as Offset).dx, greaterThan(bar.width * 0.7),
        reason: '高光中心要立刻切到手指所在的最右格，而不是留在首页');

    // ② 松手：高光留在最后触点慢慢淡出，不能当帧消失。
    await gesture.up();
    await tester.pump();
    expect(painter().touch, isNotNull, reason: '淡出期间不能清空触点');
    expect(painter().glow, greaterThan(0.0), reason: '松手当帧高光还在淡出');
    await tester.pumpAndSettle();
    expect(painter().glow, 0.0, reason: '淡出结束后完全熄灭');
    expect(tester.takeException(), isNull);
  });
}
