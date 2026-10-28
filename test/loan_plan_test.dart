import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/loan.dart';

/// 贷款还款计划的口径测试。
///
/// 为什么值得单独测：这段文案原来只活在编辑页的 getter 里，
/// 算错了界面上照样"有模有样"—— 用户拿它去和银行对账才发现差钱。
void main() {
  const sym = '¥';

  group('参数不全', () {
    test('没利率 / 没期数 / 没本金 一律返回空串（不显示那一块）', () {
      expect(
          LoanPlan.summary(
              principalCents: 100000,
              annualRatePercent: 0,
              months: 12,
              method: 0,
              symbol: sym),
          '');
      expect(
          LoanPlan.summary(
              principalCents: 100000,
              annualRatePercent: 4.2,
              months: 0,
              method: 0,
              symbol: sym),
          '');
      expect(
          LoanPlan.summary(
              principalCents: 0,
              annualRatePercent: 4.2,
              months: 12,
              method: 0,
              symbol: sym),
          '');
    });
  });

  group('等额本金', () {
    test('首月 = 本金/期数 + 本金×月利率，递减额与总利息对得上', () {
      // 本金 1200 元、年利率 12%（月利率 1%）、12 期
      // 首月 = 100 + 12 = 112；递减 = 1200×0.01/12 = 1；总利息 = 1200×0.01×13/2 = 78
      final s = LoanPlan.summary(
        principalCents: 120000,
        annualRatePercent: 12,
        months: 12,
        method: 1,
        symbol: sym,
      );
      expect(s.contains('${sym}112.00'), isTrue, reason: s);
      expect(s.contains('${sym}1.00'), isTrue, reason: s);
      expect(s.contains('${sym}78.00'), isTrue, reason: s);
    });
  });

  group('先息后本', () {
    test('每月只还利息，总利息 = 本金×年利率×年数', () {
      final s = LoanPlan.summary(
        principalCents: 120000,
        annualRatePercent: 12,
        months: 12,
        method: 2,
        symbol: sym,
      );
      // 每月 12 元，总利息 144 元，到期还本金 1200
      expect(s.contains('${sym}12.00'), isTrue, reason: s);
      expect(s.contains('${sym}144.00'), isTrue, reason: s);
      expect(s.contains('${sym}1200.00'), isTrue, reason: s);
    });
  });

  group('一次性还本付息', () {
    test('利息按「年利率 × 年数」算，不按期数', () {
      // 12 期 = 1 年 → 利息 1200×12% = 144，到期 1344
      final s = LoanPlan.summary(
        principalCents: 120000,
        annualRatePercent: 12,
        months: 12,
        method: 3,
        symbol: sym,
      );
      expect(s.contains('${sym}1344.00'), isTrue, reason: s);
      expect(s.contains('${sym}144.00'), isTrue, reason: s);
      // 老写法把月数当年数，会算成 1200×0.12×12 = 1728，到期 2928 —— 差一倍
      expect(s.contains('${sym}2928.00'), isFalse, reason: s);
    });

    test('24 期 = 2 年，利息翻倍', () {
      final s = LoanPlan.summary(
        principalCents: 120000,
        annualRatePercent: 12,
        months: 24,
        method: 3,
        symbol: sym,
      );
      expect(s.contains('${sym}288.00'), isTrue, reason: s);
    });
  });

  group('等额本息', () {
    test('1 期时本金+利息，可精确断言', () {
      // 1000 元、年利率 12%（月 1%）、1 期 → 1010
      final s = LoanPlan.summary(
        principalCents: 100000,
        annualRatePercent: 12,
        months: 1,
        method: 0,
        symbol: sym,
      );
      expect(s.contains('${sym}1010.00'), isTrue, reason: s);
      expect(s.contains('总利息约 ${sym}10.00'), isTrue, reason: s);
    });

    test('总利息随期数增长，但小于「本金×年利率×年数」的两倍', () {
      final s = LoanPlan.summary(
        principalCents: 10000000, // 10 万元
        annualRatePercent: 4.8,
        months: 240, // 20 年
        method: 0,
        symbol: sym,
      );
      expect(s.contains('等额本息'), isTrue);
      expect(s.contains('每月约'), isTrue);
    });
  });

  test('还款方式名称与下标对应', () {
    expect(LoanPlan.methodName(0), '等额本息');
    expect(LoanPlan.methodName(1), '等额本金');
    expect(LoanPlan.methodName(2), '先息后本');
    expect(LoanPlan.methodName(3), '一次性还本付息');
    // 越界不崩
    expect(LoanPlan.methodName(99), '等额本息');
  });
}
