import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/currency.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-store-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  group('开库与基础数据', () {
    test('自动建默认账本 + 账户 + 分类', () async {
      expect((await store.books()).length, 1);
      expect((await store.allPockets(includeArchived: false)).length, 2);
      // 2026-10-26 起默认支出分类只给「衣食住行」四个（原来 8 个）
      expect((await store.buckets(bookId, 'out')).length, 4);
      expect([for (final b in await store.buckets(bookId, 'out')) b.title],
          ['衣', '食', '住', '行']);
      expect((await store.buckets(bookId, 'in')).length, 4);
    });

    test('账户增改归档删除', () async {
      await store.addPocket(
        bookId: bookId,
        title: '招行信用卡',
        glyph: '💳',
        kind: PocketKind.credit,
        currency: 'CNY',
        openingCents: 0,
      );
      var pockets = await store.allPockets(includeArchived: false);
      expect(pockets.length, 3);
      final cc = pockets.firstWhere((p) => p.title == '招行信用卡');
      expect(cc.kind, PocketKind.credit);
      expect(cc.kind.isLiability, isTrue);

      await store.updatePocket(Pocket(
        id: cc.id,
        bookId: bookId,
        title: '招行白金',
        glyph: '💳',
        kind: cc.kind,
        currency: cc.currency,
        openingCents: 0,
        archived: false,
      ));
      pockets = await store.allPockets(includeArchived: false);
      expect(pockets.any((p) => p.title == '招行白金'), isTrue);

      await store.archivePocket(cc.id, true);
      expect((await store.allPockets(includeArchived: false)).length, 2);
      expect((await store.allPockets()).length, 3);

      // 没有流水的账户可以删
      await store.archivePocket(cc.id, false);
      await store.deletePocketIfEmpty(cc.id);
      expect((await store.allPockets(includeArchived: false)).length, 2);
    });

    test('分类增改归档', () async {
      await store.addBucket(
          bookId: bookId, title: '宠物', glyph: '🐱', flow: 'out');
      var out = await store.buckets(bookId, 'out');
      expect(out.length, 5);
      final pet = out.firstWhere((b) => b.title == '宠物');
      await store.archiveBucket(pet.id, true);
      expect((await store.buckets(bookId, 'out')).length, 4);
      expect(
          (await store.buckets(bookId, 'out', includeArchived: true)).length, 5);
    });
  });

  group('多账本隔离', () {
    test('两个账本的数据互不影响', () async {
      final other = await store.addBook('旅行', '✈️', 'JPY');
      final p1 = (await store.allPockets(includeArchived: false)).first;
      final p2 = (await store.allPockets(includeArchived: false)).first;

      await store.addEntry(
        bookId: bookId,
        pocketId: p1.id,
        flow: 'out',
        amountCents: 1000,
        memo: 'A',
        day: DateTime(2026, 10, 1),
      );
      await store.addEntry(
        bookId: other,
        pocketId: p2.id,
        flow: 'out',
        amountCents: 2000,
        memo: 'B',
        day: DateTime(2026, 10, 1),
      );

      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).length, 1);
      expect((await store.entriesOfMonth(other, DateTime(2026, 10))).length, 1);
      expect((await store.monthTotalsByFlow(bookId, DateTime(2026, 10)))['out'], 1000);
      expect((await store.monthTotalsByFlow(other, DateTime(2026, 10)))['out'], 2000);
    });

    test('删除账本会带走它的数据，但最后一个不能删', () async {
      final other = await store.addBook('临时', '🧳', 'CNY');
      await store.addEntry(
        bookId: other,
        pocketId: (await store.allPockets(includeArchived: false)).first.id,
        flow: 'out',
        amountCents: 500,
        memo: 'x',
        day: DateTime(2026, 10, 2),
      );
      await store.deleteBook(other);
      expect((await store.books()).length, 1);
      expect((await store.entriesOfMonth(other, DateTime(2026, 10))).isEmpty, isTrue);

      // 只剩一个时不允许删
      final only = (await store.books()).first;
      expect(() => store.deleteBook(only.id), throwsA(isA<StateError>()));
    });
  });

  group('转账与余额', () {
    test('转账不计收支，只改账户余额', () async {
      final pockets = await store.allPockets(includeArchived: false);
      final cash = pockets[0];
      final bank = pockets[1];
      final out = (await store.buckets(bookId, 'out')).first;

      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        flow: 'in',
        amountCents: 100000,
        memo: '收入',
        day: DateTime(2026, 10, 1),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        bucketId: out.id,
        flow: 'out',
        amountCents: 20000,
        memo: '花掉',
        day: DateTime(2026, 10, 2),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        toPocketId: bank.id,
        flow: 'transfer',
        amountCents: 50000,
        memo: '存银行',
        day: DateTime(2026, 10, 3),
      );

      final totals = await store.monthTotalsByFlow(bookId, DateTime(2026, 10));
      expect(totals['in'], 100000);
      expect(totals['out'], 20000); // 转账不算支出
      expect(totals['transfer'], 50000);

      final balances = await store.pocketBalances();
      final cashBalance = balances.firstWhere((b) => b.pocket.id == cash.id).balanceCents;
      final bankBalance = balances.firstWhere((b) => b.pocket.id == bank.id).balanceCents;
      expect(cashBalance, 100000 - 20000 - 50000);
      expect(bankBalance, 50000);
    });

    test('信用卡还款：转出减少、信用卡余额变正（欠款）', () async {
      await store.addPocket(
        bookId: bookId,
        title: '信用卡',
        glyph: '💳',
        kind: PocketKind.credit,
        currency: 'CNY',
        openingCents: 30000, // 欠 300
      );
      final cc = (await store.allPockets(includeArchived: false)).firstWhere((p) => p.title == '信用卡');
      final bank = (await store.allPockets(includeArchived: false)).firstWhere((p) => p.kind == PocketKind.bank);

      await store.addEntry(
        bookId: bookId,
        pocketId: bank.id,
        toPocketId: cc.id,
        flow: 'transfer',
        amountCents: 30000,
        memo: '还款',
        day: DateTime(2026, 10, 4),
      );

      final balances = await store.pocketBalances();
      final ccBalance = balances.firstWhere((b) => b.pocket.id == cc.id).balanceCents;
      // 期初欠 30000，还款让它变成 0（欠款清零）
      expect(ccBalance, 0);
    });
  });

  group('标签 / 搜索 / 报销', () {
    test('按备注、标签、分类名都能搜到', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      final food = (await store.buckets(bookId, 'out')).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        bucketId: food.id,
        flow: 'out',
        amountCents: 3500,
        memo: '和同事吃面',
        day: DateTime(2026, 10, 5),
        tags: '聚餐,报销',
      );

      expect((await store.searchEntries(bookId, '同事')).length, 1);
      expect((await store.searchEntries(bookId, '聚餐')).length, 1);
      expect((await store.searchEntries(bookId, food.title)).length, 1);
      expect((await store.searchEntries(bookId, '不存在')).isEmpty, isTrue);
    });

    test('报销状态流转', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 8800,
        memo: '打车',
        day: DateTime(2026, 10, 6),
        reimburse: 1,
      );
      expect((await store.reimburseEntries(bookId)).length, 1);
      final e = (await store.reimburseEntries(bookId)).first;
      await store.setReimburse(e.id, 2);
      expect((await store.reimburseEntries(bookId)).isEmpty, isTrue);
      expect((await store.reimburseEntries(bookId, reimburse: 2)).length, 1);
    });
  });

  group('预算 / 目标', () {
    test('预算按账本和月份独立', () async {
      await store.setBudget(bookId, DateTime(2026, 10), 300000);
      expect(await store.budgetOf(bookId, DateTime(2026, 10)), 300000);
      expect(await store.budgetOf(bookId, DateTime(2026, 11)), 0);
      final other = await store.addBook('二号', '📗', 'CNY');
      expect(await store.budgetOf(other, DateTime(2026, 10)), 0);
      await store.setBudget(bookId, DateTime(2026, 10), 0);
      expect(await store.budgetOf(bookId, DateTime(2026, 10)), 0);
    });

    test('储蓄目标增改删', () async {
      await store.addGoal(
        bookId: bookId,
        title: '旅行',
        glyph: '✈️',
        targetCents: 500000,
        savedCents: 120000,
      );
      var goals = await store.goals(bookId);
      expect(goals.length, 1);
      expect(goals.first.savedCents, 120000);

      await store.updateGoal(Goal(
        id: goals.first.id,
        bookId: bookId,
        title: '旅行',
        glyph: '✈️',
        targetCents: 500000,
        savedCents: 300000,
        dueDay: null,
      ));
      goals = await store.goals(bookId);
      expect(goals.first.savedCents, 300000);

      await store.deleteGoal(goals.first.id);
      expect((await store.goals(bookId)).isEmpty, isTrue);
    });
  });

  group('周期记账', () {
    test('首次运行只补本月且不重复', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addRecurring(Recurring(
        id: 0,
        bookId: bookId,
        title: '房租',
        bucketId: null,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 300000,
        dayOfMonth: 5,
        lastRunMonth: '',
        enabled: true,
      ));

      // 今天 10 号，本月该生成
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 10, 10)), 1);
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).length, 1);

      // 再跑一次不该重复
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 10, 20)), 0);
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).length, 1);
    });

    test('本月未到日子不生成，到了日子再补，且不会漏', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addRecurring(Recurring(
        id: 0,
        bookId: bookId,
        title: '订阅',
        bucketId: null,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 1500,
        dayOfMonth: 25,
        lastRunMonth: '2026-08',
        enabled: true,
      ));

      // 9/10：9 月还没到 25 号 → 不生成，且不能推进 lastRunMonth
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 9, 10)), 0);
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 9))).isEmpty, isTrue);

      // 9/26：到期了，应该补上 9 月这一笔
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 9, 26)), 1);
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 9))).length, 1);

      // 同月再跑不重复
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 9, 28)), 0);

      // 10/1：10 月未到 25 号 → 不生成
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 10, 1)), 0);
      // 10/25：生成
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 10, 25)), 1);
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).length, 1);
    });

    test('暂停的模板不生成', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addRecurring(Recurring(
        id: 0,
        bookId: bookId,
        title: '会员',
        bucketId: null,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 900,
        dayOfMonth: 1,
        lastRunMonth: '',
        enabled: false,
      ));
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 10, 10)), 0);
    });

    test('dayOfMonth=31 在短月不会静默丢 / 卡死（4 月只有 30 天）', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addRecurring(Recurring(
        id: 0,
        bookId: bookId,
        title: '31号费',
        bucketId: null,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 100,
        dayOfMonth: 31,
        lastRunMonth: '2026-03',
        enabled: true,
      ));
      // 4 月只有 30 天：修复后应在当月最后一天（30 号）落地一笔，
      // 并推进 lastRunMonth=2026-04；不修复则 31 号溢出到 5 月、
      // 今天(4/10) 早于 5/1 → 直接 break 且 lastRunMonth 永不推进 → 永久卡死。
      // 关键：当月没有 31 号时，进入当月即视为到期，不必等「那一天」。
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 4, 10)), 1);
      final apr = await store.entriesOfMonth(bookId, DateTime(2026, 4));
      expect(apr.length, 1);
      expect(apr.first.day.day, 30); // 被夹到当月最后一天
      // 同月再跑不应重复（证明 lastRunMonth 真的推进了）
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 4, 20)), 0);
    });

    test('dayOfMonth=31 在 2 月（28 天）同样落到当月最后一天', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      // 独立模板：lastRunMonth 早于 2 月，确保本次调用会补到 2 月。
      await store.addRecurring(Recurring(
        id: 0,
        bookId: bookId,
        title: '31号费-2月',
        bucketId: null,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 100,
        dayOfMonth: 31,
        lastRunMonth: '2026-01',
        enabled: true,
      ));
      expect(await store.applyDueRecurring(bookId, DateTime(2026, 2, 28)), 1);
      final feb = await store.entriesOfMonth(bookId, DateTime(2026, 2));
      expect(feb.length, 1);
      expect(feb.first.day.day, 28);
    });
  });

  group('汇率折算', () {
    test('外币按 rate 折成主币，缺失时按 1:1', () {
      expect(toBaseCents(10000, 'CNY', 'CNY', {}), 10000);
      // 100 美元，汇率 7.2 → 720 元 = 72000 分
      expect(toBaseCents(10000, 'USD', 'CNY', {'USD': 7.2}), 72000);
      // 没汇率按 1:1，但 hasRate 会告诉调用方
      expect(toBaseCents(10000, 'USD', 'CNY', {}), 10000);
      expect(hasRate('USD', 'CNY', {}), isFalse);
      expect(hasRate('CNY', 'CNY', {}), isTrue);
    });

    test('汇率落库后统计按折算算', () async {
      await store.setRate(bookId, 'USD', 7.0);
      expect(await store.rates(bookId), {'USD': 7.0});

      await store.addPocket(
        bookId: bookId,
        title: '美元卡',
        glyph: '💵',
        kind: PocketKind.bank,
        currency: 'USD',
        openingCents: 0,
      );
      final usd = (await store.allPockets(includeArchived: false)).firstWhere((p) => p.currency == 'USD');
      await store.addEntry(
        bookId: bookId,
        pocketId: usd.id,
        flow: 'out',
        amountCents: 1000, // 10 美元
        memo: 'usd',
        day: DateTime(2026, 10, 7),
      );
      // 上层的统计会折算；store 层返回原币种
      final slices = await store.bucketSlices(bookId, DateTime(2026, 10));
      final usdSlice = slices.firstWhere((s) => s.currency == 'USD');
      expect(usdSlice.cents, 1000);
    });
  });

  group('备份', () {
    test('导出导入往返（含多账本/目标/周期/汇率）', () async {
      await store.setRate(bookId, 'USD', 7.1);
      await store.addGoal(
          bookId: bookId,
          title: '相机',
          glyph: '📷',
          targetCents: 800000,
          savedCents: 100000);
      await store.addRecurring(Recurring(
        id: 0,
        bookId: bookId,
        title: '房租',
        bucketId: null,
        pocketId: (await store.allPockets(includeArchived: false)).first.id,
        flow: 'out',
        amountCents: 300000,
        dayOfMonth: 5,
        lastRunMonth: '',
        enabled: true,
      ));
      await store.addEntry(
        bookId: bookId,
        pocketId: (await store.allPockets(includeArchived: false)).first.id,
        flow: 'out',
        amountCents: 4321,
        memo: '备份测试',
        day: DateTime(2026, 10, 9),
        tags: 'tag1',
      );

      final json = await store.exportJson();
      expect(json.contains('jianji'), isTrue);

      await store.wipe();
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).isEmpty, isTrue);

      await store.importJson(json);
      final restored = await store.entriesOfMonth(bookId, DateTime(2026, 10));
      expect(restored.length, 1);
      expect(restored.first.memo, '备份测试');
      expect(restored.first.tags, 'tag1');
      expect((await store.goals(bookId)).length, 1);
      expect((await store.recurrings(bookId)).length, 1);
      expect((await store.rates(bookId))['USD'], 7.1);
    });

    test('非法备份要报错', () async {
      expect(() => store.importJson('{"app":"other"}'),
          throwsA(isA<FormatException>()));
      expect(() => store.importJson('not json'), throwsA(isA<FormatException>()));
    });
  });

  group('v1 → v2 迁移', () {
    test('老库打开后数据保留且挂到默认账本', () async {
      final path = '${tmp.path}/legacy.db';
      // 手工建一个 v1 结构的库
      final legacy = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) async {
              await db.execute('''CREATE TABLE pockets (
                id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,
                glyph TEXT NOT NULL, opening_cents INTEGER NOT NULL DEFAULT 0,
                rank INTEGER NOT NULL DEFAULT 0)''');
              await db.execute('''CREATE TABLE buckets (
                id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,
                glyph TEXT NOT NULL, flow TEXT NOT NULL,
                rank INTEGER NOT NULL DEFAULT 0)''');
              await db.execute('''CREATE TABLE entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT, pocket_id INTEGER NOT NULL,
                bucket_id INTEGER, flow TEXT NOT NULL,
                amount_cents INTEGER NOT NULL, memo TEXT NOT NULL DEFAULT '',
                day TEXT NOT NULL, created_at TEXT NOT NULL)''');
              await db.execute('''CREATE TABLE monthly_budgets (
                month TEXT PRIMARY KEY, amount_cents INTEGER NOT NULL)''');
              await db.insert('pockets', {'title': '旧钱包', 'glyph': '👛', 'opening_cents': 5000});
              await db.insert('buckets', {'title': '旧分类', 'glyph': '🍜', 'flow': 'out'});
              await db.insert('entries', {
                'pocket_id': 1, 'bucket_id': 1, 'flow': 'out',
                'amount_cents': 1234, 'memo': '老数据',
                'day': '2026-09-15', 'created_at': '2026-09-15T10:00:00',
              });
              await db.insert('monthly_budgets', {'month': '2026-09', 'amount_cents': 100000});
            },
          ));
      await legacy.close();

      // 用新版本打开 → 触发 1→2 迁移
      final migrated = await LedgerStore.open(path: path);
      addTearDown(migrated.close);

      final books = await migrated.books();
      expect(books.length, 1);
      final bid = books.first.id;

      final pockets = await migrated.allPockets();
      expect(pockets.length, 1);
      expect(pockets.first.title, '旧钱包');
      expect(pockets.first.currency, 'CNY'); // 补的默认币种

      final entries = await migrated.entriesOfMonth(bid, DateTime(2026, 9));
      expect(entries.length, 1);
      expect(entries.first.memo, '老数据');
      expect(entries.first.tags, '');
      expect(entries.first.reimburse, 0);

      expect(await migrated.budgetOf(bid, DateTime(2026, 9)), 100000);

      // v1 老库升级后必须能带 mood 写新流水（曾经缺这一列，addEntry 直接报错）
      await migrated.addEntry(
        bookId: bid,
        pocketId: pockets.first.id,
        flow: 'out',
        amountCents: 500,
        memo: '升级后新增',
        day: DateTime(2026, 9, 20),
        mood: 3,
      );
      final afterUpgrade = await migrated.entriesOfMonth(bid, DateTime(2026, 9));
      expect(afterUpgrade.length, 2);
      final fresh = afterUpgrade.firstWhere((e) => e.memo == '升级后新增');
      expect(fresh.mood, 3);
      expect(
          (await migrated.buckets(bid, 'out', includeArchived: true)).length, 1);
    });
  });

  group('软删除与回收站', () {
    test('删除后不进统计/搜索/余额，回收站能查到', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      final food = (await store.buckets(bookId, 'out')).first;
      final id = await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        bucketId: food.id,
        flow: 'out',
        amountCents: 5000,
        memo: '要被删',
        day: DateTime(2026, 10, 15),
        tags: '临时',
      );

      // 删除前都在
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).length, 1);
      expect((await store.searchEntries(bookId, '要被删')).length, 1);
      expect((await store.tagSpent(bookId, DateTime(2026, 10))).any((r) => r.tag == '临时'), isTrue);

      await store.deleteEntry(id);

      // 删除后从所有活跃查询消失
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).isEmpty, isTrue);
      expect((await store.searchEntries(bookId, '要被删')).isEmpty, isTrue);
      final monthTotals = await store.monthTotalsByFlow(bookId, DateTime(2026, 10));
      expect(monthTotals['out'] ?? 0, 0);
      expect((await store.recycleBinEntries(bookId)).length, 1);
      final trashed = (await store.recycleBinEntries(bookId)).first;
      expect(trashed.deletedAt, isNotNull);
      // 恢复后数据完整回来
      await store.restoreEntry(id);
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).length, 1);
      expect((await store.recycleBinEntries(bookId)).isEmpty, isTrue);
    });

    test('批量删除/恢复', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      final a = await store.addEntry(
        bookId: bookId, pocketId: cash.id, flow: 'out', amountCents: 100,
        memo: 'A', day: DateTime(2026, 10, 16));
      final b = await store.addEntry(
        bookId: bookId, pocketId: cash.id, flow: 'out', amountCents: 200,
        memo: 'B', day: DateTime(2026, 10, 16));
      expect(await store.deleteEntries([a, b]), 2);
      expect((await store.recycleBinEntries(bookId)).length, 2);
      expect(await store.restoreEntries([a]), 1);
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).length, 1);
      // 重复删除同一条：只生效一次
      expect(await store.deleteEntries([a, b]), 1);
    });

    test('永久删除会清附件记录', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      final id = await store.addEntry(
        bookId: bookId, pocketId: cash.id, flow: 'out', amountCents: 300,
        memo: '带图', day: DateTime(2026, 10, 17));
      await store.addAttachment(bookId: bookId, entryId: id, path: '/tmp/x.png');
      expect((await store.attachmentsOf(id)).length, 1);

      // 软删除后附件仍在（撤销能找回凭证）
      await store.deleteEntry(id);
      expect((await store.attachmentsOf(id)).length, 1);

      // 永久删除后附件记录清空
      await store.purgeEntry(id);
      expect((await store.attachmentsOf(id)).isEmpty, isTrue);
      expect((await store.recycleBinEntries(bookId)).isEmpty, isTrue);
    });

    test('清空回收站', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      for (var i = 0; i < 3; i++) {
        final id = await store.addEntry(
          bookId: bookId, pocketId: cash.id, flow: 'out', amountCents: 10 * i,
          memo: 'R$i', day: DateTime(2026, 10, 18));
        await store.deleteEntry(id);
      }
      expect((await store.recycleBinEntries(bookId)).length, 3);
      expect(await store.purgeAllRecycleBin(bookId), 3);
      expect((await store.recycleBinEntries(bookId)).isEmpty, isTrue);
    });

    test('老库（v1）升级后带 deleted_at 列', () async {
      final path = '${tmp.path}/legacy-soft.db';
      final legacy = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, _) async {
              await db.execute('''CREATE TABLE entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT, pocket_id INTEGER NOT NULL,
                bucket_id INTEGER, flow TEXT NOT NULL,
                amount_cents INTEGER NOT NULL, memo TEXT NOT NULL DEFAULT '',
                day TEXT NOT NULL, created_at TEXT NOT NULL)''');
              await db.execute('''CREATE TABLE pockets (
                id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,
                glyph TEXT NOT NULL, opening_cents INTEGER NOT NULL DEFAULT 0,
                rank INTEGER NOT NULL DEFAULT 0)''');
              await db.execute('''CREATE TABLE buckets (
                id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,
                glyph TEXT NOT NULL, flow TEXT NOT NULL,
                rank INTEGER NOT NULL DEFAULT 0)''');
              await db.execute('''CREATE TABLE monthly_budgets (
                month TEXT PRIMARY KEY, amount_cents INTEGER NOT NULL)''');
              await db.insert('pockets', {'title': '老', 'glyph': '👛', 'opening_cents': 0});
              await db.insert('buckets', {'title': '食', 'glyph': '🍜', 'flow': 'out'});
              await db.insert('entries', {
                'pocket_id': 1, 'bucket_id': 1, 'flow': 'out',
                'amount_cents': 1234, 'memo': '老数据',
                'day': '2026-09-15', 'created_at': '2026-09-15T10:00:00',
              });
            },
          ));
      await legacy.close();

      final migrated = await LedgerStore.open(path: path);
      addTearDown(migrated.close);
      // 升级后能软删除（说明 deleted_at 列已补上）
      final bid = (await migrated.books()).first.id;
      final e = (await migrated.entriesOfMonth(bid, DateTime(2026, 9))).first;
      await migrated.deleteEntry(e.id);
      expect((await migrated.entriesOfMonth(bid, DateTime(2026, 9))).isEmpty, isTrue);
      expect((await migrated.recycleBinEntries(bid)).length, 1);
    });
  });

  group('批量编辑（首页长按多选）', () {
    test('批量改日期：原日期消失、新日期出现，金额不变', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      final a = await store.addEntry(
          bookId: bookId,
          pocketId: cash.id,
          flow: 'out',
          amountCents: 700,
          memo: '搬家A',
          day: DateTime(2026, 8, 3));
      final b = await store.addEntry(
          bookId: bookId,
          pocketId: cash.id,
          flow: 'out',
          amountCents: 900,
          memo: '搬家B',
          day: DateTime(2026, 8, 3));

      expect(await store.updateEntriesDay([a, b], DateTime(2026, 9, 1)), 2);

      final oldDay = await store.entriesOfDay(bookId, DateTime(2026, 8, 3));
      expect(oldDay.where((e) => e.id == a || e.id == b), isEmpty,
          reason: '改日期后不该还留在原日期');
      final newDay = await store.entriesOfDay(bookId, DateTime(2026, 9, 1));
      expect(newDay.where((e) => e.id == a || e.id == b).length, 2);
      expect(newDay.firstWhere((e) => e.id == a).amountCents, 700,
          reason: '只改日期，金额不能被动');
    });

    test('批量改分类 / 备注；空列表是 no-op', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      final buckets = await store.buckets(bookId, 'out');
      final a = await store.addEntry(
          bookId: bookId,
          pocketId: cash.id,
          bucketId: buckets[0].id,
          flow: 'out',
          amountCents: 100,
          memo: '旧的',
          day: DateTime(2026, 7, 5));
      final b = await store.addEntry(
          bookId: bookId,
          pocketId: cash.id,
          bucketId: buckets[0].id,
          flow: 'out',
          amountCents: 200,
          memo: '旧的',
          day: DateTime(2026, 7, 5));

      expect(await store.updateEntriesBucket([a, b], buckets[1].id), 2);
      expect(await store.updateEntriesMemo([a, b], '新的'), 2);

      final rows = await store.entriesOfDay(bookId, DateTime(2026, 7, 5));
      final mine = rows.where((e) => e.id == a || e.id == b).toList();
      expect(mine.length, 2);
      expect(mine.every((e) => e.bucketId == buckets[1].id), isTrue);
      expect(mine.every((e) => e.memo == '新的'), isTrue);

      // 空列表不能拿空 IN () 去拼 SQL（会直接报错）
      expect(await store.updateEntriesDay(const [], DateTime(2026, 1, 1)), 0);
      expect(await store.updateEntriesBucket(const [], null), 0);
      expect(await store.updateEntriesMemo(const [], 'x'), 0);
    });
  });

  group('账户简称/卡号 + 月度总结', () {
    test('简称卡号可存可读，displayName 优先简称', () async {
      await store.addPocket(
        bookId: bookId,
        title: '储蓄卡',
        glyph: '💳',
        kind: PocketKind.bank,
        currency: 'CNY',
        openingCents: 0,
        alias: '工资卡',
        cardNo: '6222****1234',
      );
      final pockets = await store.allPockets();
      final p = pockets.firstWhere((e) => e.title == '储蓄卡');
      expect(p.alias, '工资卡');
      expect(p.cardNo, '6222****1234');
      expect(p.displayName, '工资卡', reason: '有简称时优先显示简称');

      // 清掉简称后回落到正式名称
      await store.updatePocket(Pocket(
        id: p.id,
        bookId: p.bookId,
        title: p.title,
        glyph: p.glyph,
        kind: p.kind,
        currency: p.currency,
        openingCents: p.openingCents,
        archived: p.archived,
        alias: '',
        cardNo: p.cardNo,
      ));
      final again =
          (await store.allPockets()).firstWhere((e) => e.id == p.id);
      expect(again.alias, '');
      expect(again.displayName, '储蓄卡');
    });

    test('账户类型预设可存可读，老账户回落到空串', () async {
      await store.addPocket(
        bookId: bookId,
        title: '支付宝余额',
        glyph: '🅰️',
        kind: PocketKind.bank,
        currency: 'CNY',
        openingCents: 0,
        typeId: 'alipay',
      );
      final p = (await store.allPockets())
          .firstWhere((e) => e.title == '支付宝余额');
      expect(p.typeId, 'alipay');
      expect(p.kind, PocketKind.bank, reason: '类型只做展示，口径仍看 kind');

      // 改类型要能落库（否则编辑页保存后图标又跳回默认）
      await store.updatePocket(Pocket(
        id: p.id,
        bookId: p.bookId,
        title: p.title,
        glyph: '🌸',
        kind: PocketKind.credit,
        currency: p.currency,
        openingCents: p.openingCents,
        archived: p.archived,
        typeId: 'huabei',
      ));
      final again = (await store.allPockets()).firstWhere((e) => e.id == p.id);
      expect(again.typeId, 'huabei');
      expect(again.kind, PocketKind.credit);

      // 默认账本的现金账户没设过类型，必须是空串而不是 null 崩溃
      final cash = (await store.allPockets()).firstWhere((e) => e.kind == PocketKind.cash);
      expect(cash.typeId, '');
    });

    test('账户类型随备份导出', () async {
      await store.addPocket(
        bookId: bookId,
        title: '微信零钱',
        glyph: '💬',
        kind: PocketKind.bank,
        currency: 'CNY',
        openingCents: 0,
        typeId: 'wechat',
      );
      final json = await store.exportJson();
      expect(json.contains('wechat'), isTrue);
      expect(json.contains('"type"'), isTrue);
    });

    test('月度总结：写入 / 读取 / 空白清除', () async {
      await store.setMonthNote(bookId, DateTime(2026, 10), '这个月少点外卖');
      expect(await store.monthNote(bookId, DateTime(2026, 10)), '这个月少点外卖');
      // 别的月份互不影响
      expect(await store.monthNote(bookId, DateTime(2026, 9)), '');

      await store.setMonthNote(bookId, DateTime(2026, 10), '   ');
      expect(await store.monthNote(bookId, DateTime(2026, 10)), '',
          reason: '空白应视为清除，不留空行');
    });

    test('月度总结随备份导出', () async {
      await store.setMonthNote(bookId, DateTime(2026, 10), '测试总结');
      final json = await store.exportJson();
      expect(json.contains('monthNotes'), isTrue);
      expect(json.contains('测试总结'), isTrue);
    });

    test('月度总结归档列表按月份倒序，空白的不算', () async {
      await store.setMonthNote(bookId, DateTime(2026, 8), '八月');
      await store.setMonthNote(bookId, DateTime(2026, 10), '十月');
      await store.setMonthNote(bookId, DateTime(2026, 9), '   '); // 视为清除

      final notes = await store.monthNotes(bookId);
      expect(notes.map((e) => e.month).toList(), ['2026-10', '2026-08']);
      expect(notes.first.note, '十月');
    });
  });

  group('余额校准（对账）', () {
    /// 取账户当前余额（跨账本口径，与页面显示同源）
    Future<int> balanceOf(int pocketId) async =>
        (await store.pocketBalances())
            .firstWhere((b) => b.pocket.id == pocketId)
            .balanceCents;

    test('普通账户：差额生成「收入/支出」调整流水，余额对齐且不进收支', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        flow: 'in',
        amountCents: 100000,
        memo: '工资',
        day: DateTime(2026, 10, 1),
      );
      expect(await balanceOf(cash.id), 100000);

      // 实际只有 950 → 少 5000，补一笔支出
      final id = await store.reconcileBalance(
        bookId: bookId,
        pocket: cash,
        currentCents: 100000,
        targetCents: 95000,
      );
      expect(id, isNotNull);
      expect(await balanceOf(cash.id), 95000);

      final rows = await store.entriesOfMonth(bookId, DateTime(2026, 10));
      final adj = rows.firstWhere((e) => e.id == id);
      expect(adj.flow, 'out');
      expect(adj.amountCents, 5000);
      expect(adj.adjustment, isTrue);
      expect(adj.excludeFromStats, isTrue);
      expect(adj.excludeFromBudget, isTrue);

      // 校准不能污染收支统计
      final totals = await store.monthTotalsByFlow(bookId, DateTime(2026, 10));
      expect(totals['out'] ?? 0, 0);
      expect(totals['in'], 100000);

      // 余额已经一致时不再生成
      expect(
        await store.reconcileBalance(
          bookId: bookId,
          pocket: cash,
          currentCents: 95000,
          targetCents: 95000,
        ),
        isNull,
      );
    });

    test('普通账户余额变多 → 记收入', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      final id = await store.reconcileBalance(
        bookId: bookId,
        pocket: cash,
        currentCents: 0,
        targetCents: 3000,
      );
      final e =
          (await store.entriesOfPocket(cash.id)).firstWhere((x) => x.id == id);
      expect(e.flow, 'in');
      expect(e.memo, '余额校准');
      expect(await balanceOf(cash.id), 3000);
    });

    test('负债账户：欠款变多记支出、变少记收入（符号与普通账户相反）', () async {
      await store.addPocket(
        bookId: bookId,
        title: '信用卡',
        glyph: '💳',
        kind: PocketKind.credit,
        currency: 'CNY',
        openingCents: 30000, // 期初欠 300
      );
      final cc = (await store.allPockets(includeArchived: false))
          .firstWhere((p) => p.title == '信用卡');
      expect(await balanceOf(cc.id), 30000);

      // 实际欠 350 → 多欠 5000 → 支出
      final more = await store.reconcileBalance(
        bookId: bookId,
        pocket: cc,
        currentCents: 30000,
        targetCents: 35000,
      );
      expect(await balanceOf(cc.id), 35000);
      final moreEntry =
          (await store.entriesOfPocket(cc.id)).firstWhere((e) => e.id == more);
      expect(moreEntry.flow, 'out');
      expect(moreEntry.amountCents, 5000);
      expect(moreEntry.memo, '欠款校准');

      // 实际只欠 200 → 少欠 15000 → 收入
      final less = await store.reconcileBalance(
        bookId: bookId,
        pocket: cc,
        currentCents: 35000,
        targetCents: 20000,
      );
      expect(await balanceOf(cc.id), 20000);
      final lessEntry =
          (await store.entriesOfPocket(cc.id)).firstWhere((e) => e.id == less);
      expect(lessEntry.flow, 'in');
      expect(lessEntry.amountCents, 15000);
    });

    test('只看校准：能筛出校准流水，也能数出条数', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 1200,
        memo: '买菜',
        day: DateTime(2026, 10, 2),
      );
      await store.reconcileBalance(
        bookId: bookId,
        pocket: cash,
        currentCents: await balanceOf(cash.id),
        targetCents: 50000,
      );

      expect(await store.adjustmentCountOf(cash.id), 1);
      final only = await store.entriesOfPocket(cash.id, onlyAdjustment: true);
      expect(only.length, 1);
      expect(only.first.adjustment, isTrue);
      expect(only.first.memo, '余额校准');
      // 不筛时两条都在
      expect((await store.entriesOfPocket(cash.id)).length, 2);
    });

    test('校准流水随备份往返，标记不丢', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.reconcileBalance(
        bookId: bookId,
        pocket: cash,
        currentCents: 0,
        targetCents: 8800,
      );
      final json = await store.exportJson();
      await store.wipe();
      await store.importJson(json);

      final pid = (await store.allPockets(includeArchived: false)).first.id;
      expect(await store.adjustmentCountOf(pid), 1);
      final only = await store.entriesOfPocket(pid, onlyAdjustment: true);
      expect(only.first.adjustment, isTrue);
    });

    test('v12 老库升级：按 memo 回填 adjustment，历史校准也能筛出来', () async {
      // 手工造一个 v12 的库：entries 没有 adjustment 列，
      // 但已经存在 1.3.0 时代生成的「余额校准」流水。
      final path = '${tmp.path}/v12.db';
      final legacy = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 12,
            onCreate: (db, _) async {
              await db.execute('''CREATE TABLE books (
                id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL,
                glyph TEXT NOT NULL, base_currency TEXT NOT NULL DEFAULT 'CNY',
                rank INTEGER NOT NULL DEFAULT 0)''');
              await db.execute('''CREATE TABLE pockets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id INTEGER NOT NULL DEFAULT 1, title TEXT NOT NULL,
                glyph TEXT NOT NULL, kind TEXT NOT NULL DEFAULT 'cash',
                currency TEXT NOT NULL DEFAULT 'CNY',
                opening_cents INTEGER NOT NULL DEFAULT 0,
                rank INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0,
                credit_limit_cents INTEGER NOT NULL DEFAULT 0,
                billing_day INTEGER, payment_due_day INTEGER)''');
              await db.execute('''CREATE TABLE buckets (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id INTEGER NOT NULL DEFAULT 1, title TEXT NOT NULL,
                glyph TEXT NOT NULL, flow TEXT NOT NULL,
                rank INTEGER NOT NULL DEFAULT 0,
                archived INTEGER NOT NULL DEFAULT 0, parent_id INTEGER)''');
              await db.execute('''CREATE TABLE monthly_budgets (
                month TEXT PRIMARY KEY, amount_cents INTEGER NOT NULL)''');
              await db.execute('''CREATE TABLE entries (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id INTEGER NOT NULL DEFAULT 1, pocket_id INTEGER NOT NULL,
                to_pocket_id INTEGER, bucket_id INTEGER, flow TEXT NOT NULL,
                amount_cents INTEGER NOT NULL, memo TEXT NOT NULL DEFAULT '',
                day TEXT NOT NULL, created_at TEXT NOT NULL,
                tags TEXT NOT NULL DEFAULT '', reimburse INTEGER NOT NULL DEFAULT 0,
                mood INTEGER NOT NULL DEFAULT 0, fee_cents INTEGER NOT NULL DEFAULT 0,
                discount_cents INTEGER NOT NULL DEFAULT 0,
                exclude_from_stats INTEGER NOT NULL DEFAULT 0,
                exclude_from_budget INTEGER NOT NULL DEFAULT 0,
                currency TEXT, to_amount_cents INTEGER, refund_of_id INTEGER,
                deleted_at TEXT)''');
              await db.insert('books',
                  {'title': '日常', 'glyph': '📘', 'base_currency': 'CNY'});
              await db.insert('pockets', {
                'title': '现金', 'glyph': '💵', 'kind': 'cash',
                'opening_cents': 0, 'book_id': 1,
              });
              await db.insert('buckets', {
                'title': '吃饭', 'glyph': '🍜', 'flow': 'out', 'book_id': 1,
              });
              await db.insert('entries', {
                'pocket_id': 1, 'flow': 'out', 'amount_cents': 1000,
                'memo': '余额校准', 'day': '2026-10-03',
                'created_at': '2026-10-03T10:00:00', 'book_id': 1,
                'exclude_from_stats': 1,
              });
              await db.insert('entries', {
                'pocket_id': 1, 'flow': 'out', 'amount_cents': 2000,
                'memo': '买菜', 'day': '2026-10-04',
                'created_at': '2026-10-04T10:00:00', 'book_id': 1,
              });
            },
          ));
      await legacy.close();

      final upgraded = await LedgerStore.open(path: path);
      addTearDown(upgraded.close);

      final only = await upgraded.entriesOfPocket(1, onlyAdjustment: true);
      expect(only.length, 1, reason: '升级应把老的「余额校准」流水认成校准');
      expect(only.first.memo, '余额校准');
      // 普通流水不能被误伤
      expect((await upgraded.entriesOfPocket(1)).length, 2);
    });
  });
}

