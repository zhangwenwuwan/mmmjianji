import 'dart:math' as math;

/// 贷款还款计划的文案计算（纯函数，可单测）。
///
/// 为什么要有这个文件：这段公式原来长在 `account_edit_page.dart` 的一个
/// getter 里，只有"正在编辑账户"时能看到 —— 保存之后，用户回到账户详情
/// 就再也看不到自己填的利率、期数算了什么。填了看不见，等于没填。
///
/// 现在编辑页和详情页共用同一份口径。**公式只此一份**，
/// 改口径（比如先息后本要不要算复利）只改这里。
class LoanPlan {
  const LoanPlan._();

  /// 还款方式：0 等额本息 / 1 等额本金 / 2 先息后本 / 3 一次性还本付息。
  static const methods = ['等额本息', '等额本金', '先息后本', '一次性还本付息'];

  static String methodName(int method) =>
      (method >= 0 && method < methods.length) ? methods[method] : methods[0];

  /// 生成一句人话摘要。参数不全（没利率/没期数/没本金）返回空串。
  ///
  /// [principalCents] 欠款本金（分）；[annualRatePercent] 年利率百分数（4.2 表示 4.2%）；
  /// [months] 总期数；[symbol] 币种符号，由调用方给（core 层不猜币种）。
  static String summary({
    required int principalCents,
    required double annualRatePercent,
    required int months,
    required int method,
    required String symbol,
  }) {
    if (annualRatePercent <= 0 || months <= 0 || principalCents <= 0) {
      return '';
    }
    final p = principalCents / 100;
    final r = annualRatePercent / 100 / 12;
    final n = months;
    String fmt(double v) => '$symbol${v.toStringAsFixed(2)}';

    switch (method) {
      case 1: // 等额本金
        final first = p / n + p * r;
        final down = p * r / n;
        final totalInterest = p * r * (n + 1) / 2;
        return '等额本金：首月约 ${fmt(first)}，每月递减 ${fmt(down)}，'
            '总利息约 ${fmt(totalInterest)}';
      case 2: // 先息后本
        final monthly = p * r;
        final totalInterest = p * r * n;
        return '先息后本：每月利息约 ${fmt(monthly)}，到期一次还本金 ${fmt(p)}，'
            '总利息约 ${fmt(totalInterest)}';
      case 3: // 一次性还本付息
        // ⚠️ 利息 = 本金 × 年利率 × **年数**。n 是期数（月），
        // 原来直接乘 n，等于把 12 期的利息算成了 12 年 —— 到期金额能翻倍还多。
        final totalInterest = p * annualRatePercent / 100 * (n / 12);
        return '一次性还本付息：到期还约 ${fmt(p + totalInterest)}'
            '（利息 ${fmt(totalInterest)}）';
      default: // 等额本息
        final m = r == 0 ? p / n : p * r * math.pow(1 + r, n) / (math.pow(1 + r, n) - 1);
        final totalInterest = m * n - p;
        return '等额本息：每月约 ${fmt(m)}，总利息约 ${fmt(totalInterest)}';
    }
  }
}
