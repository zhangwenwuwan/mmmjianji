import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 统计新增的两个维度：标签汇总 / 账户汇总。
///
/// 重点钉住两件容易出错的事：
/// 1. **多标签账单会在每个标签下各计一次**（这是设计，不是 bug），
///    所以这里是"刻意"让合计大于总额，别被后来的"优化"改成去重；
/// 2. 转账和「不计入统计」必须被排除，否则统计页会莫名多出钱。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;
  late int cashId;
  late int cardId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-dims-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
    final pockets = await store.allPockets(includeArchived: false);
    cashId = pockets.first.id;
    await store.addPocket(
      bookId: bookId,
      title: '外币卡',
      glyph: '💳',
      kind: PocketKind.bank,
      currency: 'USD',
      openingCents: 0,
    );
    cardId =
        (await store.allPockets(includeArchived: false)).firstWhere((p) => p.title == '外币卡').id;

    final day = DateTime(2026, 10, 10);
    // A：双标签（出差 + 报销），现金 100 元
    await store.addEntry(
      bookId: bookId,
      pocketId: cashId,
      flow: 'out',
      amountCents: 10000,
      memo: '机票',
      day: day,
      tags: '出差,报销',
    );
    // B：单标签（出差），现金 50 元
    await store.addEntry(
      bookId: bookId,
      pocketId: cashId,
      flow: 'out',
      amountCents: 5000,
      memo: '打车',
      day: day,
      tags: '出差',
    );
    // C：外币 20 美元，无标签
    await store.addEntry(
      bookId: bookId,
      pocketId: cardId,
      flow: 'out',
      amountCents: 2000,
      memo: '咖啡',
      day: day,
    );
    // D：不计入统计（有标签，但必须被统计排除）
    await store.addEntry(
      bookId: bookId,
      pocketId: cashId,
      flow: 'out',
      amountCents: 9900,
      memo: '内部转账测试',
      day: day,
      tags: '出差',
      excludeFromStats: true,
    );
    // E：转账（flow=transfer，不该进支出统计）
    await store.addEntry(
      bookId: bookId,
      pocketId: cashId,
      toPocketId: cardId,
      flow: 'transfer',
      amountCents: 30000,
      memo: '还款',
      day: day,
      tags: '出差',
    );
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  group('tagSpent', () {
    test('一笔多标签会在每个标签下各计一次（设计如此）', () async {
      final rows = await store.tagSpent(bookId, DateTime(2026, 10));
      final chuchai =
          rows.where((r) => r.tag == '出差').fold<int>(0, (s, r) => s + r.cents);
      final baoxiao =
          rows.where((r) => r.tag == '报销').fold<int>(0, (s, r) => s + r.cents);
      // 出差 = A(10000) + B(5000)；D/E 被排除
      expect(chuchai, 15000);
      // 报销 = A(10000)
      expect(baoxiao, 10000);
    });

    test('标签合计大于当月总支出是正常的（同一笔被计两次）', () async {
      final rows = await store.tagSpent(bookId, DateTime(2026, 10));
      final sum = rows.fold<int>(0, (s, r) => s + r.cents);
      // 当月真实支出 = 10000 + 5000 + 2000(USD) = 17000，标签合计 25000
      expect(sum, greaterThan(17000));
    });

    test('排除转账与「不计入统计」', () async {
      final rows = await store.tagSpent(bookId, DateTime(2026, 10));
      // 如果 D(9900) 或 E(30000) 被算进来，出差会远大于 15000
      final chuchai =
          rows.where((r) => r.tag == '出差').fold<int>(0, (s, r) => s + r.cents);
      expect(chuchai, 15000);
      expect(rows.every((r) => r.cents != 30000), isTrue);
    });

    test('不同币种分行返回，不混加', () async {
      await store.addEntry(
        bookId: bookId,
        pocketId: cardId,
        flow: 'out',
        amountCents: 700,
        memo: '小费',
        day: DateTime(2026, 10, 11),
        tags: '出差',
      );
      final rows = await store.tagSpent(bookId, DateTime(2026, 10));
      final byCurrency = {
        for (final r in rows.where((r) => r.tag == '出差'))
          r.currency: r.cents
      };
      expect(byCurrency['CNY'], 15000);
      expect(byCurrency['USD'], 700);
    });

    test('空标签的账单不产生任何行', () async {
      final rows = await store.tagSpent(bookId, DateTime(2026, 10));
      expect(rows.any((r) => r.tag.trim().isEmpty), isFalse);
    });

    test('没有数据的月份返回空', () async {
      expect(await store.tagSpent(bookId, DateTime(2025, 1)), isEmpty);
    });
  });

  group('pocketSpent', () {
    test('按账户分组，含外币账户', () async {
      final rows = await store.pocketSpent(bookId, DateTime(2026, 10));
      final cash = rows
          .where((r) => r.pocketId == cashId)
          .fold<int>(0, (s, r) => s + (r.currency == 'CNY' ? r.cents : 0));
      expect(cash, 15000); // A + B，D 被排除
      final usd = rows.where((r) => r.pocketId == cardId).toList();
      expect(usd.length, 1);
      expect(usd.first.currency, 'USD');
      expect(usd.first.cents, 2000);
    });

    test('转账不计入账户支出', () async {
      final rows = await store.pocketSpent(bookId, DateTime(2026, 10));
      final total = rows.fold<int>(0, (s, r) => s + r.cents);
      // 10000 + 5000 + 2000 = 17000；若把转账 30000 算进来会明显更大
      expect(total, 17000);
    });

    test('没有数据的月份返回空', () async {
      expect(await store.pocketSpent(bookId, DateTime(2025, 1)), isEmpty);
    });
  });
}
