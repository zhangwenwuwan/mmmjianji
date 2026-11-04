import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/ui/editor_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 两个用户反馈的回归：
///   1. 信用卡在「选账户」里把**欠款**写成了「余额」（金额对、说法错，看着像算错账）
///   2. 「月度总结」只读手写总结，没写过总结的月份一片空白 —— 用户以为
///      上月账单归档后找不到入口。现在数据源是「有流水的月份」。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;
  late int cashId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-archive-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
    cashId = (await store.allPockets(includeArchived: false)).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  /// 建一张信用卡并返回它的余额行（含 pocket）。
  Future<({Pocket pocket, int balanceCents})> creditCard({
    required String title,
    int limitCents = 0,
  }) async {
    await store.addPocket(
      bookId: bookId,
      title: title,
      glyph: '💳',
      kind: PocketKind.credit,
      currency: 'CNY',
      openingCents: 0,
      creditLimitCents: limitCents,
    );
    final id = (await store.allPockets(includeArchived: true))
        .firstWhere((p) => p.title == title)
        .id;
    return (await store.pocketBalances()).firstWhere((b) => b.pocket.id == id);
  }

  group('账户金额的说法', () {
    test('普通账户叫「余额」，信用卡叫「欠款」', () async {
      final cash = (await store.pocketBalances())
          .firstWhere((b) => b.pocket.id == cashId);
      expect(cash.pocket.kind.isLiability, isFalse);
      expect(pocketAmountLabel(cash.pocket, 123450), '余额 1,234.5');

      final card = await creditCard(title: '测试信用卡');
      expect(card.pocket.kind.isLiability, isTrue,
          reason: '负债账户的 balanceCents 是「欠多少」，写成余额会让用户以为账错了');
      expect(pocketAmountLabel(card.pocket, 123450), '欠款 1,234.5');
    });

    test('信用卡有额度时显示「可用额度」，不是欠款', () async {
      // 额度 3000，已欠 1200 → 可用 1800。用户选账户时关心的是"还能刷多少"。
      final card = await creditCard(title: '有额度卡', limitCents: 300000);
      expect(pocketAmountLabel(card.pocket, 120000), '可用 1,800');

      // 超限：可用算出来是负数，要说「超限」而不是「可用 -200」
      expect(pocketAmountLabel(card.pocket, 320000), '超限 200');
    });

    test('信用卡刷一笔后欠款为正数', () async {
      final card = await creditCard(title: '测试信用卡2');
      await store.addEntry(
        bookId: bookId,
        pocketId: card.pocket.id,
        flow: 'out',
        amountCents: 5200,
        memo: '午饭',
        day: DateTime(2026, 10, 12),
      );
      final row = (await store.pocketBalances())
          .firstWhere((b) => b.pocket.id == card.pocket.id);
      expect(row.balanceCents, 5200, reason: '欠款 52 元，不是 -52');
      expect(pocketAmountLabel(row.pocket, row.balanceCents), '欠款 52');
    });
  });

  group('月度归档的数据源', () {
    test('有流水的月份都会列出来，按月倒序，数字和月报同口径', () async {
      await store.addEntry(
        bookId: bookId,
        pocketId: cashId,
        flow: 'out',
        amountCents: 10000,
        memo: '十月支出',
        day: DateTime(2026, 10, 3),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: cashId,
        flow: 'in',
        amountCents: 80000,
        memo: '十月收入',
        day: DateTime(2026, 10, 5),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: cashId,
        flow: 'out',
        amountCents: 2000,
        memo: '九月支出',
        day: DateTime(2026, 9, 20),
      );

      final months = await store.monthsWithData(bookId);
      expect([for (final m in months) m.month], ['2026-10', '2026-09']);
      expect(months.first.incomeCents, 80000);
      expect(months.first.expenseCents, 10000);
      expect(months.first.count, 2);
      expect(months[1].expenseCents, 2000);
    });

    test('AA 分摊只算我的份额；「不计入收支」的流水不算', () async {
      await store.addEntry(
        bookId: bookId,
        pocketId: cashId,
        flow: 'out',
        amountCents: 10000,
        splitCents: 4000,
        memo: 'AA 代付',
        day: DateTime(2026, 10, 8),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: cashId,
        flow: 'out',
        amountCents: 99999,
        memo: '不计入收支',
        day: DateTime(2026, 10, 8),
        excludeFromStats: true,
      );

      final oct = (await store.monthsWithData(bookId)).first;
      expect(oct.expenseCents, 6000, reason: '10 元里别人承担 4 元，只算 6 元');
      expect(oct.count, 1);
    });

    test('回收站里的流水不算进归档', () async {
      final id = await store.addEntry(
        bookId: bookId,
        pocketId: cashId,
        flow: 'out',
        amountCents: 5000,
        memo: '待删除',
        day: DateTime(2026, 10, 9),
      );
      await store.deleteEntry(id);
      expect(await store.monthsWithData(bookId), isEmpty);
    });
  });
}
