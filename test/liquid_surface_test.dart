import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/liquid_surface.dart';

/// 公共液态材质层（2026-11-08 P0）的回归钉。
///
/// 这套组件要被对话框、弹窗、分段控件、滑条、语音键复用，所以必须先钉死
/// 两条：① 按下同帧点亮（不能被渐入拖住）；② 只用 Listener 读指针，
/// **绝不抢 child 自己的点击手势** —— 抢了就会让设置开关/滑条失灵。
void main() {
  testWidgets('按下同帧点亮、松手淡出，且不抢 child 点击', (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: LiquidSurface(
            radius: 12,
            child: GestureDetector(
              onTap: () => taps.add(1),
              child: const SizedBox(
                width: 160,
                height: 56,
                child: Center(child: Text('点我')),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final overlay = find.byWidgetPredicate((w) =>
        w is CustomPaint && w.painter is LiquidOverlayPainter);
    expect(overlay, findsOneWidget, reason: '液态表面层应存在');
    LiquidOverlayPainter painter() =>
        tester.widget<CustomPaint>(overlay).painter as LiquidOverlayPainter;
    expect(painter().glow, 0.0, reason: '静止时完全不亮');

    // ① 按下的那一帧就要满亮，位置在触点。
    final gesture = await tester.startGesture(tester.getCenter(find.text('点我')));
    await tester.pump();
    expect(painter().glow, 1.0, reason: '按下同帧点亮，不能等渐入');
    expect(painter().touch, isNotNull);

    // ② 松手淡出，且 child 的 tap 照常触发（Listener 不进手势竞技场）。
    await gesture.up();
    await tester.pump();
    expect(painter().glow, greaterThan(0.0), reason: '松手当帧还在淡出');
    await tester.pumpAndSettle();
    expect(painter().glow, 0.0, reason: '淡出结束熄灭');
    expect(taps, [1], reason: '不能吃掉 child 的点击');
    expect(tester.takeException(), isNull);
  });

  testWidgets('enabled=false 时不接管、也不画装饰层', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: LiquidSurface(
            enabled: false,
            child: const SizedBox(width: 80, height: 40, child: Text('普通')),
          ),
        ),
      ),
    ));
    expect(
      find.byWidgetPredicate((w) =>
          w is CustomPaint && w.painter is LiquidOverlayPainter),
      findsNothing,
    );
    expect(find.text('普通'), findsOneWidget);
  });
}
