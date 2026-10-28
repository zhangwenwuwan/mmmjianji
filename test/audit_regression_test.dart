import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 2026-10-27 全量审计修掉的 5 个坑的回归测试。
///
/// 每一条都对应一个「界面上看不出来、但对账会对不上」的错误，
/// 靠肉眼发现不了，只能靠断言钉住。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-audit-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  test('「不计入总资产」的账户仍要能取到余额，不能整条被过滤', () async {
    await store.addPocket(
      bookId: bookId,
      title: '不想算进净资产',
      glyph: '👛',
      kind: PocketKind.cash,
      currency: 'CNY',
      openingCents: 10000,
      includeInAssets: false,
    );
    final p = (await store.allPockets()).firstWhere((x) => x.title == '不想算进净资产');
    await store.addEntry(
      bookId: bookId,
      pocketId: p.id,
      flow: 'out',
      amountCents: 2500,
      memo: '',
      day: DateTime(2026, 10, 20),
    );

    final rows = await store.pocketBalances();
    final row = rows.where((b) => b.pocket.id == p.id).toList();
    // 原来 pocketBalances 直接 where(includeInAssets)，这里会空 →
    // 账户详情回退到期初，之后所有流水都不体现
    expect(row.length, 1, reason: '不计入总资产的账户也必须返回余额');
    expect(row.first.balanceCents, 7500);

    // 但汇总侧必须排除它（真正的"不计入"语义在调用方）
    expect(p.includeInAssets, isFalse);
  });

  test('账户月度合计跨账本（和全局余额同口径）', () async {
    final p = (await store.allPockets()).first;
    final book2 = await store.addBook('第二本', '📗', 'CNY');
    await store.addEntry(
      bookId: bookId,
      pocketId: p.id,
      flow: 'out',
      amountCents: 1000,
      memo: '账本一',
      day: DateTime(2026, 10, 5),
    );
    await store.addEntry(
      bookId: book2,
      pocketId: p.id,
      flow: 'out',
      amountCents: 2000,
      memo: '账本二',
      day: DateTime(2026, 10, 6),
    );

    final t = await store.pocketMonthTotals(p.id, DateTime(2026, 10));
    // 原来带了 e.book_id = ? → 只算 1000，而余额是全量的
    expect(t.outCents, 3000);
  });

  test('清空数据会带走月度总结', () async {
    await store.setMonthNote(bookId, DateTime(2026, 10), '十月总结');
    expect(await store.monthNote(bookId, DateTime(2026, 10)), '十月总结');

    await store.wipe();

    final nb = (await store.books()).first.id;
    // 老库的 summary 不会跟到新账本上，但行如果留着就会被下一份备份带出去
    expect(await store.monthNote(nb, DateTime(2026, 10)), '');
  });

  test('删除账本会带走该账本的月度总结', () async {
    final b2 = await store.addBook('待删', '📗', 'CNY');
    await store.setMonthNote(b2, DateTime(2026, 10), '这本要删了');
    await store.deleteBook(b2);
    expect(await store.monthNote(b2, DateTime(2026, 10)), '');
  });

  test('账户还有启用中的周期记账时不许删', () async {
    final p = (await store.allPockets()).first;
    await store.addRecurring(Recurring(
      id: 0,
      bookId: bookId,
      title: '房租',
      bucketId: null,
      pocketId: p.id,
      flow: 'out',
      amountCents: 300000,
      dayOfMonth: 1,
      lastRunMonth: '',
      enabled: true,
    ));

    // 没有流水 → 老逻辑会放行，然后模板到期生成一笔指向已删账户的流水
    await expectLater(
      store.deletePocketIfEmpty(p.id),
      throwsA(isA<StateError>()),
    );
  });

  test('标签筛选是整串匹配，不做子串误伤', () async {
    final p = (await store.allPockets()).first;
    await store.addEntry(
      bookId: bookId,
      pocketId: p.id,
      flow: 'out',
      amountCents: 100,
      memo: 'A',
      day: DateTime(2026, 10, 1),
      tags: '出差',
    );
    await store.addEntry(
      bookId: bookId,
      pocketId: p.id,
      flow: 'out',
      amountCents: 200,
      memo: 'B',
      day: DateTime(2026, 10, 2),
      tags: '出差报销',
    );

    final hit = await store.searchEntriesEx(bookId, tags: ['出差']);
    // 老写法 LIKE '%出差%' 会把「出差报销」也捞进来 → 和标签详情页金额对不上
    expect(hit.length, 1);
    expect(hit.first.tags, '出差');
  });
}
