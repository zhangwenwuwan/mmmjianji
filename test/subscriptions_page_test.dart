import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/ui/subscriptions_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 会员订阅页的冒烟：空态、新增表单、保存后卡片出现并按到期排序。
///
/// 数据层（月末对齐 / 备份 / 提醒）在 subscription_test.dart 里逐条钉住，
/// 这里只保证「用户点得到、填得进、存得下」。
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
  });

  WidgetController.hitTestWarningShouldBeFatal = true;

  Future<void> drain(WidgetTester tester, {int rounds = 26}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('空态 → 新增 → 列表出现卡片', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 清掉历史订阅，保证从空态开始
    await tester.runAsync(() async {
      final store = await LedgerStore.open();
      final book = (await store.books()).first;
      for (final s in await store.subscriptions(book.id)) {
        await store.deleteSubscription(s.id);
      }
      await store.close();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SubscriptionsPage()),
    ));
    await tester.pump();
    await drain(tester);

    expect(find.text('会员订阅管理'), findsOneWidget);
    expect(find.text('还没有会员订阅'), findsOneWidget);

    // 右上角 + 打开新增表单
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await drain(tester, rounds: 10);

    expect(find.text('新增会员'), findsOneWidget);
    expect(find.text('会员名称'), findsOneWidget);
    expect(find.text('到期日'), findsOneWidget, reason: '表单里要能预览算出来的到期日');

    // 填名称与时长（TextField 顺序：名称 / 月数 / 费用 / 提前天数 / 备注）
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(5));
    await tester.enterText(fields.at(0), 'Netflix');
    await tester.pump();
    await tester.enterText(fields.at(1), '12');
    await tester.pump();
    await tester.enterText(fields.at(2), '198');
    await tester.pump();

    // 到期日预览应该跟着算出来（今年 + 12 个月，和今天同月同日）
    final preview = find.textContaining(
        '${DateTime.now().year + 1}-${DateTime.now().month.toString().padLeft(2, '0')}');
    expect(preview, findsWidgets, reason: '选了 12 个月，到期日应是明年的同一天');

    await tester.tap(find.text('保存'));
    await tester.pump();
    await drain(tester);

    // 列表里出现这张卡
    expect(find.text('Netflix'), findsOneWidget);
    expect(find.text('自动续费'), findsOneWidget, reason: '默认自动续费，卡片上要标出来');
    expect(find.textContaining('到期'), findsWidgets);

    // 再进一次页面（重建 container），确认真的落库而不是只留在内存
    final back = await tester.runAsync(() async {
      final store = await LedgerStore.open();
      final book = (await store.books()).first;
      final list = await store.subscriptions(book.id);
      await store.close();
      return list;
    });
    expect(back, isNotNull);
    expect(back!.length, 1);
    expect(back.first.name, 'Netflix');
    expect(back.first.months, 12);
    expect(back.first.feeCents, 19800);

    await drain(tester);
  });

  testWidgets('名称留空时保存会被拦下，弹层不关闭', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: SubscriptionsPage()),
    ));
    await tester.pump();
    await drain(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await drain(tester, rounds: 10);

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('请填写会员名称'), findsOneWidget);
    expect(find.text('新增会员'), findsOneWidget, reason: '校验失败不该把弹层关掉');

    await drain(tester, rounds: 10);
  });
}
