/// 预算结转规则。
///
/// 为什么单独抽一个文件：这是**纯函数**，能直接单测。预算算错是记账 App
/// 里最容易被用户发现、也最伤信任的一类 bug（「我明明设了 3000，怎么显示
/// 2600」），而它又完全靠四则运算，没有理由不钉死。
///
/// 语义（对齐一木记账的「自动沿用」）：
/// - 上月没设预算 → 不结转、也不倒扣。不能因为用户上个月忘了设预算，
///   这个月就凭空多出一笔"超支"，那是惩罚。
/// - 只开「多余累加」→ 只结转正数（省下的），超支不带过来。
/// - 只开「超额扣除」→ 只结转负数（超支），省下的不带过来。
/// - 两个都开 → 结转为带符号的差额，省下的和超支的都会滚到本期。
library;

/// 计算上期结转到本期的金额（分，可为负）。
///
/// [prevBudget] 上期预算（0 = 上期没设）
/// [prevSpent] 上期实际支出
int budgetCarryCents({
  required int prevBudget,
  required int prevSpent,
  required bool addUnused,
  required bool deductOver,
}) {
  // 上期没设预算：什么都不结转。注意这里**不能**用 prevSpent 判断，
  // 否则「上期没预算但花了很多」会被当成超支倒扣本期。
  if (prevBudget <= 0) return 0;
  if (!addUnused && !deductOver) return 0;

  final delta = prevBudget - prevSpent;

  if (addUnused && deductOver) return delta;
  if (addUnused) return delta > 0 ? delta : 0;
  return delta < 0 ? delta : 0;
}

/// 本期可用预算 = 基础预算 + 结转，且不低于 0。
///
/// 为什么会是负数：上月超支很严重时，扣完本期预算还会剩一截负数。
/// 显示「-500 可用」对用户没有意义，所以夹到 0，同时由
/// [overFromPrevCents] 告诉 UI「还欠着多少」。
int effectiveBudgetCents({required int base, required int carry}) {
  final v = base + carry;
  return v < 0 ? 0 : v;
}

/// 结转扣不完、仍然欠着的部分（0 表示没欠）。只用于提示。
int overFromPrevCents({required int base, required int carry}) {
  final v = base + carry;
  return v < 0 ? -v : 0;
}

// ---------------------------------------------------------------------------
// 智能建议（2026-11-09）：给「设多少」一个数字锚点，而不是让用户对着空框发呆。
// 全部是纯函数：给输入出数字，不查库、不改状态。
// ---------------------------------------------------------------------------

/// 按近几个月的消费算建议预算（分）。
///
/// [recentSpents] 填近 3 个月的实际支出（0 = 那个月没消费）。
/// 规则：只平均**有消费**的月份（没消费的月份拉低平均值，
/// 会建议出一个明显不够花的数字）；全没消费 → 0（没有历史就不建议）。
/// 平均值向上取整到整百元 —— 预算是心理锚点，「3217 元」这种精确数
/// 没有锚定价值，「3200」才有；向上是为了不建议出「必然超支」的数。
int suggestBudgetCents(List<int> recentSpents) {
  final valid = recentSpents.where((s) => s > 0).toList();
  if (valid.isEmpty) return 0;
  final avg = valid.reduce((a, b) => a + b) ~/ valid.length;
  if (avg <= 0) return 0;
  const step = 10000; // 整百元
  return (avg + step - 1) ~/ step * step;
}

/// 把总预算按消费比例分到各分类（最大余数法）。
///
/// [spentByBucket] 各分类近 3 个月的消费（分，按账本主币折算）。
/// 规则：
/// - 消费为 0 的分类不参与（给没花钱的分类设预算只会让进度条全绿，没有意义）；
/// - 分摊结果去掉 0 和负数（比例极小的分类宁可不给，别建 0 元预算行）；
/// - 最大余数法保证 Σ结果 == total（四舍五入做不到）。
Map<int, int> proportionalSplitCents(int total, Map<int, int> spentByBucket) {
  final parts = spentByBucket.entries.where((e) => e.value > 0).toList();
  if (total <= 0 || parts.isEmpty) return const {};
  final sum = parts.fold<int>(0, (a, e) => a + e.value);
  if (sum <= 0) return const {};

  final exact = <int, double>{};
  final floor = <int, int>{};
  for (final e in parts) {
    final v = total * e.value / sum;
    exact[e.key] = v;
    floor[e.key] = v.floor();
  }
  // 剩下的分（floor 丢掉的小数部分合计，最多 parts.length 分）
  var remainder = total - floor.values.fold(0, (a, b) => a + b);
  // 余数给小数部分最大的；小数部分相同给消费大的（多花的分类多拿一点）
  final order = [...parts]..sort((a, b) {
      final fa = exact[a.key]! - floor[a.key]!;
      final fb = exact[b.key]! - floor[b.key]!;
      final cmp = fb.compareTo(fa);
      if (cmp != 0) return cmp;
      return b.value.compareTo(a.value);
    });
  final result = {...floor};
  for (final e in order) {
    if (remainder <= 0) break;
    result[e.key] = result[e.key]! + 1;
    remainder--;
  }
  result.removeWhere((_, v) => v <= 0);
  return result;
}
