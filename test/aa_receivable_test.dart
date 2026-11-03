import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// AA 应收（DB v20）：别人还 AA 钱时生成一笔**不计收支**的收入冲抵待收。
///
/// 铁律：
/// - 支出按 amount − split 计；
/// - 回款收入 exclude_from_stats=true（只加余额、不算收入），否则结余虚高；
/// - 待收 = split − Σ 指向它的回款；
/// - 删原支出→回款一起删；删回款→待收自然复原（无残留状态）。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;
  late int pocketId;
  late int bucketId;
  final day = DateTime(2026, 10, 20);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-aa-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
    pocketId = (await store.allPockets(includeArchived: false)).first.id;
    bucketId = (await store.buckets(bookId, 'out')).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  /// 一笔 300 元支出，他人承担 200（我 100）。
  Future<int> addSplit() => store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        bucketId: bucketId,
        flow: 'out',
        amountCents: 30000,
        splitCents: 20000,
        memo: '聚餐',
        day: day,
      );

  Future<int> balance() async =>
      (await store.pocketBalances()).first.balanceCents;

  group('收回', () {
    test('生成不计收支的收入，冲掉待收，余额回来', () async {
      final id = await addSplit();
      expect(await balance(), -30000);

      final settleId = await store.settleAa(id, pocketId);
      expect(settleId, greaterThan(0));

      final all = await store.entriesOfDay(bookId, DateTime.now());
      final income = all.firstWhere((e) => e.id == settleId);
      expect(income.flow, 'in');
      expect(income.amountCents, 20000);
      expect(income.excludeFromStats, isTrue);
      expect(income.aaOfEntryId, id);
      expect(income.isAaSettle, isTrue);

      // 待收清空
      expect((await store.aaSettledByEntry(bookId))[id], 20000);
      // 账户：-30000 + 20000 = -10000
      expect(await balance(), -10000);
    });

    test('回款不计收入：统计里收入仍为 0、支出仍是我那份', () async {
      final id = await addSplit();
      // 回款日期必须显式给：默认是「今天」，跨月后就和这笔 10/20 的支出
      // 不在同一个月份里，下面按 10 月统计会查不到任何东西。
      await store.settleAa(id, pocketId, day: day);
      final m = await store.monthTotalsByFlow(bookId, day);
      expect(m['in'] ?? 0, 0); // 回款被 exclude_from_stats 挡掉
      expect(m['out'], 10000); // 30000 - 20000
    });

    test('重复收回不会重复入账', () async {
      final id = await addSplit();
      final a = await store.settleAa(id, pocketId);
      final b = await store.settleAa(id, pocketId);
      expect(b, a); // 返回已有那笔
      final settled = await store.aaSettledByEntry(bookId);
      expect(settled[id], 20000); // 没有叠加
      expect(await balance(), -10000);
    });

    test('没有分摊的流水不能收回', () async {
      final id = await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        flow: 'out',
        amountCents: 5000,
        memo: '咖啡',
        day: day,
      );
      expect(() => store.settleAa(id, pocketId), throwsA(isA<StateError>()));
    });
  });

  group('撤销', () {
    test('删掉回款收入，待收复原、余额回到垫付全额', () async {
      final id = await addSplit();
      await store.settleAa(id, pocketId);
      expect(await balance(), -10000);

      await store.unsettleAa(id);
      expect(await store.aaSettledByEntry(bookId), isEmpty);
      expect(await balance(), -30000);
    });
  });

  group('级联', () {
    test('删原支出：回款收入一起进回收站，余额双双回落', () async {
      final id = await addSplit();
      await store.settleAa(id, pocketId);
      await store.softDeleteEntries([id]);
      // 收入和支出都软删了 → 余额回到期初
      expect(await balance(), 0);
      // 回收站里两条
      expect((await store.recycleBinEntries(bookId)).length, 2);
    });

    test('恢复原支出：回款一起回来', () async {
      final id = await addSplit();
      await store.settleAa(id, pocketId);
      await store.softDeleteEntries([id]);
      await store.restoreEntries([id]);
      expect(await balance(), -10000);
      expect((await store.aaSettledByEntry(bookId))[id], 20000);
    });

    test('只删回款收入：待收自然复原（无需额外状态回退）', () async {
      final id = await addSplit();
      final settleId = await store.settleAa(id, pocketId);
      await store.softDeleteEntries([settleId]);
      expect(await store.aaSettledByEntry(bookId), isEmpty);
      expect(await balance(), -30000);
    });
  });

  group('待收清单', () {
    test('aaEntries 只含分摊支出，不含回款收入', () async {
      final id = await addSplit();
      await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        flow: 'out',
        amountCents: 5000,
        memo: '不分摊',
        day: day,
      );
      await store.settleAa(id, pocketId);
      final list = await store.aaEntries(bookId);
      expect(list.length, 1);
      expect(list.first.id, id);
    });
  });

  group('部分收回', () {
    test('先收一半，待收保留；再收剩下的', () async {
      final id = await addSplit();
      final s1 = await store.settleAa(id, pocketId, amountCents: 5000);
      expect((await store.aaSettledByEntry(bookId))[id], 5000);
      expect(await balance(), -25000); // -30000 + 5000
      final s2 = await store.settleAa(id, pocketId); // 收剩下的 15000
      expect((await store.aaSettledByEntry(bookId))[id], 20000);
      expect(await balance(), -10000);
      expect(s2, isNot(s1));
    });

    test('多传金额不会多收（夹到待收）', () async {
      final id = await addSplit();
      await store.settleAa(id, pocketId, amountCents: 999999);
      expect((await store.aaSettledByEntry(bookId))[id], 20000);
      expect(await balance(), -10000);
    });
  });

  group('欠款人', () {
    test('记录 / 读取 / 清除', () async {
      final id = await addSplit();
      await store.setAaCounterparty(id, ' 张三 ');
      var e = (await store.entriesOfDay(bookId, day)).first;
      expect(e.aaCounterparty, '张三');
      await store.setAaCounterparty(id, '');
      e = (await store.entriesOfDay(bookId, day)).first;
      expect(e.aaCounterparty, isNull);
    });
  });

  group('导出导入', () {
    test('aa_of_entry_id 随备份往返', () async {
      final id = await addSplit();
      await store.settleAa(id, pocketId);
      final json = await store.exportJson();
      expect(json.contains('"aa_of_entry_id"'), isTrue);

      final tmp2 = await Directory.systemTemp.createTemp('jianji-aa-imp-');
      final store2 = await LedgerStore.open(path: '${tmp2.path}/imp.db');
      await store2.importJson(json);
      final bid2 = (await store2.books()).first.id;
      final settled = await store2.aaSettledByEntry(bid2);
      expect(settled[id], 20000);
      await store2.close();
      await tmp2.delete(recursive: true);
    });
  });

  group('v19 → v20 迁移', () {
    test('老库无 aa_of_entry_id 列：升级后补列、老流水为空', () async {
      final path = '${tmp.path}/legacy.db';
      final legacy = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 19,
            onCreate: (db, _) async {
              await db.execute('''CREATE TABLE books (
                id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,
                glyph TEXT NOT NULL, base_currency TEXT NOT NULL DEFAULT 'CNY',
                rank INTEGER NOT NULL DEFAULT 0)''');
              await db.execute('''CREATE TABLE pockets (
                id INTEGER PRIMARY KEY AUTOINCREMENT, book_id INTEGER NOT NULL,
                title TEXT NOT NULL, glyph TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'cash',
                currency TEXT NOT NULL DEFAULT 'CNY',
                opening_cents INTEGER NOT NULL DEFAULT 0,
                rank INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
                credit_limit_cents INTEGER NOT NULL DEFAULT 0,
                billing_day INTEGER, payment_due_day INTEGER)''');
              await db.execute('''CREATE TABLE buckets (
                id INTEGER PRIMARY KEY AUTOINCREMENT, book_id INTEGER NOT NULL,
                title TEXT NOT NULL, glyph TEXT NOT NULL, flow TEXT NOT NULL,
                rank INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
                parent_id INTEGER)''');
              await db.execute('''CREATE TABLE entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT, book_id INTEGER NOT NULL DEFAULT 1,
                pocket_id INTEGER NOT NULL, to_pocket_id INTEGER, bucket_id INTEGER,
                flow TEXT NOT NULL, amount_cents INTEGER NOT NULL,
                split_cents INTEGER NOT NULL DEFAULT 0,
                memo TEXT NOT NULL DEFAULT '', day TEXT NOT NULL,
                tags TEXT NOT NULL DEFAULT '', reimburse INTEGER NOT NULL DEFAULT 0,
                mood INTEGER NOT NULL DEFAULT 0, fee_cents INTEGER NOT NULL DEFAULT 0,
                discount_cents INTEGER NOT NULL DEFAULT 0,
                exclude_from_stats INTEGER NOT NULL DEFAULT 0,
                exclude_from_budget INTEGER NOT NULL DEFAULT 0, currency TEXT,
                to_amount_cents INTEGER, refund_of_id INTEGER, deleted_at TEXT,
                created_at TEXT NOT NULL)''');
              await db.execute('''CREATE TABLE monthly_budgets (
                month TEXT NOT NULL, book_id INTEGER NOT NULL DEFAULT 1,
                amount_cents INTEGER NOT NULL, PRIMARY KEY (month, book_id))''');
              await db.insert('books', {
                'title': '默认账本', 'glyph': '📒',
                'base_currency': 'CNY', 'rank': 0
              });
              await db.insert('pockets', {
                'book_id': 1, 'title': '现金', 'glyph': '💵', 'kind': 'cash',
                'currency': 'CNY', 'opening_cents': 0, 'rank': 0,
                'archived': 0, 'credit_limit_cents': 0,
              });
              await db.insert('buckets', {
                'book_id': 1, 'title': '食', 'glyph': '🍜',
                'flow': 'out', 'rank': 0, 'archived': 0,
              });
              await db.insert('entries', {
                'book_id': 1, 'pocket_id': 1, 'bucket_id': 1, 'flow': 'out',
                'amount_cents': 9000, 'split_cents': 4000, 'memo': '老AA',
                'day': '2026-09-15', 'created_at': '2026-09-15T10:00:00',
              });
            },
          ));
      await legacy.close();

      final migrated = await LedgerStore.open(path: path);
      addTearDown(migrated.close);
      final bid = (await migrated.books()).first.id;
      final old =
          (await migrated.entriesOfMonth(bid, DateTime(2026, 9))).first;
      expect(old.splitCents, 4000);
      expect(old.aaOfEntryId, isNull); // 老流水没有回款关联
      // 能正常收回
      final sid = await migrated.settleAa(old.id, 1);
      expect(sid, greaterThan(0));
    });
  });
}
