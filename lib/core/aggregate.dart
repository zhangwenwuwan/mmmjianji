/// 纯函数聚合：预算进度、分类占比、每日流水。
///
/// 单独抽出来是为了能脱离数据库单测——这些算法错了，界面上看不出来，
/// 但用户的钱会算错。
library;

import 'rules.dart';

class DayFlow {
  const DayFlow(
      {required this.day,
      required this.incomeCents,
      required this.expenseCents});

  final DateTime day;
  final int incomeCents;
  final int expenseCents;

  int get netCents => incomeCents - expenseCents;
}

class Slice {
  const Slice({required this.label, required this.cents});

  /// 分类标题（分类被删时用「未分类」）
  final String label;
  final int cents;
}

/// 预算进度。[budgetCents] <= 0 视为未设置。
class BudgetProgress {
  const BudgetProgress({
    required this.budgetCents,
    required this.spentCents,
    required this.daysLeft,
    required this.daysTotal,
  });

  final int budgetCents;
  final int spentCents;
  final int daysLeft;
  final int daysTotal;

  bool get configured => budgetCents > 0;
  int get remainCents => budgetCents - spentCents;
  double get ratio =>
      budgetCents <= 0 ? 0 : (spentCents / budgetCents).clamp(0.0, 1.0);
  bool get overflow => budgetCents > 0 && spentCents > budgetCents;

  /// 按剩余天数均摊的「今天还能花」。已经超支时返回 0，不返回负数。
  int get safeDailyCents {
    if (!configured) return 0;
    if (daysLeft <= 0) return remainCents > 0 ? remainCents : 0;
    final per = remainCents / daysLeft;
    return per <= 0 ? 0 : per.floor();
  }
}

BudgetProgress buildBudgetProgress({
  required int budgetCents,
  required int spentCents,
  required DateTime month,
  required DateTime today,
}) {
  final total = daysInMonth(month);
  final isCurrentMonth = month.year == today.year && month.month == today.month;
  final left = isCurrentMonth ? daysLeftInMonth(today) : 0;
  return BudgetProgress(
    budgetCents: budgetCents,
    spentCents: spentCents,
    daysLeft: left,
    daysTotal: total,
  );
}

/// 分类占比：只保留金额 > 0 的项，按金额降序；[limit] 之外的合并成「其他」。
List<Slice> rankSlices(List<Slice> input,
    {int limit = 5, String otherLabel = '其他'}) {
  final sorted = input.where((s) => s.cents > 0).toList()
    ..sort((a, b) => b.cents.compareTo(a.cents));
  if (sorted.length <= limit) return sorted;
  final head = sorted.take(limit - 1).toList();
  final rest = sorted.skip(limit - 1).fold<int>(0, (sum, s) => sum + s.cents);
  return [...head, Slice(label: otherLabel, cents: rest)];
}

/// 百分比（0..1），总数 <= 0 时返回 0
double shareOf(int part, int total) =>
    total <= 0 ? 0 : (part / total).clamp(0.0, 1.0);

/// 「今日安全可花」：今天还能花多少钱（分，可为负=今天已经花超）。
///
/// 2026-10-25 修过一个真 bug。旧公式是
/// `（预算 − 本月已花 − 待扣周期账单）÷ 剩余天数`，那算出来是**日均值**，
/// 不是"今天还能花多少"——今天花 500 和一分没花，卡片显示的是同一个数，
/// 用户每天记账后看到数字纹丝不动，第一反应就是"这 App 算错了"。
///
/// 正确语义分两步：
/// 1. 剩余预算摊到剩下的每一天（含今天）→ 日均可用；
/// 2. 再减掉**今天已经花掉的** → 今天真正还能花的。
///
/// 为什么可以减：今天少花的额度并没有消失，它只是提前挪到了今天可用；
/// 花超了（返回负数）就该红字提醒，而不是显示一个好看的假数字。
///
/// [daysLeft] 剩余天数，含今天；<=0（非本月视图/月末已过）时返回 0。
int safeToSpendCents({
  required int budgetCents,
  required int spentCents,
  required int todaySpentCents,
  required int pendingCents,
  required int daysLeft,
}) {
  if (budgetCents <= 0 || daysLeft <= 0) return 0;
  final remain = budgetCents - spentCents - pendingCents;
  final daily = remain / daysLeft;
  return (daily - todaySpentCents).floor();
}
