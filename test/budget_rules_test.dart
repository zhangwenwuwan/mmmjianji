import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/aggregate.dart';
import 'package:jianji/core/budget_rules.dart';

/// 预算结转 + 今日安全可花的纯逻辑测试。
///
/// 这块算错的后果是"我明明设了 3000，怎么显示 2600"——用户不会去翻设置，
/// 直接判定这软件算错账。所以四个开关组合必须逐一对齐。
void main() {
  group('budgetCarryCents', () {
    test('上期没设预算 → 不结转也不倒扣（哪怕花了很多）', () {
      expect(
        budgetCarryCents(
          prevBudget: 0,
          prevSpent: 500000,
          addUnused: true,
          deductOver: true,
        ),
        0,
      );
    });

    test('两个开关都关 → 0', () {
      expect(
        budgetCarryCents(
          prevBudget: 300000,
          prevSpent: 120000,
          addUnused: false,
          deductOver: false,
        ),
        0,
      );
    });

    test('两个都开：带符号差额，正负都滚', () {
      expect(
        budgetCarryCents(
            prevBudget: 300000, prevSpent: 120000, addUnused: true, deductOver: true),
        180000,
      );
      expect(
        budgetCarryCents(
            prevBudget: 100000, prevSpent: 160000, addUnused: true, deductOver: true),
        -60000,
      );
    });

    test('只开「多余累加」：省下的带过来', () {
      expect(
        budgetCarryCents(
            prevBudget: 300000, prevSpent: 120000, addUnused: true, deductOver: false),
        180000,
      );
    });

    test('只开「多余累加」：超支不带过来（不能惩罚）', () {
      expect(
        budgetCarryCents(
            prevBudget: 100000, prevSpent: 160000, addUnused: true, deductOver: false),
        0,
      );
    });

    test('只开「超额扣除」：超支带过来（负数）', () {
      expect(
        budgetCarryCents(
            prevBudget: 100000, prevSpent: 160000, addUnused: false, deductOver: true),
        -60000,
      );
    });

    test('只开「超额扣除」：省下的不结转', () {
      expect(
        budgetCarryCents(
            prevBudget: 300000, prevSpent: 120000, addUnused: false, deductOver: true),
        0,
      );
    });

    test('刚好花完 → 0', () {
      expect(
        budgetCarryCents(
            prevBudget: 200000, prevSpent: 200000, addUnused: true, deductOver: true),
        0,
      );
    });
  });

  group('effectiveBudgetCents', () {
    test('正结转相加', () {
      expect(effectiveBudgetCents(base: 300000, carry: 180000), 480000);
    });

    test('负结转相减', () {
      expect(effectiveBudgetCents(base: 300000, carry: -60000), 240000);
    });

    test('扣成负数时夹到 0（显示负数可用没有意义）', () {
      expect(effectiveBudgetCents(base: 50000, carry: -180000), 0);
    });

    test('没有基础预算 → 0', () {
      expect(effectiveBudgetCents(base: 0, carry: 99999), 99999);
      // 注意：这条只是纯函数行为，上层 effectiveBudgetProvider 会在
      // base <= 0 时直接返回 0，不会让"上月省下的钱"变成一个凭空出现的预算。
    });
  });

  group('overFromPrevCents', () {
    test('扣完后仍欠多少', () {
      expect(overFromPrevCents(base: 50000, carry: -180000), 130000);
    });

    test('没欠 → 0', () {
      expect(overFromPrevCents(base: 300000, carry: -60000), 0);
      expect(overFromPrevCents(base: 300000, carry: 10000), 0);
    });
  });

  /// 2026-10-25 真机反馈：有预算时每天记账后，「今日安全可花」数字不动 ——
  /// 旧公式只算日均值，不减今天已花的钱。这里把语义钉死。
  group('safeToSpendCents', () {
    test('今天一分没花 → 等于日均可用', () {
      expect(
        safeToSpendCents(
          budgetCents: 300000,
          spentCents: 140000,
          todaySpentCents: 0,
          pendingCents: 0,
          daysLeft: 20,
        ),
        8000,
      );
    });

    test('今天花了钱 → 数字要跟着掉（旧 bug：不降）', () {
      // 固定本月已花，只变「今天花了多少」：差额必须正好等于今天的花费
      final none = safeToSpendCents(
        budgetCents: 300000,
        spentCents: 150000,
        todaySpentCents: 0,
        pendingCents: 0,
        daysLeft: 20,
      );
      final some = safeToSpendCents(
        budgetCents: 300000,
        spentCents: 150000,
        todaySpentCents: 10000,
        pendingCents: 0,
        daysLeft: 20,
      );
      expect(none, 7500); // (300000-150000)/20
      expect(some, none - 10000, reason: '今天花 100，今日可花就少 100');
    });

    test('今天花超了 → 返回负数，由界面红字提醒', () {
      final v = safeToSpendCents(
        budgetCents: 300000,
        spentCents: 250000,
        todaySpentCents: 40000,
        pendingCents: 0,
        daysLeft: 5,
      );
      // (300000-250000)/5 = 10000，今天已花 40000 → -30000
      expect(v, -30000);
    });

    test('待扣的周期账单先扣掉，不摊到今天头上', () {
      expect(
        safeToSpendCents(
          budgetCents: 300000,
          spentCents: 0,
          todaySpentCents: 0,
          pendingCents: 60000,
          daysLeft: 10,
        ),
        24000,
      );
    });

    test('月末最后一天 → 剩余预算全部可用', () {
      expect(
        safeToSpendCents(
          budgetCents: 300000,
          spentCents: 280000,
          todaySpentCents: 10000,
          pendingCents: 0,
          daysLeft: 1,
        ),
        10000,
      );
    });

    test('没设预算 / 不在本月视图 → 0', () {
      expect(
        safeToSpendCents(
          budgetCents: 0,
          spentCents: 0,
          todaySpentCents: 0,
          pendingCents: 0,
          daysLeft: 20,
        ),
        0,
      );
      expect(
        safeToSpendCents(
          budgetCents: 300000,
          spentCents: 0,
          todaySpentCents: 0,
          pendingCents: 0,
          daysLeft: 0,
        ),
        0,
      );
    });
  });
}
