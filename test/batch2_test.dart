import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/insight_calc.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/services/auto_backup.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Entry entry(
    DateTime day,
    int cents, {
    String flow = 'out',
    String memo = '',
    int mood = 0,
  }) =>
      Entry(
        id: day.millisecondsSinceEpoch + cents,
        bookId: 1,
        pocketId: 1,
        toPocketId: null,
        bucketId: null,
        flow: flow,
        amountCents: cents,
        memo: memo,
        day: day,
        tags: '',
        reimburse: 0,
        mood: mood,
      );

  group('现金流预测', () {
    test('净流入为正：30 天后更高，最低就是当前', () {
      final f = forecastCashFlow(
        netWorthCents: 100000,
        sampleExpenseCents: 30000,
        sampleIncomeCents: 60000,
        sampleDays: 30,
      );
      expect(f.dailyExpenseCents, 1000); // 30 元/天
      expect(f.dailyNetCents, 1000);
      expect(f.in7Days, 107000);
      expect(f.in30Days, 130000);
      expect(f.lowestCents, 100000);
      expect(f.daysToZero, isNull);
    });

    test('净流出：能算出撑多少天，30 天后为负', () {
      final f = forecastCashFlow(
        netWorthCents: 100000,
        sampleExpenseCents: 90000,
        sampleIncomeCents: 0,
        sampleDays: 30,
      );
      expect(f.dailyNetCents, -3000);
      expect(f.in30Days, 100000 - 90000);
      expect(f.lowestCents, f.in30Days);
      expect(f.daysToZero, 33); // 1000 元 / 每天 30 元 = 33 天
    });

    test('已经负数时，撑 0 天', () {
      final f = forecastCashFlow(
        netWorthCents: -5000,
        sampleExpenseCents: 3000,
        sampleIncomeCents: 0,
        sampleDays: 30,
      );
      expect(f.daysToZero, 0);
    });

    test('样本天数为 0 不会除零崩溃', () {
      final f = forecastCashFlow(
        netWorthCents: 1000,
        sampleExpenseCents: 100,
        sampleIncomeCents: 200,
        sampleDays: 0,
      );
      expect(f.dailyExpenseCents, 100);
    });
  });

  group('订阅识别', () {
    test('同名同额跨三个月 → 命中', () {
      final list = findSubscriptions([
        entry(DateTime(2026, 8, 5), 2500, memo: '视频会员'),
        entry(DateTime(2026, 9, 5), 2500, memo: '视频会员'),
        entry(DateTime(2026, 10, 5), 2500, memo: '视频会员'),
      ]);
      expect(list.length, 1);
      expect(list.first.cents, 2500);
      expect(list.first.months, 3);
      expect(list.first.yearlyCents, 30000);
    });

    test('只有一个月不命中', () {
      final list = findSubscriptions([
        entry(DateTime(2026, 10, 5), 2500, memo: '视频会员'),
        entry(DateTime(2026, 10, 20), 2500, memo: '视频会员'),
      ]);
      expect(list, isEmpty);
    });

    test('金额差超过 1% 不算同一定阅', () {
      final list = findSubscriptions([
        entry(DateTime(2026, 9, 5), 2500, memo: '健身房'),
        entry(DateTime(2026, 10, 5), 9900, memo: '健身房'),
      ]);
      expect(list, isEmpty);
    });

    test('没备注、收入、转账都不参与', () {
      final list = findSubscriptions([
        entry(DateTime(2026, 9, 5), 2500, memo: ''),
        entry(DateTime(2026, 10, 5), 2500, memo: ''),
        entry(DateTime(2026, 9, 6), 2500, memo: '工资', flow: 'in'),
        entry(DateTime(2026, 10, 6), 2500, memo: '工资', flow: 'in'),
        entry(DateTime(2026, 9, 7), 2500, memo: '转存', flow: 'transfer'),
        entry(DateTime(2026, 10, 7), 2500, memo: '转存', flow: 'transfer'),
      ]);
      expect(list, isEmpty);
    });
  });

  group('消费热力', () {
    test('按周一对齐，金额落到正确格子', () {
      // 2026-10-21 是周三
      final today = DateTime(2026, 10, 21);
      final data = buildHeatmap(
        [
          entry(DateTime(2026, 10, 21), 3000),
          entry(today, 2000), // 同一天累加
          entry(DateTime(2026, 10, 19), 500), // 本周一
          entry(DateTime(2026, 8, 1), 999), // 超出 12 周，忽略
        ],
        weeks: 4,
        today: today,
      );
      final lastWeek = data.grid.length - 1;
      expect(data.grid[lastWeek][2], 5000, reason: '周三 = 今天，两笔累加');
      expect(data.grid[lastWeek][0], 500, reason: '周一那笔');
      expect(data.maxCents, 5000);
    });
  });

  group('碳足迹', () {
    test('按分类系数估算，树按年吸收量向上取整', () {
      // 交通 100 元 = 100 * 300g = 30000g
      expect(estimateCarbonGrams('交通', 10000), 30000);
      // 餐饮 100 元 = 15000g
      expect(estimateCarbonGrams('餐饮', 10000), 15000);
      // 未收录的分类按 100g/元
      expect(estimateCarbonGrams('某个新分类', 10000), 10000);
      // 30kg → 需要 2 棵树（每棵 18.3kg）
      expect(treesNeeded(30000), 2);
      expect(treesNeeded(0), 0);
    });
  });

  group('情绪账本', () {
    test('只统计标记过的，后悔率与金额', () {
      final s = moodStats([
        entry(DateTime(2026, 10, 1), 1000, mood: 1),
        entry(DateTime(2026, 10, 2), 2000, mood: 2),
        entry(DateTime(2026, 10, 3), 3000, mood: 3),
        entry(DateTime(2026, 10, 4), 9999), // 未标，不计
      ]);
      expect(s.marked, 3);
      expect(s.worthIt, 1);
      expect(s.neutral, 1);
      expect(s.regret, 1);
      expect(s.regretCents, 3000);
      expect(s.markedCents, 6000);
      expect(s.regretRate, closeTo(1 / 3, 1e-9));
      expect(s.worthRate, closeTo(1 / 3, 1e-9));
    });

    test('一笔没标时比例为 0，不除零', () {
      final s = moodStats([entry(DateTime(2026, 10, 1), 100)]);
      expect(s.marked, 0);
      expect(s.regretRate, 0);
    });
  });

  group('如果模拟器', () {
    test('每天金额 × 天数', () {
      expect(simulateSaving(dailyCents: 1500, days: 365), 547500);
      expect(simulateSaving(dailyCents: 0, days: 365), 0);
      expect(simulateSaving(dailyCents: -100, days: 30), 0);
      expect(simulateSaving(dailyCents: 100, days: 0), 0);
    });
  });

  group('情绪字段落库', () {
    late Directory tmp;
    late LedgerStore store;
    late int bookId;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jj-b2-');
      store = await LedgerStore.open(path: '${tmp.path}/t.db');
      bookId = (await store.books()).first.id;
    });

    tearDown(() async {
      await store.close();
      await tmp.delete(recursive: true);
    });

    test('mood 能存能读能改', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 1000,
        memo: 'x',
        day: DateTime.now(),
        mood: 3,
      );
      var list = await store.entriesRecent(bookId);
      expect(list.length, 1);
      expect(list.first.mood, 3);

      await store.updateEntry(list.first.copyWith(mood: 1));
      list = await store.entriesRecent(bookId);
      expect(list.first.mood, 1);
    });

    test('数据概况与孤儿检查', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 500,
        memo: '正常',
        day: DateTime.now(),
      );
      final counts = await store.tableCounts();
      expect(counts['entries'], 1);
      expect(counts['pockets'], 2);
      expect(counts['books'], 1);

      expect(await store.databaseBytes(), greaterThan(0));

      // 正常数据没有孤儿
      var orphans = await store.orphanStats(bookId);
      expect(orphans.badPocket, 0);
      expect(orphans.badBucket, 0);

      // 构造孤儿：导入一份指向不存在账户的备份
      final json = await store.exportJson();
      final decoded = jsonDecode(json) as Map<String, Object?>;
      final entries = (decoded['entries'] as List).cast<Map<String, Object?>>();
      entries.first['pocket_id'] = 9999;
      entries.first['bucket_id'] = 8888;
      await store.importJson(jsonEncode(decoded));

      orphans = await store.orphanStats(bookId);
      expect(orphans.badPocket, 1);
      expect(orphans.badBucket, 1);

      final fixed = await store.fixOrphans(bookId);
      expect(fixed, greaterThanOrEqualTo(2));
      orphans = await store.orphanStats(bookId);
      expect(orphans.badPocket, 0);
      expect(orphans.badBucket, 0);
    });

    test('自动备份：同一天只写一份，且只保留 5 份', () async {
      // 清掉可能存在的旧备份
      final dir = await AutoBackup.dir();
      for (final f in await dir.list().toList()) {
        if (f is File) await f.delete();
      }

      final first = await AutoBackup.run(store);
      expect(first, isNotNull);
      // 同一天第二次不写
      expect(await AutoBackup.run(store), isNull);
      expect((await AutoBackup.list()).length, 1);

      // 造 8 个旧备份，prune 后应只剩 5 个
      for (var i = 0; i < 8; i++) {
        final f = File('${dir.path}/auto_2020010${i}_0800.json');
        await f.writeAsString('{}');
      }
      await AutoBackup.prune();
      expect((await AutoBackup.list()).length, AutoBackup.keepCount);
    });
  });
}
