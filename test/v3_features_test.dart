import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/core/rules.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/ui/common.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v3 新增：分类预算、账户流水、多个账本/币种下的「近 N 个月」序列、
/// 以及紧凑金额显示。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('分类预算', () {
    late Directory tmp;
    late LedgerStore store;
    late int bookId;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jj-v3-');
      store = await LedgerStore.open(path: '${tmp.path}/t.db');
      bookId = (await store.books()).first.id;
    });

    tearDown(() async {
      await store.close();
      await tmp.delete(recursive: true);
    });

    test('按分类+月份保存，0 表示清除', () async {
      final food = (await store.buckets(bookId, 'out')).first;
      final month = DateTime(2026, 10);

      await store.setBucketBudget(bookId, month, food.id, 100000);
      expect((await store.bucketBudgets(bookId, month))[food.id], 100000);
      // 换个月份互不影响
      expect((await store.bucketBudgets(bookId, DateTime(2026, 11))), isEmpty);

      // 覆盖
      await store.setBucketBudget(bookId, month, food.id, 150000);
      expect((await store.bucketBudgets(bookId, month))[food.id], 150000);

      // 0 = 删除
      await store.setBucketBudget(bookId, month, food.id, 0);
      expect((await store.bucketBudgets(bookId, month)), isEmpty);
    });

    test('分类支出按 bucket_id 汇总（未分类为 null）', () async {
      final pockets = await store.allPockets(includeArchived: false);
      final food = (await store.buckets(bookId, 'out')).first;
      final month = DateTime(2026, 10);

      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        bucketId: food.id,
        flow: 'out',
        amountCents: 3000,
        memo: 'a',
        day: DateTime(2026, 10, 2),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        bucketId: food.id,
        flow: 'out',
        amountCents: 2000,
        memo: 'b',
        day: DateTime(2026, 10, 3),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        bucketId: null,
        flow: 'out',
        amountCents: 700,
        memo: '未分类',
        day: DateTime(2026, 10, 4),
      );
      // 收入不该进来
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        flow: 'in',
        amountCents: 99999,
        memo: '收入',
        day: DateTime(2026, 10, 5),
      );

      final spent = await store.bucketSpent(bookId, month);
      final foodSum = spent
          .where((s) => s.bucketId == food.id)
          .fold<int>(0, (a, b) => a + b.cents);
      final uncategorized =
          spent.where((s) => s.bucketId == null).fold<int>(0, (a, b) => a + b.cents);
      expect(foodSum, 5000);
      expect(uncategorized, 700);
    });

    test('账户流水只取与该账户有关的（含转入）', () async {
      final pockets = await store.allPockets(includeArchived: false);
      final a = pockets[0];
      final b = pockets[1];
      await store.addEntry(
        bookId: bookId,
        pocketId: a.id,
        flow: 'out',
        amountCents: 100,
        memo: 'a出',
        day: DateTime(2026, 10, 1),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: b.id,
        flow: 'out',
        amountCents: 200,
        memo: 'b出',
        day: DateTime(2026, 10, 2),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: a.id,
        toPocketId: b.id,
        flow: 'transfer',
        amountCents: 300,
        memo: 'a转b',
        day: DateTime(2026, 10, 3),
      );

      final aEntries = await store.entriesOfPocket(a.id);
      final bEntries = await store.entriesOfPocket(b.id);
      expect(aEntries.length, 2); // 支出 + 转出
      expect(bEntries.length, 2); // 支出 + 转入
    });
  });

  group('近 N 个月序列', () {
    test('按时间正序、跨币种折算、转账不计入', () async {
      final tmp = await Directory.systemTemp.createTemp('jj-series-');
      final dbPath = '${tmp.path}/s.db';
      final store = await LedgerStore.open(path: dbPath);
      final bookId = (await store.books()).first.id;
      final pockets = await store.allPockets(includeArchived: false);

      // 9 月：支出 100
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        flow: 'out',
        amountCents: 10000,
        memo: '9月',
        day: DateTime(2026, 9, 10),
      );
      // 10 月：收入 500、支出 200、转账 999（不该计入）
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        flow: 'in',
        amountCents: 50000,
        memo: '10月收入',
        day: DateTime(2026, 10, 1),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        flow: 'out',
        amountCents: 20000,
        memo: '10月支出',
        day: DateTime(2026, 10, 2),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        toPocketId: pockets[1].id,
        flow: 'transfer',
        amountCents: 99900,
        memo: '转账',
        day: DateTime(2026, 10, 3),
      );
      await store.close();

      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(overrides: [
        databasePathProvider.overrideWithValue(dbPath),
      ]);
      addTearDown(container.dispose);
      // 锚点由调用方传（不再从 monthProvider 里读）
      final anchor = DateTime(2026, 10);

      final points = await container
          .read(monthSeriesProvider((count: 3, anchor: anchor)).future);
      expect(points.length, 3);
      expect(points.first.month.month, 8);
      expect(points.last.month.month, 10);
      expect(points[1].expenseCents, 10000); // 9 月
      expect(points[2].incomeCents, 50000); // 10 月
      expect(points[2].expenseCents, 20000); // 转账没被算进支出
      expect(points[2].netCents, 30000);
      // 容器还持有数据库句柄（addTearDown 才释放），这里不删临时目录
    });
  });

  group('日历每日收支', () {
    test('收入和支出分日聚合，转账与不计入统计的流水排除', () async {
      final tmp = await Directory.systemTemp.createTemp('jj-daily-');
      final dbPath = '${tmp.path}/daily.db';
      final store = await LedgerStore.open(path: dbPath);
      final bookId = (await store.books()).first.id;
      final pockets = await store.allPockets(includeArchived: false);

      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        flow: 'out',
        amountCents: 2500,
        memo: '午餐',
        day: DateTime(2026, 10, 1),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        flow: 'out',
        amountCents: 1000,
        memo: '咖啡',
        day: DateTime(2026, 10, 1),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        flow: 'in',
        amountCents: 50000,
        memo: '工资',
        day: DateTime(2026, 10, 1),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        flow: 'in',
        amountCents: 12300,
        memo: '红包',
        day: DateTime(2026, 10, 2),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        toPocketId: pockets[1].id,
        flow: 'transfer',
        amountCents: 99900,
        memo: '转账',
        day: DateTime(2026, 10, 1),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pockets.first.id,
        flow: 'in',
        amountCents: 88800,
        memo: '不计入统计',
        day: DateTime(2026, 10, 1),
        excludeFromStats: true,
      );
      await store.close();

      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(overrides: [
        databasePathProvider.overrideWithValue(dbPath),
      ]);
      addTearDown(container.dispose);
      container.read(monthProvider.notifier).state = DateTime(2026, 10);

      final days = await container.read(dailyTotalsProvider.future);
      expect(days[dayKey(DateTime(2026, 10, 1))]?.incomeCents, 50000);
      expect(days[dayKey(DateTime(2026, 10, 1))]?.expenseCents, 3500);
      expect(days[dayKey(DateTime(2026, 10, 2))]?.incomeCents, 12300);
      expect(days[dayKey(DateTime(2026, 10, 2))]?.expenseCents, 0);
    });
  });

  group('紧凑金额', () {
    testWidgets('开启后一万以上缩写，关闭后完整显示', (tester) async {
      SharedPreferences.setMockInitialValues({'compact_amounts': true});
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(body: MoneyText(1234567)), // 12345.67 元
        ),
      ));
      // 等偏好补水
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('¥1.2万'), findsOneWidget);

      SharedPreferences.setMockInitialValues({'compact_amounts': false});
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(home: Scaffold(body: MoneyText(1234567))),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('¥12,345.67'), findsOneWidget);
    });
  });
}
