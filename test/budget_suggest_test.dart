// 预算智能建议纯函数用例：suggestBudgetCents / proportionalSplitCents。
// 结转三件套已有 budget_rules 相关覆盖，这里只盯新函数。
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/budget_rules.dart';

void main() {
  group('suggestBudgetCents', () {
    test('近三月平均，向上取整到整百元', () {
      // (2000 + 2500 + 3000) / 3 = 2500 → 2500 元
      expect(suggestBudgetCents([200000, 250000, 300000]), 250000);
      // (1000 + 1100 + 1200) / 3 = 1100 → 1100 元
      expect(suggestBudgetCents([100000, 110000, 120000]), 110000);
      // 平均 1250 → 取整到 1300（向上）
      expect(suggestBudgetCents([100000, 125000, 150000]), 130000);
    });

    test('没消费的月份不拉低平均', () {
      // 只有两个月有消费：(2000 + 4000) / 2 = 3000 → 3000
      expect(suggestBudgetCents([200000, 0, 400000]), 300000);
    });

    test('全没消费 / 空列表 → 0（不建议）', () {
      expect(suggestBudgetCents([0, 0, 0]), 0);
      expect(suggestBudgetCents(const []), 0);
      expect(suggestBudgetCents([-1, 0]), 0);
    });

    test('很小也到整百元：平均 37 元 → 100 元', () {
      expect(suggestBudgetCents([3700, 0, 0]), 10000);
    });
  });

  group('proportionalSplitCents（最大余数法）', () {
    test('总和守恒：Σ结果 == total', () {
      final r = proportionalSplitCents(
        10000,
        {1: 50000, 2: 30000, 3: 20000}, // 50% / 30% / 20%
      );
      expect(r.values.fold(0, (a, b) => a + b), 10000);
      expect(r[1], 5000);
      expect(r[2], 3000);
      expect(r[3], 2000);
    });

    test('除不尽时余数给比例最大的', () {
      // 100 分给 3 份等比：33/33/33 + 余 1 → 余数给第一个
      final r = proportionalSplitCents(100, {1: 1, 2: 1, 3: 1});
      expect(r.values.fold(0, (a, b) => a + b), 100);
      expect(r[1], 34);
      expect(r[2], 33);
      expect(r[3], 33);
    });

    test('同余数时消费大的优先', () {
      // total=2，两份等比：各 1.0，floor 1+1=2，无余数。
      // 换 total=1：exact 各 0.5，floor 0+0=0，余 1 → 小数部分同为 0.5，
      // 给消费大的（key=1）。
      final r = proportionalSplitCents(1, {1: 100, 2: 100});
      expect(r, {1: 1});
    });

    test('消费为 0 的分类不参与', () {
      final r = proportionalSplitCents(10000, {1: 60000, 2: 0});
      expect(r, {1: 10000});
    });

    test('比例极小、按分摊不到 1 分的分类不建行', () {
      // 100 分，2 号只占 0.1%：floor(0.1)=0，余数 0（1 号 floor 99.9→99，
      // 余 1 给小数最大的 1 号(0.9)）→ 2 号为 0，被移除。
      final r = proportionalSplitCents(100, {1: 999, 2: 1});
      expect(r[1], 100);
      expect(r.containsKey(2), isFalse);
    });

    test('total <= 0 / 空 / 全 0 → 空', () {
      expect(proportionalSplitCents(0, {1: 100}), isEmpty);
      expect(proportionalSplitCents(-5, {1: 100}), isEmpty);
      expect(proportionalSplitCents(100, const {}), isEmpty);
      expect(proportionalSplitCents(100, {1: 0, 2: 0}), isEmpty);
    });
  });
}
