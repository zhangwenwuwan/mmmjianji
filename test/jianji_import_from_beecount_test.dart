import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 端到端：把 **BeeCount 真实导出的那份 JSON** 灌进简记，确认能进库、口径对。
///
/// fixture 来源：BeeCount 的 `test/jianji_export_test.dart` 里
/// `JianjiExport.mapRows(fixtureRows())` 的产物（原样拷贝，没手改）。
/// 这条链一旦断了（比如简记加了列、BeeCount 那边改了映射），这里会先红，
/// 而不是等用户拿真数据导入时才发现「导入失败」。
void main() {
  late Directory tmp;
  late LedgerStore store;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-from-bc-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  test('能导入 BeeCount 导出的整库 JSON', () async {
    final raw =
        File('test/fixtures/jianji_from_beecount.json').readAsStringSync();

    await store.importJson(raw);

    // ---- 账本 ----
    final books = await store.books();
    expect(books.length, 1);
    expect(books.first.title, '我的账本');
    final bookId = books.first.id;

    // ---- 账户：kind / 负债符号 / 额度 / 账单日 ----
    final pockets = await store.allPockets(includeArchived: true);
    expect(pockets.length, 3, reason: '三个账户搬过来，不该多出占位账户');

    final cash = pockets.firstWhere((p) => p.title == '现金');
    expect(cash.kind, PocketKind.cash);
    expect(cash.openingCents, 10050);

    final bank = pockets.firstWhere((p) => p.title == '招行储蓄卡');
    expect(bank.kind, PocketKind.bank);

    final credit = pockets.firstWhere((p) => p.title == '招行信用卡');
    expect(credit.kind, PocketKind.credit);
    expect(credit.kind.isLiability, isTrue);
    expect(credit.openingCents, 80000, reason: '简记：负债正数=还欠多少');
    expect(credit.creditLimitCents, 2000000);
    expect(credit.billingDay, 5);
    expect(credit.paymentDueDay, 23);

    // ---- 分类：3 个，父子关系还在，flow 是 in/out ----
    final outBuckets = await store.buckets(bookId, 'out');
    final inBuckets = await store.buckets(bookId, 'in');
    expect(outBuckets.length, 2); // 餐饮 / 外卖
    expect(inBuckets.length, 1); // 工资
    final parent = outBuckets.firstWhere((b) => b.title == '餐饮');
    final child = outBuckets.firstWhere((b) => b.title == '外卖');
    expect(child.parentId, parent.id);

    // ---- 流水：2 笔，转账的两个账户都在 ----
    final entries = await store.entriesOfMonth(bookId, DateTime(2026, 10));
    expect(entries.length, 2);
    final lunch = entries.firstWhere((e) => e.memo == '午饭');
    expect(lunch.isExpense, isTrue);
    expect(lunch.amountCents, 3250);
    final transfer = entries.firstWhere((e) => e.isTransfer);
    expect(transfer.amountCents, 50000);
    expect(transfer.toPocketId, isNotNull);

    // ---- 余额算出来对不对（这条最能证明"账没记歪"）----
    final balances = {
      for (final b in await store.pocketBalances()) b.pocket.title: b.balanceCents
    };
    // 现金：期初 100.5 − 午饭 32.5 + 转账转入 500 = 568
    expect(balances['现金'], 56800);
    // 储蓄卡：期初 2500 − 转出 500 = 2000
    expect(balances['招行储蓄卡'], 200000);
    // 信用卡：欠 800，没有流水
    expect(balances['招行信用卡'], 80000);

    // ---- 借贷 + 还款 ----
    final debts = await store.debts(bookId, includeClosed: true);
    expect(debts.length, 1);
    final debt = debts.single;
    expect(debt.direction, 'borrow');
    expect(debt.counterparty, '招商银行');
    expect(debt.channel, 'bank');
    expect(debt.principalCents, 5000000);
    expect(debt.interestRate, 4.35);
    expect(debt.closed, isFalse);

    final pays = await store.debtPayments(debt.id);
    expect(pays.length, 1, reason: '只有已确认还款的月份才搬');
    expect(pays.single.amountCents, 216600);
  });

  test('不是简记备份的文件会被拒绝（防止误导入）', () async {
    expect(
      () => store.importJson('{"app":"beecount","books":[]}'),
      throwsA(isA<FormatException>()),
    );
  });
}
