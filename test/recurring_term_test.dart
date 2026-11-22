import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 周期账单的「开始时间 / 结束方式」（1.4.81，DB v29）。
///
/// 三条边界最容易写错，各钉一条：
///   1. `count`：跑满次数必须真的停（并且把开关关掉，别让列表里挂着一条僵尸规则）；
///   2. `until`：结束日之后的那一期不能再生成；
///   3. `startOn`：起始日之前**不补记** —— 11-20 建的「每月 5 号」，
///      第一次应该是 12-05，而不是把 11-05 补出来。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;
  late int pocketId;
  late int bucketId;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('recterm');
    store = await LedgerStore.open(path: '${tmp.path}/t.db');
    bookId = (await store.books()).first.id;
    await store.addPocket(
      bookId: bookId,
      title: '现金',
      glyph: 'ic:acc_cash',
      kind: PocketKind.cash,
      currency: 'CNY',
      openingCents: 0,
    );
    pocketId = (await store.allPockets()).first.id;
    bucketId = (await store.buckets(bookId, 'out')).first.id;
  });

  tearDown(() async {
    await store.close();
    await databaseFactory.deleteDatabase('${tmp.path}/t.db');
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<int> addRule({
    required String lastRunMonth,
    int dayOfMonth = 5,
    DateTime? startOn,
    String endMode = 'never',
    int endCount = 0,
    DateTime? endOn,
  }) async {
    await store.addRecurring(Recurring(
      id: 0,
      bookId: bookId,
      title: '房租',
      bucketId: bucketId,
      pocketId: pocketId,
      flow: 'out',
      amountCents: 100000,
      dayOfMonth: dayOfMonth,
      lastRunMonth: lastRunMonth,
      enabled: true,
      startOn: startOn,
      endMode: endMode,
      endCount: endCount,
      endOn: endOn,
    ));
    return (await store.recurrings(bookId)).last.id;
  }

  Future<Recurring> rule(int id) async =>
      (await store.recurrings(bookId)).firstWhere((r) => r.id == id);

  test('永不结束：老行为不变，按月补齐', () async {
    await addRule(lastRunMonth: '2025-12');
    final n = await store.applyDueRecurring(bookId, DateTime(2026, 3, 10));
    expect(n, 3, reason: '1/2/3 月各一笔');
    final r = await rule((await store.recurrings(bookId)).last.id);
    expect(r.enabled, isTrue);
    expect(r.lastRunMonth, '2026-03');
  });

  test('执行 N 次：跑满就停，并且自动关闭开关', () async {
    final id = await addRule(
      lastRunMonth: '2025-12',
      endMode: 'count',
      endCount: 2,
    );
    final n = await store.applyDueRecurring(bookId, DateTime(2026, 5, 10));
    expect(n, 2, reason: '只允许两次，哪怕已经过了 5 个月');

    final r = await rule(id);
    expect(r.runCount, 2);
    expect(r.enabled, isFalse, reason: '跑完必须关掉，否则列表里挂着僵尸规则');

    // 再跑一次也不该再多出流水
    final again = await store.applyDueRecurring(bookId, DateTime(2026, 8, 10));
    expect(again, 0);
  });

  test('到某天结束：结束日之后的那期不再生成', () async {
    await addRule(
      lastRunMonth: '2025-12',
      endMode: 'until',
      endOn: DateTime(2026, 3, 15),
    );
    final n = await store.applyDueRecurring(bookId, DateTime(2026, 6, 10));
    // 1/5、2/5、3/5 都 <= 3/15；4/5 已过结束日
    expect(n, 3);
    final list = await store.entriesOfMonth(bookId, DateTime(2026, 4));
    expect(list, isEmpty, reason: '4 月不该有');
  });

  test('开始时间在未来的月份：从那个月才开始', () async {
    await addRule(
      lastRunMonth: '2025-12',
      startOn: DateTime(2026, 2, 1),
    );
    final n = await store.applyDueRecurring(bookId, DateTime(2026, 6, 1));
    // 1 月整月早于起始月，跳过；2/3/4/5 月各一笔；6/5 还没到
    expect(n, 4);
    final jan = await store.entriesOfMonth(bookId, DateTime(2026, 1));
    expect(jan, isEmpty);
  });

  test('开始时间在当月、但那一期已经过去 → 当月不补', () async {
    // 11-20 建「每月 5 号」：11-05 已经过去，第一次应该是 12-05
    await addRule(lastRunMonth: '2026-10', startOn: DateTime(2026, 11, 20));
    final n = await store.applyDueRecurring(bookId, DateTime(2026, 11, 22));
    expect(n, 0, reason: '当月那一期早于开始日，不能补记');
    final r = await rule((await store.recurrings(bookId)).last.id);
    expect(r.lastRunMonth, '2026-11', reason: '要推进，否则每个月都重扫');
  });

  test('开始时间在当月、那一期还没到 → 到日子照常生成', () async {
    await addRule(lastRunMonth: '2026-10', startOn: DateTime(2026, 11, 1));
    final before = await store.applyDueRecurring(bookId, DateTime(2026, 11, 3));
    expect(before, 0, reason: '11-05 还没到');
    final after = await store.applyDueRecurring(bookId, DateTime(2026, 11, 6));
    expect(after, 1);
  });
}
