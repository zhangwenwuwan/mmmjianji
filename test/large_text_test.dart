import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 大字号适配：系统字体放大后，主要页面不能溢出、不能抛异常。
///
/// 为什么值得单独盯：中文用户（尤其长辈）普遍把系统字体调到「大 / 特大」，
/// 而记账 App 全是"标签 + 金额 + 按钮"的紧凑行，字号一放大最容易挤爆。
/// 这类问题在默认字号的测试里**永远看不到**，只有真机 + 大字才会露出来。
///
/// Flutter 的布局溢出会走 FlutterError.reportError，widget 测试里用
/// `tester.takeException()` 就能抓到 —— 所以每访问一个页面都断言它为 null。
///
/// 两档都测：
/// - 1.3 = Android「大」，日常最常用；
/// - 2.0 = 「特大」，日历格子这种固定高度的版式压力最大。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});
    final dir = await databaseFactory.getDatabasesPath();
    final dbPath = '$dir/jianji_ledger.db';
    try {
      await databaseFactory.deleteDatabase(dbPath);
    } catch (_) {
      // 删不掉就用旧库：断言只看"不溢出"
    }
    await _seedWorstCase(dbPath);
  });

  /// 交替推进真实时间与假时钟。
  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> boot(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 80));
    }
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 只推进**真实时间**、不推假时钟：让 sqflite 还在跑的查询真正跑完。
  /// pump 推的是假时钟，事务定时器靠真实完成回调取消，两者不能互相替代。
  Future<void> drainReal(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    await tester.pump();
  }

  /// 设字号。刻意**不**在 addTearDown 里清：清空会让还挂着的组件树重建一次，
  /// 重建又起新的 provider 查询，测试结束时反而留下未完成的 sqflite 定时器。
  void useTextScale(WidgetTester tester, double scale) {
    tester.platformDispatcher.textScaleFactorTestValue = scale;
  }

  /// 把四个 tab + 日历页 + 记账页 + 预算页都点一遍，每步断言不抛异常。
  Future<void> visitAllPages(WidgetTester tester, {required String tag}) async {
    // 四个 tab
    for (final label in ['统计', '资产', '我的', '首页']) {
      await tester.tap(find.text(label).last);
      await tester.pump();
      await settle(tester, rounds: 10);
      expect(tester.takeException(), isNull, reason: '$tag：$label 页不应溢出');
    }

    // 日历：格子固定 48 高、三行文字，是版式压力最大的页面
    await tester.tap(find.byTooltip('日历').first);
    await tester.pump();
    await settle(tester, rounds: 14);
    expect(tester.takeException(), isNull, reason: '$tag：日历页不应溢出');
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await settle(tester, rounds: 10);

    // 记账页：金额键盘 + 分类格 + chip 行
    await tester.tap(find.byIcon(Icons.add).last);
    await tester.pump();
    await settle(tester, rounds: 14);
    expect(tester.takeException(), isNull, reason: '$tag：记账页不应溢出');
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await settle(tester, rounds: 10);

    // 预算页：入口是首页那张引导卡
    final budgetCard = find.text('设个月度预算，超支前会提醒你');
    if (budgetCard.evaluate().isNotEmpty) {
      await tester.tap(budgetCard.first);
      await tester.pump();
      await settle(tester, rounds: 14);
      expect(tester.takeException(), isNull, reason: '$tag：预算页不应溢出');
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await tester.pump();
      await settle(tester, rounds: 10);
    }
  }

  testWidgets('字号 1.3 倍（系统「大」）：主要页面都不溢出', (tester) async {
    useTextScale(tester, 1.3);
    await tester.pumpWidget(const ProviderScope(child: JianjiApp()));
    await tester.pump();
    await boot(tester);
    await settle(tester, rounds: 14);

    expect(tester.takeException(), isNull, reason: '大字号下首页不应溢出');
    await visitAllPages(tester, tag: '字号 1.3');
    await drainReal(tester);
  });

  testWidgets('字号 2.0 倍（系统「特大」）：主要页面都不溢出', (tester) async {
    useTextScale(tester, 2.0);
    await tester.pumpWidget(const ProviderScope(child: JianjiApp()));
    await tester.pump();
    await boot(tester);
    await settle(tester, rounds: 14);

    expect(tester.takeException(), isNull, reason: '特大字号下首页不应溢出');
    await visitAllPages(tester, tag: '字号 2.0');
    await drainReal(tester);
  });
}

/// 塞一条「最坏情况」流水：金额位数拉满 + 超长备注 + 三个长标签 + AA 分摊 + 报销中。
///
/// 空账本测大字号没意义 —— 真正会挤爆的是流水行：标题、角标、副标题、金额四样
/// 挤在同一行，字号一翻倍就必须靠弹性布局或省略号顶住。
Future<void> _seedWorstCase(String dbPath) async {
  // 用默认参数开（withSamplePockets: true）：这样有预置账户和分类可挂。
  // App 自己用 false，但那只是"不额外插入示例账户"，对版式压力测试没影响。
  final store = await LedgerStore.open(path: dbPath);
  try {
    final book = (await store.books()).first;
    final pockets = await store.allPockets(includeArchived: false);
    if (pockets.isEmpty) return;
    var buckets = await store.buckets(book.id, 'out');
    if (buckets.isEmpty) {
      await store.addBucket(
          bookId: book.id, title: '其他', glyph: '🧾', flow: 'out');
      buckets = await store.buckets(book.id, 'out');
    }
    if (buckets.isEmpty) return;
    await store.addEntry(
      bookId: book.id,
      pocketId: pockets.first.id,
      bucketId: buckets.first.id,
      flow: 'out',
      amountCents: 12345678, // ¥123,456.78
      memo: '这是一个特别特别长的备注，用来看看流水行会不会被挤到溢出',
      day: DateTime.now(),
      tags: '出差异地报销,客户招待,季度总结',
      reimburse: 1,
      splitCents: 1000000,
    );
  } finally {
    await store.close();
  }
}
