import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/insight_calc.dart';
import 'package:jianji/data/store.dart';

/// 现金流预测页「当前净资产」的口径回归。
///
/// 曾经的 bug：直接 `net += balanceCents.real`，把「欠 8,000」的信用卡
/// 当成「多了 8,000 资产」，净资产虚高 16,000，30 天预测跟着全偏。
/// 资产页的合计（assets − liabilities）才是唯一正确口径，这里锁死。

Pocket _pocket({
  required int id,
  required PocketKind kind,
  String currency = 'CNY',
  bool includeInAssets = true,
}) =>
    Pocket(
      id: id,
      bookId: 1,
      title: 'p$id',
      glyph: 'wallet',
      kind: kind,
      currency: currency,
      openingCents: 0,
      archived: false,
      includeInAssets: includeInAssets,
    );

void main() {
  test('负债账户从净资产里扣掉，不是加上', () {
    final net = netWorthOfBalances([
      (pocket: _pocket(id: 1, kind: PocketKind.bank), balanceCents: 1000000),
      (pocket: _pocket(id: 2, kind: PocketKind.credit), balanceCents: 800000),
    ], 'CNY', const {});
    // ¥10,000 资产 − ¥8,000 欠款 = ¥2,000
    expect(net, 200000);
  });

  test('欠款超过资产时净资产为负', () {
    final net = netWorthOfBalances([
      (pocket: _pocket(id: 1, kind: PocketKind.cash), balanceCents: 50000),
      (pocket: _pocket(id: 2, kind: PocketKind.debt), balanceCents: 300000),
    ], 'CNY', const {});
    expect(net, -250000);
  });

  test('「不计入总资产」的账户不参与净资产（资产侧）', () {
    final net = netWorthOfBalances([
      (pocket: _pocket(id: 1, kind: PocketKind.bank), balanceCents: 100000),
      (
        pocket: _pocket(
            id: 2, kind: PocketKind.bank, includeInAssets: false),
        balanceCents: 9999999,
      ),
    ], 'CNY', const {});
    expect(net, 100000);
  });

  test('「不计入总资产」的负债也不参与（否则少扣一份欠款）', () {
    final net = netWorthOfBalances([
      (pocket: _pocket(id: 1, kind: PocketKind.bank), balanceCents: 100000),
      (
        pocket: _pocket(
            id: 2, kind: PocketKind.credit, includeInAssets: false),
        balanceCents: 400000,
      ),
    ], 'CNY', const {});
    expect(net, 100000);
  });

  test('外币账户按汇率折算后计入净资产', () {
    // 100 USD 按 7.1 折 = ¥710；负债 100 USD = −¥710
    final net = netWorthOfBalances([
      (
        pocket: _pocket(id: 1, kind: PocketKind.bank, currency: 'USD'),
        balanceCents: 10000,
      ),
      (
        pocket: _pocket(id: 2, kind: PocketKind.credit, currency: 'USD'),
        balanceCents: 10000,
      ),
    ], 'CNY', const {'USD': 7.1});
    expect(net, 0);
  });

  test('空账户列表 → 0', () {
    expect(netWorthOfBalances(const [], 'CNY', const {}), 0);
  });
}
