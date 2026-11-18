import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/ui/subscriptions_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 会员卡上「对应的那笔账」：关联能落库、账被删了也认得、点开看得到明细。
///
/// 订到期的口径在 subscription_test.dart、页面冒烟在 subscriptions_page_test.dart。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('关联落库', () {
    late Directory tmp;
    late LedgerStore store;
    late int bookId;
    late int pocketId;
    late int bucketId;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jianji-link-');
      // 不 seed 示例账户：first 要稳定指向下面新建的「微信零钱」
      store = await LedgerStore.open(
          path: '${tmp.path}/test.db', withSamplePockets: false);
      bookId = (await store.books()).first.id;
      await store.addPocket(
        bookId: bookId,
        title: '微信零钱',
        glyph: '💚',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      pocketId = (await store.allPockets()).first.id;
      await store.addBucket(
          bookId: bookId, title: '订阅', glyph: '📺', flow: 'out');
      bucketId = (await store.buckets(bookId, 'out'))
          .firstWhere((b) => b.title == '订阅')
          .id;
    });

    tearDown(() async {
      await store.close();
      await tmp.delete(recursive: true);
    });

    Future<int> seedEntry({String memo = '网易云年卡', int cents = 23800}) =>
        store.addEntry(
          bookId: bookId,
          pocketId: pocketId,
          bucketId: bucketId,
          flow: 'out',
          amountCents: cents,
          memo: memo,
          day: DateTime(2026, 11, 1),
        );

    Subscription sub({int entryId = 0, int fee = 23800}) => Subscription(
          id: 0,
          bookId: bookId,
          name: '网易云音乐',
          glyph: '🎵',
          startDay: '2026-11-01',
          months: 12,
          feeCents: fee,
          autoRenew: true,
          note: '',
          remindDays: 7,
          entryId: entryId,
        );

    test('关联的账 id 能存能读，linked 跟着变', () async {
      final eid = await seedEntry();
      await store.addSubscription(sub(entryId: eid));
      final s = (await store.subscriptions(bookId)).first;
      expect(s.entryId, eid);
      expect(s.linked, isTrue);

      final map = await store.entriesByIds([eid]);
      expect(map[eid]?.memo, '网易云年卡');
      expect(map[eid]?.amountCents, 23800);
    });

    test('没关联时 entryId = 0，linked 为假', () async {
      await store.addSubscription(sub());
      final s = (await store.subscriptions(bookId)).first;
      expect(s.entryId, 0);
      expect(s.linked, isFalse);
      expect(await store.entriesByIds([s.entryId]), isEmpty,
          reason: '0 不该去查库');
    });

    test('账删进回收站后仍取得到（卡片才能提示「已删除」）', () async {
      final eid = await seedEntry();
      await store.addSubscription(sub(entryId: eid));
      await store.deleteEntry(eid);

      final map = await store.entriesByIds([eid]);
      expect(map[eid], isNotNull, reason: '软删的账也要能按 id 取回来');
      expect(map[eid]!.deletedAt, isNotNull);

      // 订阅本身不受影响：删的是流水，不是会员卡
      expect((await store.subscriptions(bookId)).first.entryId, eid);
    });

    test('取消关联后 entryId 归零，那笔账还在', () async {
      final eid = await seedEntry();
      final id = await store.addSubscription(sub(entryId: eid));
      final s = (await store.subscriptions(bookId)).first;
      await store.updateSubscription(Subscription(
        id: id,
        bookId: bookId,
        name: s.name,
        glyph: s.glyph,
        startDay: s.startDay,
        months: s.months,
        feeCents: s.feeCents,
        autoRenew: s.autoRenew,
        note: s.note,
        remindDays: s.remindDays,
      ));

      expect((await store.subscriptions(bookId)).first.entryId, 0);
      expect((await store.entriesByIds([eid])).containsKey(eid), isTrue,
          reason: '取消关联不该顺手删账');
    });

    test('备份带上 entry_id：导出再导入后还连着', () async {
      final eid = await seedEntry();
      await store.addSubscription(sub(entryId: eid));
      final raw = await store.exportJson();
      expect(raw, contains('entry_id'));

      await store.importJson(raw);
      expect((await store.subscriptions(bookId)).first.entryId, eid);
    });

    test('老库（v23，没有 entry_id 列）打开后自动补列，写入不炸', () async {
      final dir = await Directory.systemTemp.createTemp('jianji-mig-');
      final path = '${dir.path}/old.db';
      // 手工造一个 v23 的库：只有 subscriptions 的旧表结构。
      // 其余表交给升级时的 CREATE TABLE IF NOT EXISTS 补齐。
      final raw = await databaseFactory.openDatabase(path,
          options: OpenDatabaseOptions(
            version: 23,
            onCreate: (db, v) => db.execute('''
              CREATE TABLE subscriptions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                book_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                glyph TEXT NOT NULL DEFAULT '📺',
                start_day TEXT NOT NULL,
                months INTEGER NOT NULL DEFAULT 12,
                fee_cents INTEGER NOT NULL DEFAULT 0,
                auto_renew INTEGER NOT NULL DEFAULT 0,
                note TEXT NOT NULL DEFAULT '',
                remind_days INTEGER NOT NULL DEFAULT 7
              )
            '''),
          ));
      await raw.close();

      final old = await LedgerStore.open(path: path, withSamplePockets: false);
      final bid = (await old.books()).first.id;
      // map 里带 entry_id，表没这一列就会抛 no such column —— 这就是断言点
      final id = await old.addSubscription(Subscription(
        id: 0,
        bookId: bid,
        name: '老会员',
        glyph: '📺',
        startDay: '2026-11-01',
        months: 12,
        feeCents: 10000,
        autoRenew: true,
        note: '',
        remindDays: 7,
        entryId: 0,
      ));
      final read = (await old.subscriptions(bid)).firstWhere((s) => s.id == id);
      expect(read.name, '老会员');
      expect(read.entryId, 0, reason: '老数据没有关联，默认 0');
      await old.close();
      await dir.delete(recursive: true);
    });
  });

  testWidgets('卡片显示关联的账，点开能看到明细', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('jianji-link-ui-'));
    final path = '${tmp!.path}/ui.db';

    await tester.runAsync(() async {
      final s =
          await LedgerStore.open(path: path, withSamplePockets: false);
      final book = (await s.books()).first;
      await s.addPocket(
        bookId: book.id,
        title: '微信零钱',
        glyph: '💚',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      final pocket = (await s.allPockets()).first;
      await s.addBucket(bookId: book.id, title: '订阅', glyph: '📺', flow: 'out');
      final bucket = (await s.buckets(book.id, 'out'))
          .firstWhere((b) => b.title == '订阅');
      final eid = await s.addEntry(
        bookId: book.id,
        pocketId: pocket.id,
        bucketId: bucket.id,
        flow: 'out',
        amountCents: 23800,
        memo: '网易云年卡',
        day: DateTime(2026, 11, 1),
      );
      await s.addSubscription(Subscription(
        id: 0,
        bookId: book.id,
        name: '网易云音乐',
        glyph: '🎵',
        startDay: '2026-11-01',
        months: 12,
        feeCents: 23800,
        autoRenew: false,
        note: '',
        remindDays: 7,
        entryId: eid,
      ));
      await s.close();
    });

    final container = ProviderContainer(
        overrides: [databasePathProvider.overrideWithValue(path)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SubscriptionsPage()),
    ));
    await tester.pump();
    await drain(tester);

    expect(find.text('网易云音乐'), findsOneWidget);
    // 卡片上的金额取自那笔账（不是表单里填的费用）
    expect(find.textContaining('11-01 · ¥238 · 网易云年卡'), findsOneWidget);

    await tester.tap(find.textContaining('11-01 · ¥238 · 网易云年卡'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await drain(tester, rounds: 8);

    await drain(tester, rounds: 16);

    expect(find.text('这笔账'), findsOneWidget, reason: '点会员要能看到对应的那笔账');
    expect(find.text('订阅'), findsWidgets, reason: '弹层里要有分类名');
    expect(find.text('微信零钱'), findsOneWidget, reason: '弹层里要有账户');
    expect(find.text('-¥238'), findsOneWidget);
    expect(find.text('编辑这笔账'), findsOneWidget);

    await drain(tester);
  });

  testWidgets('表单里能关联一笔账，也能取消关联', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final tmp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('jianji-link-form-'));
    final path = '${tmp!.path}/form.db';

    await tester.runAsync(() async {
      final s =
          await LedgerStore.open(path: path, withSamplePockets: false);
      final book = (await s.books()).first;
      await s.addPocket(
        bookId: book.id,
        title: '微信零钱',
        glyph: '💚',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      final pocket = (await s.allPockets()).first;
      await s.addBucket(bookId: book.id, title: '订阅', glyph: '📺', flow: 'out');
      final bucket = (await s.buckets(book.id, 'out'))
          .firstWhere((b) => b.title == '订阅');
      await s.addEntry(
        bookId: book.id,
        pocketId: pocket.id,
        bucketId: bucket.id,
        flow: 'out',
        amountCents: 23800,
        memo: '网易云年卡',
        day: DateTime(2026, 11, 1),
      );
      await s.addSubscription(Subscription(
        id: 0,
        bookId: book.id,
        name: '网易云音乐',
        glyph: '🎵',
        startDay: '2026-11-01',
        months: 12,
        feeCents: 0,
        autoRenew: false,
        note: '',
        remindDays: 7,
      ));
      await s.close();
    });

    final container = ProviderContainer(
        overrides: [databasePathProvider.overrideWithValue(path)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SubscriptionsPage()),
    ));
    await tester.pump();
    await drain(tester);

    // 打开编辑（点卡片本体）
    await tester.tap(find.text('网易云音乐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await drain(tester, rounds: 10);

    expect(find.text('编辑会员'), findsOneWidget);
    expect(find.text('选一笔已有的支出'), findsOneWidget, reason: '没关联时给个可点的入口');

    // 打开挑选面板
    await tester.tap(find.text('选一笔已有的支出'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await drain(tester, rounds: 10);

    expect(find.text('挑一笔账'), findsOneWidget);
    expect(find.text('不关联账单'), findsOneWidget);

    await tester.tap(find.textContaining('网易云年卡').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await drain(tester, rounds: 8);

    // 表单行变成选中那笔账，费用框跟上一笔账的金额
    expect(find.textContaining('11-01 · ¥238 · 网易云年卡'), findsOneWidget);
    expect(find.text('取消关联'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pump();
    await drain(tester);

    // ⚠️ 别在这里再 LedgerStore.open(path) 一次：sqflite 的 singleInstance
    // 会让它拿到和 provider **同一个** Database，close() 一调用 provider 那边
    // 就变成 database_closed（本测试第一版就栽在这）。
    final saved = await tester.runAsync(() async {
      final s = await container.read(storeProvider.future);
      return s.subscriptions((await s.books()).first.id);
    });
    expect(saved!.first.entryId, greaterThan(0), reason: '关联要落库');
    expect(saved.first.feeCents, 23800, reason: '费用跟关联的账对齐');

    // 再进去取消关联
    await tester.tap(find.text('网易云音乐'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await drain(tester, rounds: 10);

    await tester.tap(find.text('取消关联'));
    await tester.pump();
    expect(find.text('选一笔已有的支出'), findsOneWidget);

    await tester.tap(find.text('保存'));
    await tester.pump();
    await drain(tester);

    final cleared = await tester.runAsync(() async {
      final s = await container.read(storeProvider.future);
      return s.subscriptions((await s.books()).first.id);
    });
    expect(cleared!.first.entryId, 0, reason: '取消关联要落库');
    expect(cleared.first.feeCents, 23800, reason: '取消关联不清空费用数字');

    await drain(tester);
  });

  // ⚠️ 这条必须放文件最后：字号设在 platformDispatcher 上，
  // 刻意不在 addTearDown 里清（清空会让挂着的组件树重建，
  // 又起新的 provider 查询，留下跑不完的 sqflite 定时器 ——
  // 和 large_text_test 里同一个坑）。
  testWidgets('大字号（1.6x）下卡片和「这笔账」弹层都不溢出', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;

    final tmp = await tester.runAsync(
        () => Directory.systemTemp.createTemp('jianji-link-big-'));
    final path = '${tmp!.path}/big.db';

    await tester.runAsync(() async {
      final s =
          await LedgerStore.open(path: path, withSamplePockets: false);
      final book = (await s.books()).first;
      await s.addPocket(
        bookId: book.id,
        title: '微信零钱',
        glyph: '💚',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      final pocket = (await s.allPockets()).first;
      await s.addBucket(bookId: book.id, title: '订阅', glyph: '📺', flow: 'out');
      final bucket = (await s.buckets(book.id, 'out'))
          .firstWhere((b) => b.title == '订阅');
      final eid = await s.addEntry(
        bookId: book.id,
        pocketId: pocket.id,
        bucketId: bucket.id,
        flow: 'out',
        amountCents: 23800,
        memo: '网易云年卡自动续费这一笔',
        day: DateTime(2026, 11, 1),
      );
      await s.addSubscription(Subscription(
        id: 0,
        bookId: book.id,
        name: '网易云音乐年度会员',
        glyph: '🎵',
        startDay: '2026-11-01',
        months: 12,
        feeCents: 23800,
        autoRenew: true,
        note: '和家人共用',
        remindDays: 7,
        entryId: eid,
      ));
      await s.close();
    });

    final container = ProviderContainer(
        overrides: [databasePathProvider.overrideWithValue(path)]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SubscriptionsPage()),
    ));
    await tester.pump();
    await drain(tester);

    expect(tester.takeException(), isNull, reason: '1.6x 字号下订阅卡片不应溢出');

    await tester.tap(find.textContaining('11-01 · ¥238'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await drain(tester, rounds: 10);

    expect(tester.takeException(), isNull, reason: '1.6x 字号下账单弹层不应溢出');

    await drain(tester);
  });
}

/// 真实 IO + 假时钟交替推进（sqflite 的 10s timer 需要真实时间）。
Future<void> drain(WidgetTester tester, {int rounds = 26}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 200));
}
