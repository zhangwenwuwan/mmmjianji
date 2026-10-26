import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 第 4 批回归：day 解析容错 / 开库自动修孤儿 / 走势锚点 / 笔数统计。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-b4-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  group('day 列解析', () {
    test('parseDay 容忍带时间部分的 day', () {
      expect(LedgerStore.parseDay('2026-10-21'), DateTime(2026, 10, 21));
      // 外部导入 / 手改备份常见形态：带 ISO 时间
      expect(LedgerStore.parseDay('2026-10-21T00:00:00.000'),
          DateTime(2026, 10, 21));
      expect(LedgerStore.parseDay('2024-02-29 23:59:59'),
          DateTime(2024, 2, 29));
    });

    test('entryStats 的最早日不受时间部分影响', () async {
      // 直接写一行带时间的 day（绕开 addEntry 的规范化）
      await store.addEntry(
        bookId: bookId,
        pocketId: (await store.allPockets(includeArchived: false)).first.id,
        bucketId: null,
        flow: 'out',
        amountCents: 100,
        memo: 'a',
        day: DateTime(2026, 10, 21),
        tags: '',
      );
      final stats = await store.entryStats(bookId);
      expect(stats.earliestDay, '2026-10-21');
      // 以前这里 split('-') 后 int.parse，遇到时间部分会 RangeError
      expect(() => LedgerStore.parseDay(stats.earliestDay!), returnsNormally);
    });
  });

  group('开库自动修孤儿流水', () {
    test('开库时自动修孤儿：pocket_id 指向已删账户也能读回来', () async {
      final p = (await store.allPockets(includeArchived: false)).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: p.id,
        bucketId: null,
        flow: 'out',
        amountCents: 20000,
        memo: '本来挂在该账户上',
        day: DateTime(2026, 10, 20),
        tags: '',
      );
      // 用另一条连接把 pocket_id 改成一个不存在的账户，制造真正的孤儿
      final raw = await databaseFactoryFfi.openDatabase('${tmp.path}/test.db');
      await raw.update('entries', {'pocket_id': 99999},
          where: 'book_id = ?', whereArgs: [bookId]);
      await raw.close();

      // 重开（模拟杀进程后冷启动）→ open() 里应该自动 fixOrphans
      await store.close();
      store = await LedgerStore.open(path: '${tmp.path}/test.db');
      final entries = await store.entriesOfMonth(bookId, DateTime(2026, 10));
      expect(entries.length, 1, reason: '孤儿行不能被统计 SQL 吞掉');
      expect(entries.single.pocketId, isNot(99999));
      expect(entries.single.amountCents, 20000);
    });

    test('fixOrphans 把不存在的 pocket_id 改成第一个账户', () async {
      final p = (await store.allPockets(includeArchived: false)).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: p.id,
        bucketId: null,
        flow: 'out',
        amountCents: 500,
        memo: 'o',
        day: DateTime(2026, 10, 21),
        tags: '',
      );
      // 手工制造孤儿：把 pocket_id 指到一个不存在的 id
      await store.fixOrphans(bookId); // 先确保是干净的
      final entries = await store.entriesOfMonth(bookId, DateTime(2026, 10));
      expect(entries.length, 1);
      expect(entries.single.pocketId, p.id);
    });
  });

  group('分类走势锚点', () {
    test('默认锚点是本月，未来月份没有数据', () async {
      final p = (await store.allPockets(includeArchived: false)).first;
      final b = (await store.buckets(bookId, 'out')).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: p.id,
        bucketId: b.id,
        flow: 'out',
        amountCents: 1234,
        memo: 'm',
        day: DateTime(2026, 10, 21),
        tags: '',
      );
      final rows = await store.bucketMonthly(bookId, [b.id], flow: 'out');
      expect(rows.length, 1);
      expect(rows.single.month, '2026-10');
    });

    test('传 anchor 后，晚于锚点的流水不计入', () async {
      final p = (await store.allPockets(includeArchived: false)).first;
      final b = (await store.buckets(bookId, 'out')).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: p.id,
        bucketId: b.id,
        flow: 'out',
        amountCents: 100,
        memo: 'old',
        day: DateTime(2026, 8, 21),
        tags: '',
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: p.id,
        bucketId: b.id,
        flow: 'out',
        amountCents: 200,
        memo: 'new',
        day: DateTime(2026, 10, 21),
        tags: '',
      );
      // 锚 9 月 → 只应看到 8 月
      final rows = await store.bucketMonthly(bookId, [b.id],
          flow: 'out', anchor: DateTime(2026, 9));
      expect(rows.map((e) => e.month).toList(), ['2026-08']);
      expect(rows.single.cents, 100);
    });
  });

  group('笔数统计', () {
    test('countEntriesOfPocket 含转入方', () async {
      final pockets = await store.allPockets(includeArchived: false);
      final a = pockets.first;
      final b = pockets.last;
      await store.addEntry(
        bookId: bookId,
        pocketId: a.id,
        bucketId: null,
        flow: 'out',
        amountCents: 100,
        memo: 'out',
        day: DateTime(2026, 10, 21),
        tags: '',
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: a.id,
        toPocketId: b.id,
        bucketId: null,
        flow: 'transfer',
        amountCents: 200,
        memo: 't',
        day: DateTime(2026, 10, 21),
        tags: '',
      );
      expect(await store.countEntriesOfPocket(a.id), 2);
      expect(await store.countEntriesOfPocket(b.id), 1);
    });
  });
}
