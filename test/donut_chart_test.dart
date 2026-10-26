import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/aggregate.dart';
import 'package:jianji/ui/charts.dart';

/// 环形图的**有数据**路径回归测试。
///
/// 为什么非写不可：`_DonutChartState` 同时持有两个 AnimationController
/// （扫过动画 + 扇区点击回弹），却曾经 mixin 了
/// `SingleTickerProviderStateMixin`，只要有数据就抛：
///   "SingleTickerProviderStateMixin but multiple tickers were created"
///
/// 这个 bug 在空数据库下**永远测不到**——没数据就不构建环形图。
/// 之前的冒烟测试跑的是空库，所以一路绿灯，直到真机上记了账才红屏。
void main() {
  testWidgets('有两个扇区时能正常构建（不得因多 ticker 抛异常）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: DonutChart(
              slices: [
                Slice(label: '餐饮', cents: 6500),
                Slice(label: '交通', cents: 3500),
              ],
              totalCents: 10000,
              symbol: '¥',
            ),
          ),
        ),
      ),
    );

    // 建树阶段就该抓出来：多 ticker 的断言发生在 initState/首帧。
    expect(tester.takeException(), isNull);
    expect(find.text('本月支出'), findsOneWidget);

    // 让扫过动画跑完，别把 ticker 挂着（否则测试结束时会有 "Timer still pending"）
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('单扇区也要正常', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: DonutChart(
              slices: [Slice(label: '餐饮', cents: 100)],
              totalCents: 100,
              symbol: '¥',
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('空扇区不崩（空库场景）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: DonutChart(
              slices: [],
              totalCents: 0,
              symbol: '¥',
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 1));
  });
}
