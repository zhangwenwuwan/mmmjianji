import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/core/rules.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 借贷关联资金账户（1.4.79 新增）。
///
/// 借贷以前是纯台账：借了 1 万，账户余额纹丝不动，用户得手工再记一笔，
/// 两处金额一错就对不上。现在可以在建借贷 / 记还款时选一个账户（**可选**），
/// 系统自动生成一笔流水。
///
/// 三条铁律，错一条账就废了：
///   1. 生成的那笔**不计入收支统计** —— 借钱不是收入、还钱不是消费；
///   2. 删除借贷 / 还款记录时，流水必须一起删（否则余额凭空少一块没人认）；
///   3. 不关联时**什么都不发生**，和旧版本行为完全一致。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('debtpocket');
    store = await LedgerStore.open(path: '${tmp.path}/t.db');
    bookId = (await store.books()).first.id;
  });

  tearDown(() async {
    await store.close();
    await databaseFactory.deleteDatabase('${tmp.path}/t.db');
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<int> addPocket(String title, {String currency = 'CNY'}) async {
    await store.addPocket(
      bookId: bookId,
      title: title,
      glyph: 'ic:acc_cash',
      kind: PocketKind.cash,
      currency: currency,
      openingCents: 0,
    );
    final all = await store.allPockets();
    return all.firstWhere((p) => p.title == title).id;
  }

  Future<int> balanceOf(int pocketId) async {
    for (final b in await store.pocketBalances()) {
      if (b.pocket.id == pocketId) return b.balanceCents;
    }
    return 0;
  }

  Debt debtOf({
    required String direction,
    required int cents,
    int pocketId = 0,
    String currency = 'CNY',
    String counterparty = '老王',
  }) =>
      Debt(
        id: 0,
        bookId: bookId,
        direction: direction,
        counterparty: counterparty,
        channel: 'personal',
        principalCents: cents,
        currency: currency,
        borrowedOn: DateTime(2026, 11, 1),
        dueOn: null,
        note: '',
        interestRate: null,
        closed: false,
        pocketId: pocketId,
      );

  test('借入关联账户：余额增加，但不计入本月收入', () async {
    final cash = await addPocket('现金');
    await store.addDebt(debtOf(
        direction: 'borrow', cents: 100000, pocketId: cash));

    expect(await balanceOf(cash), 100000, reason: '借来的钱要真进账户');

    final month = DateTime(2026, 11, 1);
    final stats = await store.monthTotalsByFlow(bookId, month);
    expect(stats['in'] ?? 0, 0, reason: '借钱不是收入，不能进统计');
    expect(stats['out'] ?? 0, 0);
  });

  test('借出关联账户：余额减少，也不计入支出', () async {
    final cash = await addPocket('现金');
    await store.addPocket(
      bookId: bookId,
      title: '钱包',
      glyph: 'ic:acc_cash',
      kind: PocketKind.cash,
      currency: 'CNY',
      openingCents: 0,
    );
    final wallet =
        (await store.allPockets()).firstWhere((p) => p.title == '钱包').id;
    // 先给钱包放点钱，避免余额变成负数看着怪
    await store.addEntry(
      bookId: bookId,
      pocketId: wallet,
      flow: 'in',
      amountCents: 500000,
      memo: '期初',
      day: DateTime(2026, 11, 1),
    );

    await store.addDebt(
        debtOf(direction: 'lend', cents: 200000, pocketId: wallet));
    expect(await balanceOf(wallet), 300000);

    final stats = await store.monthTotalsByFlow(bookId, DateTime(2026, 11, 1));
    expect(stats['in'] ?? 0, 500000, reason: '只有那笔期初算收入');
    expect(stats['out'] ?? 0, 0, reason: '借出去不是消费');
    expect(await balanceOf(cash), 0);
  });

  test('不关联账户：余额和统计都不动', () async {
    final cash = await addPocket('现金');
    await store.addDebt(debtOf(direction: 'borrow', cents: 88800));

    expect(await balanceOf(cash), 0);
    final stats = await store.monthTotalsByFlow(bookId, DateTime(2026, 11, 1));
    expect(stats['in'] ?? 0, 0);
    final entries = await store.entriesOfDay(bookId, DateTime(2026, 11, 1));
    expect(entries, isEmpty, reason: '不关联就不该凭空多一笔流水');
  });

  test('还款关联账户：借出的收回进账户，借入的还款出账户', () async {
    final cash = await addPocket('现金');
    await store.addPocket(
      bookId: bookId,
      title: '工资卡',
      glyph: 'ic:acc_bank',
      kind: PocketKind.bank,
      currency: 'CNY',
      openingCents: 0,
    );
    final bank =
        (await store.allPockets()).firstWhere((p) => p.title == '工资卡').id;

    // 我借入 1000，进现金
    final borrowId =
        await store.addDebt(debtOf(direction: 'borrow', cents: 100000, pocketId: cash));
    expect(await balanceOf(cash), 100000);

    // 从工资卡还款 400
    await store.addDebtPayment(
      bookId: bookId,
      debtId: borrowId,
      amountCents: 40000,
      paidOn: DateTime(2026, 11, 10),
      pocketId: bank,
    );
    expect(await balanceOf(bank), -40000, reason: '还款从卡里出');

    // 我借出 500 给老王，从现金出；他收回 200 回现金
    final lendId =
        await store.addDebt(debtOf(direction: 'lend', cents: 50000, pocketId: cash));
    expect(await balanceOf(cash), 50000, reason: '1000 借入 − 500 借出');
    await store.addDebtPayment(
      bookId: bookId,
      debtId: lendId,
      amountCents: 20000,
      paidOn: DateTime(2026, 11, 12),
      pocketId: cash,
    );
    expect(await balanceOf(cash), 70000, reason: '收回 200 回到现金');

    final stats = await store.monthTotalsByFlow(bookId, DateTime(2026, 11, 1));
    expect(stats['in'] ?? 0, 0);
    expect(stats['out'] ?? 0, 0);
  });

  test('删除借贷 / 删除还款记录时，关联流水一起删', () async {
    final cash = await addPocket('现金');
    final id =
        await store.addDebt(debtOf(direction: 'borrow', cents: 100000, pocketId: cash));
    await store.addDebtPayment(
      bookId: bookId,
      debtId: id,
      amountCents: 30000,
      paidOn: DateTime(2026, 11, 5),
      pocketId: cash,
    );
    // 借入 1000（+1000），还款 300（−300）
    expect(await balanceOf(cash), 70000);

    final pays = await store.debtPayments(id);
    expect(pays.single.pocketId, cash);
    await store.deleteDebtPayment(pays.single.id);
    expect(await balanceOf(cash), 100000, reason: '删还款记录要把那笔流水收回去');

    await store.deleteDebt(id);
    expect(await balanceOf(cash), 0, reason: '删借贷要把本金那笔也收回');
    expect(await store.pocketBalances().then((v) => v.first.balanceCents), 0);
  });

  test('编辑借贷：改金额 / 换账户 / 取消关联，流水都跟着走', () async {
    final cash = await addPocket('现金');
    await store.addPocket(
      bookId: bookId,
      title: '支付宝',
      glyph: 'ic:acc_alipay',
      kind: PocketKind.bank,
      currency: 'CNY',
      openingCents: 0,
    );
    final ali =
        (await store.allPockets()).firstWhere((p) => p.title == '支付宝').id;

    final id =
        await store.addDebt(debtOf(direction: 'borrow', cents: 100000, pocketId: cash));
    var d = (await store.debts(bookId)).firstWhere((x) => x.id == id);
    expect(d.entryId, greaterThan(0));

    // 改金额
    await store.updateDebt(d.copyWith(principalCents: 123400));
    expect(await balanceOf(cash), 123400);

    // 换账户
    d = (await store.debts(bookId)).firstWhere((x) => x.id == id);
    await store.updateDebt(d.copyWith(pocketId: ali));
    expect(await balanceOf(cash), 0);
    expect(await balanceOf(ali), 123400);

    // 取消关联
    d = (await store.debts(bookId)).firstWhere((x) => x.id == id);
    await store.updateDebt(d.copyWith(pocketId: 0));
    expect(await balanceOf(ali), 0);
    d = (await store.debts(bookId)).firstWhere((x) => x.id == id);
    expect(d.pocketId, 0);
    expect(d.entryId, 0, reason: '取消关联要顺手清掉 entry_id');
    final left = await store.entriesOfDay(bookId, DateTime(2026, 11, 1));
    expect(left.where((e) => e.tags.contains('债务')), isEmpty);
  });

  test('币种不一致直接拒绝，不做静默折算', () async {
    final usd = await addPocket('美元现金', currency: 'USD');
    await expectLater(
      store.addDebt(debtOf(direction: 'borrow', cents: 10000, pocketId: usd)),
      throwsA(isA<StateError>()),
    );
    expect(await balanceOf(usd), 0);
  });

  test('月收支口径：债务流水不算进去，但账户余额认', () async {
    final cash = await addPocket('现金');
    final bucket =
        (await store.buckets(bookId, 'out')).first; // 正常记一笔对照
    final id =
        await store.addDebt(debtOf(direction: 'borrow', cents: 500000, pocketId: cash));
    await store.addDebtPayment(
      bookId: bookId,
      debtId: id,
      amountCents: 100000,
      paidOn: DateTime(2026, 11, 8),
      pocketId: cash,
    );
    await store.addEntry(
      bookId: bookId,
      pocketId: cash,
      bucketId: bucket.id,
      flow: 'out',
      amountCents: 3000,
      memo: '早饭',
      day: DateTime(2026, 11, 9),
    );

    final stats = await store.monthTotalsByFlow(bookId, DateTime(2026, 11, 1));
    expect(stats['out'] ?? 0, 3000, reason: '只有真消费算支出');
    expect(stats['in'] ?? 0, 0);
    expect(await balanceOf(cash), 400000 - 3000);
    expect(dayKey(DateTime(2026, 11, 1)), '2026-11-01');
  });
}
