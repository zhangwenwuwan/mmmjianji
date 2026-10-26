import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jianji/ui/wheel_date_picker.dart';

/// 2026-10-26 用户报的 bug：
/// 「不管是统计还是日历里的选择日期有 bug，会滚动出很多月份，一年只有 12 个月，
///   但我可以滚到 12 个月以上……26 年 12 月再往下滚应该是 27 年 1 月」。
///
/// 根因：`CupertinoPicker.builder` 是**无限列表**（没有 childCount），
/// 月份轮原来写死 12 项、`itemBuilder` 却对任意 i 渲染 `i+1 月` → 13 月、20 月…
void main() {
  const minYear = 1996; // 测试里 now-30 的结果（now = 2026）

  group('连续月份轴', () {
    test('26 年 12 月往下滑一格 → 27 年 1 月', () {
      final idx = monthAxisIndex(2026, 12, minYear);
      expect(monthAxisAt(idx, minYear), (year: 2026, month: 12));
      expect(monthAxisAt(idx + 1, minYear), (year: 2027, month: 1));
    });

    test('26 年 1 月往上滑一格 → 25 年 12 月', () {
      final idx = monthAxisIndex(2026, 1, minYear);
      expect(monthAxisAt(idx - 1, minYear), (year: 2025, month: 12));
    });

    test('轴下标永远落在 1~12 月，不会出现 13 月', () {
      for (var i = 0; i < 32 * 12; i++) {
        final at = monthAxisAt(i, minYear);
        expect(at.month, inInclusiveRange(1, 12), reason: 'index=$i');
      }
    });

    test('往返换算不丢（任意年月）', () {
      for (var y = minYear; y <= minYear + 31; y++) {
        for (var m = 1; m <= 12; m++) {
          expect(monthAxisAt(monthAxisIndex(y, m, minYear), minYear),
              (year: y, month: m));
        }
      }
    });
  });

  group('年份范围', () {
    test('能选到 2099 年（原来只到「明年」）', () {
      expect(kWheelMaxYear, 2099);
    });
  });

  group('滚轮实测', () {
    Finder monthWheel(WidgetTester t) => find.byType(CupertinoPicker).at(1);

    /// find.text 只吃 String，正则得自己写 predicate。
    Finder byText(RegExp re) => find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains(re));

    Future<void> pumpSheet(WidgetTester t) async {
      // 显式给 maxYear：默认到 2099（2026-10-26 用户要求放开），
      // 那样"滚到底是哪一年"就不可控了。这里收窄到 2027，断言才稳。
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: WheelDateSheet(
                initial: DateTime(2026, 12), maxYear: 2027)),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('初始停在当前年月', (tester) async {
      await pumpSheet(tester);
      expect(find.text('2026 年 12 月'), findsOneWidget);
    });

    testWidgets('一路猛滚也不会滚出 13 月（原来能滚到 20 月）', (tester) async {
      await pumpSheet(tester);
      for (var i = 0; i < 3; i++) {
        await tester.drag(monthWheel(tester), const Offset(0, -600));
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }
      expect(find.text('13 月'), findsNothing);
      expect(find.text('20 月'), findsNothing);
    });

    testWidgets('往下滚会跨到 2027 年，年份轮跟着走', (tester) async {
      await pumpSheet(tester);
      for (var i = 0; i < 3; i++) {
        await tester.drag(monthWheel(tester), const Offset(0, -600));
        await tester.pumpAndSettle(const Duration(seconds: 2));
      }
      // 标题（带"月"）和年份轮的项（只有"年"）分开断言：
      // 滚多少格由惯性决定，所以只锁"年份前进了、月份还在 1~12"。
      expect(byText(RegExp(r'^2027 年 \d{1,2} 月$')), findsOneWidget);
      // 年份轮也跳到了 2027（说明两列联动，不是一个人在动）
      expect(find.text('2027 年'), findsOneWidget);
      expect(byText(RegExp(r'^2028 年')), findsNothing);
    });

    testWidgets('往上滚会退到 2025 年', (tester) async {
      await pumpSheet(tester);
      await tester.drag(monthWheel(tester), const Offset(0, 600));
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(byText(RegExp(r'^2025 年 \d{1,2} 月$')), findsOneWidget);
      expect(find.text('2025 年'), findsOneWidget);
      expect(find.text('0 月'), findsNothing);
    });
  });
}
