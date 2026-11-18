import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/due_reminders.dart';
import 'package:jianji/core/subscription.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 会员订阅的口径：到期日怎么算、倒计时怎么显示、排序和提醒。
///
/// 最容易错的是「月末」：Dart 的 `DateTime(2026, 2, 31)` 会自动顺延到 3 月 3 日，
/// 1 月 31 日开的年卡就会莫名多出 3 天。这里逐条钉住月末对齐。
Subscription sub({
  int id = 1,
  String startDay = '2026-01-31',
  int months = 1,
  int fee = 19800,
  int remind = 7,
  bool autoRenew = true,
  String name = 'Netflix',
}) =>
    Subscription(
      id: id,
      bookId: 1,
      name: name,
      glyph: '📺',
      startDay: startDay,
      months: months,
      feeCents: fee,
      autoRenew: autoRenew,
      note: '',
      remindDays: remind,
    );

void main() {
  group('到期日：月末对齐', () {
    test('1/31 + 1 个月 = 2/28（平年）', () {
      expect(LedgerStore.addMonths(DateTime(2026, 1, 31), 1),
          DateTime(2026, 2, 28));
    });

    test('1/31 + 1 个月 = 2/29（闰年）', () {
      expect(LedgerStore.addMonths(DateTime(2028, 1, 31), 1),
          DateTime(2028, 2, 29));
    });

    test('8/31 + 3 个月 = 11/30', () {
      expect(LedgerStore.addMonths(DateTime(2026, 8, 31), 3),
          DateTime(2026, 11, 30));
    });

    test('跨年：11/15 + 3 个月 = 次年 2/15', () {
      expect(LedgerStore.addMonths(DateTime(2026, 11, 15), 3),
          DateTime(2027, 2, 15));
    });

    test('整年：3/5 + 12 个月 = 次年 3/5', () {
      expect(LedgerStore.addMonths(DateTime(2026, 3, 5), 12),
          DateTime(2027, 3, 5));
    });

    test('自定义 15 个月：1/31 + 15 = 次年 4/30', () {
      expect(LedgerStore.addMonths(DateTime(2026, 1, 31), 15),
          DateTime(2027, 4, 30));
    });

    test('小于 1 个月按 1 算（不会让到期日等于开卡日）', () {
      expect(LedgerStore.addMonths(DateTime(2026, 1, 15), 0),
          DateTime(2026, 2, 15));
      expect(LedgerStore.addMonths(DateTime(2026, 1, 15), -3),
          DateTime(2026, 2, 15));
    });
  });

  group('倒计时', () {
    final today = DateTime(2026, 5, 1, 15, 30); // 带时分，验证不会算成半天

    test('还有 N 天', () {
      final s = sub(startDay: '2025-05-10', months: 12, remind: 7);
      final cd = countdownOf(s, today); // 到期 2026-05-10
      expect(cd.days, 9);
      expect(cd.state, SubscriptionState.normal);
      expect(cd.text, '还有 9 天到期');
      expect(cd.urgent, isFalse);
    });

    test('进入提醒窗口算 soon', () {
      final s = sub(startDay: '2025-05-05', months: 12, remind: 7);
      final cd = countdownOf(s, today); // 到期 2026-05-05
      expect(cd.days, 4);
      expect(cd.state, SubscriptionState.soon);
      expect(cd.urgent, isTrue);
    });

    test('今天到期', () {
      final s = sub(startDay: '2025-05-01', months: 12);
      final cd = countdownOf(s, today);
      expect(cd.days, 0);
      expect(cd.state, SubscriptionState.today);
      expect(cd.text, '今天到期');
      expect(cd.urgent, isTrue);
    });

    test('已过期显示负数天数', () {
      final s = sub(startDay: '2025-04-20', months: 12);
      final cd = countdownOf(s, today); // 到期 2026-04-20
      expect(cd.days, -11);
      expect(cd.state, SubscriptionState.expired);
      expect(cd.text, '已过期 11 天');
    });

    test('提醒天数设 0 时永远不会 soon（但过期照样标红）', () {
      final s = sub(startDay: '2025-05-05', months: 12, remind: 0);
      expect(countdownOf(s, today).state, SubscriptionState.normal);
      expect(countdownOf(sub(startDay: '2025-04-20', months: 12), today).state,
          SubscriptionState.expired);
    });
  });

  group('排序与即将到期计数', () {
    test('按到期日升序，同一天按 id', () {
      final a = sub(id: 3, startDay: '2026-06-01', months: 1); // 7/1
      final b = sub(id: 1, startDay: '2026-01-01', months: 1); // 2/1
      final c = sub(id: 2, startDay: '2026-05-01', months: 2); // 7/1
      final list = [a, b, c]..sort(compareSubscriptions);
      expect(list.map((e) => e.id), [1, 2, 3]);
    });

    test('即将到期数不含已过期', () {
      final today = DateTime(2026, 5, 1);
      final list = [
        sub(id: 1, startDay: '2025-04-20', months: 12), // 已过期
        sub(id: 2, startDay: '2025-05-20', months: 12), // 19 天后
        sub(id: 3, startDay: '2025-12-01', months: 12), // 很远
      ];
      expect(expiringSoonCount(list, today, days: 30), 1);
    });
  });

  group('落库与备份', () {
    late Directory tmp;
    late LedgerStore store;
    late int bookId;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jianji-subs-');
      store = await LedgerStore.open(path: '${tmp.path}/test.db');
      bookId = (await store.books()).first.id;
    });

    tearDown(() async {
      await store.close();
      await tmp.delete(recursive: true);
    });

    Subscription draft({
      String name = '网易云音乐',
      String startDay = '2026-01-31',
      int months = 12,
      int fee = 17800,
      int remind = 7,
    }) =>
        Subscription(
          id: 0,
          bookId: bookId,
          name: name,
          glyph: '🎵',
          startDay: startDay,
          months: months,
          feeCents: fee,
          autoRenew: true,
          note: '年付',
          remindDays: remind,
        );

    test('新增后能读回来，字段一个不少', () async {
      final id = await store.addSubscription(draft());
      final list = await store.subscriptions(bookId);
      expect(list.length, 1);
      final s = list.first;
      expect(s.id, id);
      expect(s.name, '网易云音乐');
      expect(s.glyph, '🎵');
      expect(s.startDay, '2026-01-31');
      expect(s.months, 12);
      expect(s.feeCents, 17800);
      expect(s.autoRenew, isTrue);
      expect(s.note, '年付');
      expect(s.remindDays, 7);
      expect(s.dueDate, DateTime(2027, 1, 31));
    });

    test('列表按到期日升序，改时长后位置跟着变', () async {
      // A 到期 2026-02-01，B 到期 2026-12-01
      await store.addSubscription(
          draft(name: 'A', startDay: '2026-01-01', months: 1));
      final bId = await store.addSubscription(
          draft(name: 'B', startDay: '2026-06-01', months: 6));
      expect((await store.subscriptions(bookId)).map((e) => e.name), ['A', 'B']);

      final b = (await store.subscriptions(bookId)).firstWhere((e) => e.id == bId);
      await store.updateSubscription(Subscription(
        id: b.id,
        bookId: b.bookId,
        name: b.name,
        glyph: b.glyph,
        // 开卡日期改到去年 → 到期 2025-12-01，应排到最前
        startDay: '2025-06-01',
        months: b.months,
        feeCents: b.feeCents,
        autoRenew: b.autoRenew,
        note: b.note,
        remindDays: b.remindDays,
      ));
      expect((await store.subscriptions(bookId)).map((e) => e.name), ['B', 'A']);
    });

    test('删除后不再出现', () async {
      final id = await store.addSubscription(draft());
      await store.deleteSubscription(id);
      expect(await store.subscriptions(bookId), isEmpty);
    });

    test('备份导出 / 导入往返保留订阅', () async {
      await store.addSubscription(draft());
      final json = await store.exportJson();
      await store.deleteSubscription((await store.subscriptions(bookId)).first.id);
      expect(await store.subscriptions(bookId), isEmpty);

      await store.importJson(json);
      final back = await store.subscriptions(bookId);
      expect(back.length, 1);
      expect(back.first.name, '网易云音乐');
      expect(back.first.dueDate, DateTime(2027, 1, 31));
    });

    test('订阅进入到期提醒，并且用自己的提前天数', () async {
      final reminders = buildDueReminders(
        const [],
        const [],
        const [],
        now: DateTime(2026, 5, 1),
        leadDays: 3,
        symbol: '¥',
        subscriptions: [
          sub(startDay: '2025-05-10', months: 12, remind: 10, fee: 19800),
        ],
      );
      expect(reminders.length, 1);
      expect(reminders.first.kind, 'subscription');
      expect(reminders.first.occurrence, DateTime(2026, 5, 10));
      expect(reminders.first.leadDays, 10, reason: '每项订阅用自己的提前天数');
      expect(reminders.first.body, contains('¥198'));
    });

    test('提醒设为 0 的订阅不排通知', () async {
      final reminders = buildDueReminders(
        const [],
        const [],
        const [],
        now: DateTime(2026, 5, 1),
        leadDays: 3,
        symbol: '¥',
        subscriptions: [sub(startDay: '2025-05-10', months: 12, remind: 0)],
      );
      expect(reminders, isEmpty);
    });

    test('远期订阅也能排进通知（不受 45 天窗口限制）', () async {
      final reminders = buildDueReminders(
        const [],
        const [],
        const [],
        now: DateTime(2026, 5, 1),
        leadDays: 3,
        symbol: '¥',
        subscriptions: [sub(startDay: '2026-02-01', months: 12, remind: 7)],
      );
      expect(reminders.single.occurrence, DateTime(2027, 2, 1));
    });
  });
}
