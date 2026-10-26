import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/aggregate.dart';
import 'package:jianji/core/rules.dart';

void main() {
  group('金额解析', () {
    test('常见输入', () {
      expect(parseAmountToCents('12.30'), 1230);
      expect(parseAmountToCents('12.3'), 1230);
      expect(parseAmountToCents('12'), 1200);
      expect(parseAmountToCents(' 8 '), 800);
      expect(parseAmountToCents('.5'), 50);
      expect(parseAmountToCents('0'), 0);
    });

    test('带千分位与负号', () {
      expect(parseAmountToCents('1,234.56'), 123456);
      expect(parseAmountToCents('1，234'), 123400); // 中文逗号
      expect(parseAmountToCents('-5'), -500);
      expect(parseAmountToCents('+5'), 500);
    });

    test('多余小数位截断，不四舍五入', () {
      expect(parseAmountToCents('1.999'), 199);
      expect(parseAmountToCents('0.005'), 0);
    });

    test('非法输入返回 null', () {
      expect(parseAmountToCents(''), isNull);
      expect(parseAmountToCents('abc'), isNull);
      expect(parseAmountToCents('1.2.3'), isNull);
      expect(parseAmountToCents('-'), isNull);
      expect(parseAmountToCents('.'), isNull);
    });
  });

  group('金额展示', () {
    test('整数不带小数，其余最多两位', () {
      expect(centsToText(1200), '12');
      expect(centsToText(1230), '12.3');
      expect(centsToText(1234), '12.34');
      expect(centsToText(0), '0');
      expect(centsToText(123456789), '1,234,567.89');
    });

    test('带符号', () {
      expect(centsToSignedText(1234), '+12.34');
      expect(centsToSignedText(-1234), '-12.34');
      expect(centsToSignedText(0), '0');
    });

    test('固定两位（账单导出场景）', () {
      expect(centsToText(1200, alwaysTwoDecimals: true), '12.00');
    });
  });

  group('计算器运算（acc / v 都是分）', () {
    test('加减', () {
      expect(applyAmountOp(1200, '+', 500), 1700);
      expect(applyAmountOp(1200, '-', 500), 700);
    });

    test('乘法：17 元 × 2 元 = 34 元，不能是 3400 元', () {
      // 曾经的 bug：分 × 分 直接相乘 → 1700*200 = 340000 分 = 3400 元
      expect(applyAmountOp(1700, '×', 200), 3400);
      expect(centsToText(applyAmountOp(1700, '×', 200)), '34');
    });

    test('乘法带小数：0.1 × 0.3 = 0.03', () {
      expect(applyAmountOp(10, '×', 30), 3);
    });

    test('除法：17 元 ÷ 2 = 8.5 元', () {
      expect(applyAmountOp(1700, '÷', 200), 850);
      expect(centsToText(applyAmountOp(1700, '÷', 200)), '8.5');
    });

    test('除零保持累加值，不清空', () {
      expect(applyAmountOp(1700, '÷', 0), 1700);
    });

    test('未知运算符原样返回', () {
      expect(applyAmountOp(1700, '?', 200), 200);
    });
  });

  group('日期规则', () {
    test('月份键与日期键', () {
      expect(monthKey(DateTime(2026, 10, 21)), '2026-10');
      expect(monthKey(DateTime(2026, 1, 1)), '2026-01');
      expect(dayKey(DateTime(2026, 10, 5)), '2026-10-05');
    });

    test('月末与闰年', () {
      expect(daysInMonth(DateTime(2026, 2)), 28);
      expect(daysInMonth(DateTime(2028, 2)), 29);
      expect(daysInMonth(DateTime(2026, 10)), 31);
    });

    test('月份跨越', () {
      expect(monthKey(shiftMonth(DateTime(2026, 1, 15), -1)), '2025-12');
      expect(monthKey(shiftMonth(DateTime(2026, 12, 1), 1)), '2027-01');
    });

    test('剩余天数含今天', () {
      expect(daysLeftInMonth(DateTime(2026, 10, 21)), 11);
      expect(daysLeftInMonth(DateTime(2026, 10, 31)), 1);
      expect(daysLeftInMonth(DateTime(2026, 10, 1)), 31);
    });
  });

  group('分类占比', () {
    test('超过限制时合并成「其他」', () {
      final input = [
        const Slice(label: 'a', cents: 100),
        const Slice(label: 'b', cents: 80),
        const Slice(label: 'c', cents: 60),
        const Slice(label: 'd', cents: 40),
        const Slice(label: 'e', cents: 20),
        const Slice(label: 'f', cents: 10),
      ];
      final ranked = rankSlices(input, limit: 5);
      expect(ranked.length, 5);
      expect(ranked.last.label, '其他');
      expect(ranked.last.cents, 30); // 20 + 10
      expect(ranked.first.label, 'a');
    });

    test('全零返回空，避免画出一堆 0% 的图例', () {
      expect(
        rankSlices(const [Slice(label: 'a', cents: 0), Slice(label: 'b', cents: 0)]),
        isEmpty,
      );
    });

    test('正好等于限制时不合并', () {
      final ranked = rankSlices(const [
        Slice(label: 'a', cents: 1),
        Slice(label: 'b', cents: 1),
      ], limit: 5);
      expect(ranked.length, 2);
    });
  });

  group('预算进度', () {
    final month = DateTime(2026, 10);
    final today = DateTime(2026, 10, 21);

    test('正常进度', () {
      final p = buildBudgetProgress(
        budgetCents: 300000,
        spentCents: 120000,
        month: month,
        today: today,
      );
      expect(p.configured, isTrue);
      expect(p.remainCents, 180000);
      expect(p.daysLeft, 11);
      expect(p.overflow, isFalse);
      // 1800 / 11 = 163.63 → 取整 163 元的分
      expect(p.safeDailyCents, 16363);
      expect(p.ratio, closeTo(0.4, 1e-9));
    });

    test('超支时安全额度为 0 而不是负数', () {
      final p = buildBudgetProgress(
        budgetCents: 100000,
        spentCents: 150000,
        month: month,
        today: today,
      );
      expect(p.overflow, isTrue);
      expect(p.safeDailyCents, 0);
      expect(p.ratio, 1.0);
      expect(p.remainCents, -50000);
    });

    test('未设预算', () {
      final p = buildBudgetProgress(
        budgetCents: 0,
        spentCents: 5000,
        month: month,
        today: today,
      );
      expect(p.configured, isFalse);
      expect(p.safeDailyCents, 0);
      expect(p.ratio, 0);
    });

    test('看历史月份时剩余天数按 0 处理（不做"每天还能花"推算）', () {
      final p = buildBudgetProgress(
        budgetCents: 100000,
        spentCents: 40000,
        month: DateTime(2026, 9),
        today: today,
      );
      expect(p.daysLeft, 0);
      expect(p.safeDailyCents, 60000); // 剩余全额
    });
  });
}
