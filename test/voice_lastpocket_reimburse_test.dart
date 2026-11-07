import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/state/settings.dart';
import 'package:jianji/ui/motion.dart';
import 'package:jianji/ui/reimburse_page.dart';
import 'package:jianji/ui/voice_entry_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 2026-11-07 两个 bug 的回归钉：
///
/// 1. **语音弹窗的账户记忆**：默认账户=微信、上一笔在语音里选了支付宝，
///    下次弹确认窗必须预选支付宝（lastPocketId > defaultPocketId），
///    保存后还要把这次的账户写回 lastPocketId。
///    之前 `_fallbackPocket` 只认默认账户、保存也不记录，手动记账页
///    1.4.59 的改动没覆盖语音通道。
/// 2. **报销列表「未注明」**：没写备注的支出在待报销/已报销列表里
///    只显示「未注明」，看着像数据丢了。改成 备注 > 分类名 > 未注明。
///
/// ⚠️ 结构铁律（踩过的坑，别改）：
/// - **单个 testWidgets**：多个 testWidgets 抢进程内同一个 sqflite 文件锁
///   会挂死（editor_save_amount_test 教训）。
/// - 语音页走 [VoiceEntryPage.showAsDraftSheet] 的按钮宿主——和生产路径
///   同壳（透明 Material），直接把 embedded 页当 home 会报
///   No Material widget，pop 还会把唯一路由弹掉。
/// - **不要在 runAsync 里 await 被 bumpRevision 失效过的 provider 的
///   `.future`**（如 activeBookProvider）：riverpod 的重算体跑在容器创建时
///   捕获的 fake-async zone 里，runAsync 的真实时间推不动它，直接死锁
///   （本文件第一版卡死 10 分钟的根因）。要拿账本 id 就在 bump 之前读。
/// - 真实 IO 一律 runAsync + pump 交替推进（假时钟推不动 sqflite）。
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
  });

  WidgetController.hitTestWarningShouldBeFatal = true;

  Widget host(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    unawaited(
                        VoiceEntryPage.showAsDraftSheet(ctx, '午饭花了 20 元'));
                  },
                  child: const Text('打开确认框'),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> settle(WidgetTester tester, {int rounds = 14}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('语音账户记忆 + 报销标题回退分类名', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // ---- seed：微信/支付宝两个账户 + 餐饮分类。账本 id 在此捕获，
    //      后面 bumpRevision 之后绝不再读 activeBookProvider.future。----
    late int pocketWx;
    late int pocketAlipay;
    late int foodBucket;
    late int bookId;
    await tester.runAsync(() async {
      final seed = await LedgerStore.open();
      final book = (await seed.books()).first;
      bookId = book.id;
      await seed.addPocket(
        bookId: book.id,
        title: '微信',
        glyph: '💬',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      await seed.addPocket(
        bookId: book.id,
        title: '支付宝',
        glyph: '🅰️',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      // addPocket 返回 void，id 从列表反查。
      final pockets = await seed.allPockets();
      pocketWx = pockets.firstWhere((p) => p.title == '微信').id;
      pocketAlipay = pockets.firstWhere((p) => p.title == '支付宝').id;
      foodBucket = await seed.addBucket(
          bookId: book.id,
          title: '餐饮',
          glyph: '🍜',
          flow: 'out',
          parentId: null);
      await seed.close();
    });
    SharedPreferences.setMockInitialValues({
      'default_pocket_id': pocketWx, // 默认账户=微信
      'last_pocket_id': pocketAlipay, // 上一笔用了支付宝
    });
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // ---- 组 1：语音确认弹窗预选支付宝（不是默认账户微信）----
    await tester.pumpWidget(host(container));
    await settle(tester);
    await tester.tap(find.text('打开确认框'));
    await settle(tester);
    expect(find.text('确认这笔'), findsOneWidget);
    for (var i = 0; i < 30; i++) {
      if (find.text('支付宝').evaluate().isNotEmpty) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('支付宝'), findsOneWidget,
        reason: '语音弹窗应预选上次用的支付宝，而不是默认账户微信');
    expect(find.text('微信'), findsNothing);

    // ---- 组 2：语音保存成功后记录 lastPocket ----
    await tester.tap(find.text('记一笔'));
    bool saved = false;
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      if (container.read(settingsProvider).lastPocketId == pocketAlipay) {
        saved = true;
        break;
      }
    }
    expect(saved, true, reason: '语音保存成功后应写回 lastPocketId');
    // 弹窗保存后 pop 回宿主；SnackBar 的 2 秒定时器用假时钟自然走完，
    // 别让 pending timer 拖到测试收尾。
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();

    // ---- 组 3：报销列表——无备注的已报销账显示分类名，不再「未注明」----
    // storeProvider 不 watch revision，保存后依然有效；账本 id 用开头捕获的。
    late int expenseId;
    await tester.runAsync(() async {
      final store = await container.read(storeProvider.future);
      await store.addEntry(
        bookId: bookId,
        pocketId: pocketWx,
        bucketId: foodBucket,
        flow: 'out',
        amountCents: 8800,
        memo: '', // 故意不写备注
        day: DateTime.now(),
      );
      final rows = await store.entriesOfDay(bookId, DateTime.now());
      expenseId = rows.first.id; // ORDER BY id DESC，最新在最前
      await store.reimburseTo(expenseId, pocketAlipay);
    });
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ReimbursePage()),
    ));
    // 等列表加载完（SkeletonList 消失、Tab 标签带数量出现）。
    for (var i = 0; i < 50; i++) {
      if (find.text('已报销 1').evaluate().isNotEmpty &&
          find.byType(SkeletonList).evaluate().isEmpty) {
        break;
      }
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('已报销 1'), findsOneWidget, reason: '报销页应加载出 1 笔已报销');
    await tester.tap(find.text('已报销 1'));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('餐饮'), findsOneWidget,
        reason: '无备注的报销账应显示分类名「餐饮」');
    expect(find.text('未注明'), findsNothing,
        reason: '有分类的账不该再显示「未注明」');
  });
}
