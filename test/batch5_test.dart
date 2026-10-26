import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 第 5 批回归：搜索合计不被 LIMIT 截断 / 预算口径 / 借贷到期日清除。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;
  late int pocketId;
  late int bucketId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-b5-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
    pocketId = (await store.allPockets(includeArchived: false)).first.id;
    bucketId = (await store.buckets(bookId, 'out')).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  group('搜索合计', () {
    test('命中超过 300 条时，合计仍然是全量（列表仍只回 300）', () async {
      // 320 笔，每笔 1 元
      for (var i = 0; i < 320; i++) {
        await store.addEntry(
          bookId: bookId,
          pocketId: pocketId,
          bucketId: bucketId,
          flow: 'out',
          amountCents: 100,
          memo: '咖啡 $i',
          day: DateTime(2026, 10, 21),
          tags: '',
        );
      }
      final list = await store.searchEntriesEx(bookId, keyword: '咖啡');
      expect(list.length, 300, reason: '列表仍然有上限，避免一次拉爆');

      final totals = await store.searchTotals(bookId, keyword: '咖啡');
      final out = totals.where((t) => t.flow == 'out').fold<int>(0, (s, t) => s + t.cents);
      expect(out, 320 * 100,
          reason: '合计必须覆盖全部 320 笔，不能只算前 300 笔');
    });

    test('合计排除「不计入收支」，与首页口径一致', () async {
      await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        bucketId: bucketId,
        flow: 'out',
        amountCents: 500,
        memo: '算的',
        day: DateTime(2026, 10, 21),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        bucketId: bucketId,
        flow: 'out',
        amountCents: 800,
        memo: '不算的',
        day: DateTime(2026, 10, 21),
        excludeFromStats: true,
      );
      final totals = await store.searchTotals(bookId);
      final out = totals.where((t) => t.flow == 'out').fold<int>(0, (s, t) => s + t.cents);
      expect(out, 500, reason: '勾了「不计入收支」的笔不能进合计');
    });

    test('合计的筛选条件和列表完全一致（换 flow 就变）', () async {
      await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        bucketId: bucketId,
        flow: 'out',
        amountCents: 300,
        memo: 'x',
        day: DateTime(2026, 10, 21),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        bucketId: null,
        flow: 'in',
        amountCents: 900,
        memo: 'x',
        day: DateTime(2026, 10, 21),
      );
      final out = await store.searchTotals(bookId, flow: 'out');
      final inn = await store.searchTotals(bookId, flow: 'in');
      expect(out.single.cents, 300);
      expect(inn.single.cents, 900);
    });
  });

  group('预算口径', () {
    test('排除「不计入预算」，且跨币种逐笔折算', () async {
      // 主币 CNY，给账本加一个 USD 账户
      await store.addPocket(
        bookId: bookId,
        title: '美元账户',
        glyph: r'$',
        kind: PocketKind.cash,
        currency: 'USD',
        openingCents: 0,
      );
      // addPocket 返回 void，id 要回查
      final usd = (await store.allPockets(includeArchived: false))
          .firstWhere((p) => p.title == '美元账户')
          .id;
      await store.setRate(bookId, 'USD', 7.0);

      await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        bucketId: bucketId,
        flow: 'out',
        amountCents: 1000,
        memo: '算预算',
        day: DateTime(2026, 10, 21),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        bucketId: bucketId,
        flow: 'out',
        amountCents: 2000,
        memo: '不算预算',
        day: DateTime(2026, 10, 21),
        excludeFromBudget: true,
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: usd,
        bucketId: bucketId,
        flow: 'out',
        amountCents: 100,
        memo: '美元支出',
        day: DateTime(2026, 10, 21),
        currency: 'USD',
      );

      final book = (await store.books()).first;
      final spent = await budgetSpentOf(store, book, DateTime(2026, 10));
      // 1000 + 100 USD × 7 = 1000 + 700 = 1700；那笔 2000 被排除
      expect(spent, 1700);
      expect(book.baseCurrency, 'CNY');
    });
  });

  group('借贷到期日', () {
    test('clearDueOn 能真正清掉（copyWith 不再吃 null）', () async {
      await store.addDebt(Debt(
        id: 0,
        bookId: bookId,
        direction: 'lend',
        counterparty: '张三',
        channel: '现金',
        principalCents: 10000,
        currency: 'CNY',
        borrowedOn: DateTime(2026, 10, 1),
        dueOn: DateTime(2026, 11, 1),
        note: '',
        interestRate: null,
        closed: false,
      ));
      final before = (await store.debts(bookId)).first;
      expect(before.dueOn, DateTime(2026, 11, 1));

      await store.updateDebt(before.copyWith(clearDueOn: true));
      final after = (await store.debts(bookId)).first;
      expect(after.dueOn, isNull, reason: '清空到期日必须写进库');

      // 反过来：传具体日期仍然生效
      await store.updateDebt(after.copyWith(dueOn: DateTime(2026, 12, 25)));
      expect((await store.debts(bookId)).first.dueOn, DateTime(2026, 12, 25));
    });
  });
}
