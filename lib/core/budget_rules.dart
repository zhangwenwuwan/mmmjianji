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
