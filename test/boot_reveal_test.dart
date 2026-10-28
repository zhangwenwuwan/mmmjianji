import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/boot_reveal.dart';
import 'package:jianji/ui/splash_page.dart';
import 'package:jianji/ui/theme.dart';

/// 启动「开幕」的两半：时间线的排期，和幕本身的阶段回调。
///
/// 幕的手感全靠时间，而时间是**唯一没法靠肉眼验收**的东西 ——
/// 差 200ms 看起来只是"有点怪"，说不出哪里怪。所以把时长钉成断言。
void main() {
  group('BootRevealTimeline', () {
    test('每块间隔 60ms，序号越大越晚', () {
      final t = BootRevealTimeline(
        startAt: DateTime.now().add(const Duration(seconds: 1)),
      );
      final d0 = t.delayFor(0);
      final d1 = t.delayFor(1);
      final d3 = t.delayFor(3);
      // 留 ±5ms 的余量：两次 delayFor 之间 DateTime.now() 自己会走掉一点
      expect((d1 - d0).inMilliseconds, inInclusiveRange(55, 65));
      expect((d3 - d0).inMilliseconds, inInclusiveRange(175, 185));
    });

    test('序号封顶：第 20 块不会排到 1.2 秒之后', () {
      final t = BootRevealTimeline(
        startAt: DateTime.now().add(const Duration(seconds: 1)),
      );
      expect((t.delayFor(20) - t.delayFor(BootRevealTimeline.maxIndex))
          .inMilliseconds
          .abs(),
          lessThan(5));
      expect((t.delayFor(20) - t.delayFor(0)).inMilliseconds,
          inInclusiveRange(355, 365));
    });

    test('已经过了的时刻直接返回 0（晚创建的块不该再从头排队）', () {
      final t = BootRevealTimeline(
        startAt: DateTime.now().subtract(const Duration(seconds: 5)),
      );
      expect(t.delayFor(0), Duration.zero);
      expect(t.delayFor(5), Duration.zero);
    });
  });

  group('SplashCurtain', () {
    testWidgets('呼吸 600ms 后才开张，再 700ms 收完', (tester) async {
      var opened = false;
      var done = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: SplashCurtain(
            onOpenStart: () => opened = true,
            onDone: () => done = true,
          ),
        ),
      );

      // 呼吸阶段：只画幕，首页还没进场（首页构建和"张开"要并行，
      // 提前插进来会抢首帧）
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, isFalse);
      expect(done, isFalse);

      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(opened, isTrue, reason: '呼吸结束就该通知插入首页');
      expect(done, isFalse);

      // 张开还没走完，幕不能先摘 —— 摘早了就是硬切
      await tester.pump(const Duration(milliseconds: 400));
      expect(done, isFalse);

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(done, isTrue, reason: '张开结束才摘幕');
    });

    testWidgets('系统「减少动态效果」时一帧都不演', (tester) async {
      var opened = false;
      var done = false;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: SplashCurtain(
              onOpenStart: () => opened = true,
              onDone: () => done = true,
            ),
          ),
        ),
      );
      // 一帧就交完（回调排在帧后，避开 build 期间 setState），
      // 期间没有任何动画被创建，所以也不需要 pump 时长
      await tester.pump();
      expect(opened, isTrue);
      expect(done, isTrue);
    });

    testWidgets('幕收完后时间线失效，新建的块直接显示', (tester) async {
      final timeline = BootRevealTimeline(
        startAt: DateTime.now().add(const Duration(seconds: 1)),
      );
      timeline.active = false;

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: BootRevealScope(
            timeline: timeline,
            child: const BootRevealItem(
              index: 3,
              child: Text('首页内容'),
            ),
          ),
        ),
      );
      final opacity = tester.widget<Opacity>(
        find.ancestor(
          of: find.text('首页内容'),
          matching: find.byType(Opacity),
        ),
      );
      expect(opacity.opacity, 1.0);
    });
  });
}
