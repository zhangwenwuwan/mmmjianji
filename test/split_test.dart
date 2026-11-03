import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// AA 分摊（DB v19）：entries.split_cents = 「他人承担」金额。
///
/// 口径铁律：
/// - 落库金额 amount_cents 仍是**全额垫付**（账户余额/净资产照全额算）；
/// - 「我的消费」统计 = amount - split（statsCents）；
/// - 收入 / 转账不受影响。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;
  late int pocketId;
  late int bucketId;
  final day = DateTime(2026, 10, 15);

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-split-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
    pocketId = (await store.allPockets(includeArchived: false)).first.id;
    bucketId = (await store.buckets(bookId, 'out')).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  Future<int> addOut(int amount, int split, {String tags = ''}) =>
      store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        bucketId: bucketId,
        flow: 'out',
        amountCents: amount,
        splitCents: split,
        memo: '聚餐',
        tags: tags,
        day: day,
      );

  group('模型 statsCents 口径', () {
    test('支出 = amount - split，收入/转账原样', () {
      Entry mk(String flow, int amount, int split) => Entry(
            id: 1,
            bookId: 1,
            pocketId: 1,
            toPocketId: null,
            bucketId: null,
            flow: flow,
            amountCents: amount,
            splitCents: split,
            memo: '',
            day: day,
            tags: '',
            reimburse: 0,
          );
      expect(mk('out', 30000, 20000).statsCents, 10000);
      expect(mk('out', 30000, 0).statsCents, 30000);
      expect(mk('in', 30000, 20000).statsCents, 30000);
      expect(mk('transfer', 30000, 20000).statsCents, 30000);
      expect(mk('out', 30000, 20000).hasSplit, isTrue);
      expect(mk('out', 30000, 0).hasSplit, isFalse);
      expect(mk('in', 30000, 20000).hasSplit, isFalse);
    });

    test('脏数据 clamp：split>amount 或负数都不会算成负支出', () {
      Entry mk(int amount, int split) => Entry(
            id: 1,
            bookId: 1,
            pocketId: 1,
            toPocketId: null,
            bucketId: null,
            flow: 'out',
            amountCents: amount,
            splitCents: split,
            memo: '',
            day: day,
            tags: '',
            reimburse: 0,
          );
      expect(mk(10000, 99999).statsCents, 0);
      expect(mk(10000, -500).statsCents, 10000);
    });
  });

  group('落库与读取', () {
    test('addEntry 存 split，_toEntry 读回', () async {
      await addOut(30000, 20000);
      final e = (await store.entriesOfDay(bookId, day)).first;
      expect(e.amountCents, 30000); // 全额仍记
      expect(e.splitCents, 20000);
      expect(e.statsCents, 10000);
      expect(e.hasSplit, isTrue);
    });

    test('updateEntry 更新 split', () async {
      await addOut(30000, 20000);
      final e = (await store.entriesOfDay(bookId, day)).first;
      await store.updateEntry(e.copyWith(splitCents: 5000));
      final again = (await store.entriesOfDay(bookId, day)).first;
      expect(again.splitCents, 5000);
      expect(again.statsCents, 25000);
    });

    test('收入/转账强制 split=0（即使调用方传了）', () async {
      await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        flow: 'in',
        amountCents: 10000,
        splitCents: 8000, // 应被忽略
        memo: '还款',
        day: day,
      );
      final e = (await store.entriesOfDay(bookId, day)).first;
      expect(e.splitCents, 0);
      expect(e.statsCents, 10000);
    });

    test('addEntry clamp：split 超过金额时压到金额（不会负支出）', () async {
      await addOut(10000, 99999);
      final e = (await store.entriesOfDay(bookId, day)).first;
      expect(e.splitCents, 10000);
      expect(e.statsCents, 0);
    });

    test('不分摊的普通支出 split 默认 0', () async {
      final id = await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        bucketId: bucketId,
        flow: 'out',
        amountCents: 4200,
        memo: '咖啡',
        day: day,
      );
      expect(id, greaterThan(0));
      expect((await store.entriesOfDay(bookId, day)).first.splitCents, 0);
    });
  });

  group('统计口径（我的消费 = amount - split）', () {
    setUp(() async {
      // 三笔支出：全额 300代付200 / 全额 100代付0 / 全额 50代付50
      await addOut(30000, 20000, tags: 'AA');
      await addOut(10000, 0);
      await addOut(5000, 5000);
      await store.addEntry(
        bookId: bookId,
        pocketId: pocketId,
        flow: 'in',
        amountCents: 8000,
        memo: '报销到账',
        day: day,
      );
    });

    test('monthTotalsByFlow：支出合计只算我的份额', () async {
      final m = await store.monthTotalsByFlow(bookId, day);
      expect(m['out'], 10000 + 10000 + 0); // 20000
      expect(m['in'], 8000); // 收入不受影响
    });

    test('dailyTotalsByFlow：每日支出按我的份额', () async {
      final m = await store.dailyTotalsByFlow(bookId, day);
      final d = m['2026-10-15']!;
      expect(d['out'], 20000);
      expect(d['in'], 8000);
    });

    test('bucketRank：分类排行按我的份额', () async {
      final rows = await store.bucketRank(
        bookId,
        flow: 'out',
        from: DateTime(2026, 10, 1),
        to: DateTime(2026, 10, 31),
      );
      expect(rows.length, 1);
      expect(rows.first.cents, 20000);
    });

    test('bucketSlices：分类占比按我的份额', () async {
      final rows = await store.bucketSlices(bookId, day, flow: 'out');
      expect(rows.length, 1);
      expect(rows.first.cents, 20000);
    });

    test('bucketSpent（预算已花）按我的份额', () async {
      final rows = await store.bucketSpent(bookId, day);
      expect(rows.length, 1);
      expect(rows.first.cents, 20000);
    });

    test('tagSpent：标签统计按我的份额', () async {
      final rows = await store.tagSpent(bookId, day, flow: 'out');
      expect(rows.length, 1);
      expect(rows.first.cents, 10000); // 打了 AA 标签的那笔我只承担 100
    });

    test('pocketSpent：账户维度统计按我的份额', () async {
      final rows = await store.pocketSpent(bookId, day, flow: 'out');
      expect(rows.length, 1);
      expect(rows.first.cents, 20000);
    });

    test('searchTotals：搜索汇总按我的份额', () async {
      final rows = await store.searchTotals(bookId, flow: 'out');
      final out = rows.firstWhere((r) => r.flow == 'out');
      expect(out.cents, 20000);
    });

    test('收入侧统计完全不受 split 影响', () async {
      final rank = await store.bucketRank(
        bookId,
        flow: 'in',
        from: DateTime(2026, 10, 1),
        to: DateTime(2026, 10, 31),
      );
      // 收入没分类，会归到「未分类」，但金额必须还是 8000 全额
      expect(rank.length, 1);
      expect(rank.first.cents, 8000);
      final m = await store.monthTotalsByFlow(bookId, day);
      expect(m['in'], 8000);
    });
  });

  group('余额/资产口径不变（全额）', () {
    test('pocketBalances：账户余额照全额扣，split 不冲抵', () async {
      final pocket = (await store.allPockets(includeArchived: false)).first;
      await addOut(30000, 20000); // 全额垫付 300，别人还我 200
      final balances = {
        for (final b in await store.pocketBalances()) b.pocket.id: b.balanceCents
      };
      // 钱确实从账户出去了 300（不是 100）
      expect(balances[pocket.id], pocket.openingCents - 30000);
    });
  });

  group('导出导入往返', () {
    test('split_cents 随备份往返；老备份缺列时默认 0', () async {
      await addOut(30000, 20000);
      final json = await store.exportJson();
      expect(json.contains('"split_cents"'), isTrue);

      final tmp2 = await Directory.systemTemp.createTemp('jianji-split-imp-');
      final store2 = await LedgerStore.open(path: '${tmp2.path}/imp.db');
      await store2.importJson(json);
      final bid2 = (await store2.books()).first.id;
      final e = (await store2.entriesOfMonth(bid2, day)).first;
      expect(e.amountCents, 30000);
      expect(e.splitCents, 20000);
      expect(e.statsCents, 10000);
      await store2.close();
      await tmp2.delete(recursive: true);
    });
  });

  group('v18 → v19 迁移', () {
    test('老库无 split_cents 列：升级后补列、老数据 split=0', () async {
      final path = '${tmp.path}/legacy.db';
      // 手工建一个含 entries 但**没有 split_cents** 的老结构库（v18）。
      final legacy = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 18,
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
                'title': '默认账本', 'glyph': '📒', 'base_currency': 'CNY', 'rank': 0
              });
              await db.insert('pockets', {
                'book_id': 1, 'title': '现金', 'glyph': '💵', 'kind': 'cash',
                'currency': 'CNY', 'opening_cents': 0, 'rank': 0, 'archived': 0,
                'credit_limit_cents': 0,
              });
              await db.insert('buckets', {
                'book_id': 1, 'title': '食', 'glyph': '🍜', 'flow': 'out',
                'rank': 0, 'archived': 0,
              });
              await db.insert('entries', {
                'book_id': 1, 'pocket_id': 1, 'bucket_id': 1, 'flow': 'out',
                'amount_cents': 1234, 'memo': '老数据', 'day': '2026-09-15',
                'created_at': '2026-09-15T10:00:00',
              });
            },
          ));
      await legacy.close();

      // 用新版本打开 → 触发 18→19 迁移
      final migrated = await LedgerStore.open(path: path);
      addTearDown(migrated.close);

      final bid = (await migrated.books()).first.id;
      final old =
          (await migrated.entriesOfMonth(bid, DateTime(2026, 9))).first;
      expect(old.amountCents, 1234);
      expect(old.splitCents, 0); // 老流水默认不分摊
      expect(old.statsCents, 1234);

      // 新流水能正常写 split
      final p = (await migrated.allPockets()).first.id;
      await migrated.addEntry(
        bookId: bid,
        pocketId: p,
        flow: 'out',
        amountCents: 5000,
        splitCents: 3000,
        memo: 'AA',
        day: DateTime(2026, 9, 16),
      );
      final list = await migrated.entriesOfMonth(bid, DateTime(2026, 9));
      final aa = list.firstWhere((e) => e.memo == 'AA');
      expect(aa.splitCents, 3000);
      expect(aa.statsCents, 2000);
    });
  });
}
