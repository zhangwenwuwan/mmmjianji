import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/ui/voice_entry_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 语音识别后的**紧凑确认弹窗**（embedded）端到端。
///
/// 钉住用户提的两件事：① 不再出现冷冰冰的「未分类」；
/// ② 分类选择器顶部常驻「自定义分类」，建完立刻选中并落库。
/// 顺带确认精简后「记一笔」仍能写库 —— UI 大改最容易把保存链路碰断。
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await databaseFactory.getDatabasesPath();
    final path = '$dir/jianji_ledger.db';
    await databaseFactory.deleteDatabase(path);
    final seed = await LedgerStore.open(path: path);
    final book = (await seed.books()).first;
    await seed.addPocket(
      bookId: book.id,
      title: '现金',
      glyph: '👛',
      kind: PocketKind.cash,
      currency: 'CNY',
      openingCents: 0,
    );
    await seed.close();
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
                    unawaited(VoiceEntryPage.showAsDraftSheet(
                        ctx, '买衣服花了五百块钱'));
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

  testWidgets('紧凑确认框：无未分类、分类顶部可自定义、建完即用并落库',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(host(container));
    await settle(tester);

    await tester.tap(find.text('打开确认框'));
    await settle(tester);

    expect(find.text('确认这笔'), findsOneWidget);
    expect(find.text('记一笔'), findsOneWidget);
    // 旧版把「未分类」直接摆在选择框里，识别不到时很扎眼。
    expect(find.text('未分类'), findsNothing);
    expect(find.text('选分类'), findsOneWidget);
    // 解析出的金额、账户都在，只是收进了更紧凑的控件里。
    expect(find.text('现金'), findsOneWidget);

    // ① 分类 chip → 选择面板
    await tester.tap(find.text('选分类'));
    await settle(tester);
    expect(find.text('自定义分类'), findsOneWidget,
        reason: '分类选择器顶部必须有自定义入口');

    // ② 自定义 → 输入名字 → 创建并选用
    await tester.tap(find.text('自定义分类'));
    await settle(tester);
    expect(find.text('创建并选用'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '衣服');
    await tester.tap(find.text('创建并选用'));
    await settle(tester, rounds: 18);

    expect(find.text('衣服'), findsWidgets, reason: '新建的分类应立即被选中');
    expect(find.text('未分类'), findsNothing);

    final store = await container.read(storeProvider.future);
    final book = await container.read(activeBookProvider.future);
    final buckets = await tester.runAsync(() => store.buckets(book.id, 'out'));
    expect(buckets!.any((b) => b.title == '衣服'), isTrue,
        reason: '自定义分类要真的写进数据库');

    // ③ 记一笔：精简后的弹窗仍要能落库，金额来自「五百块钱」。
    await tester.tap(find.text('记一笔'));
    await settle(tester, rounds: 18);
    expect(find.text('先选一个账户'), findsNothing, reason: '账户校验不应拦住保存');
    expect(find.text('还没填金额，补一句「35 元」试试'), findsNothing,
        reason: '金额应已从「五百块钱」解析出来');
    expect(find.text('保存失败，详情见日志中心'), findsNothing,
        reason: 'addEntry 不应抛异常');

    final rows = await tester.runAsync(
        () => store.entriesOfDay(book.id, DateTime.now()));
    expect(rows, isNotNull, reason: '确认后必须真的落库');
    expect(rows!.first.amountCents, 50000);
    expect(rows.first.flow, 'out');
    // 语音记的「今天」的账必须和手动记账一样带当前时分，
    // 否则首页时间轴会显示 --:--（那个占位只该留给没记时分的老账）。
    expect(rows.first.timeMinutes, isNotNull);
    expect(find.text('确认这笔'), findsNothing, reason: '保存后弹窗应关闭');

    // SnackBar 的 3 秒定时器：推进假时钟让它自然触发，别在收尾留下 pending。
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
  });

  testWidgets('选账户的列表里带余额（和记账页同一个选择器）', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(host(container));
    await settle(tester);

    await tester.tap(find.text('打开确认框'));
    await settle(tester);

    // 点账户 chip → 选择器
    await tester.tap(find.text('现金'));
    await settle(tester);

    // 名字之外必须有余额那一行：语音记完账常要确认"这笔该记哪张卡"，
    // 看不到余额就得退出去查一遍（用户反馈的就是这个）。
    expect(find.textContaining('余额'), findsWidgets,
        reason: '选账户时必须能直接看到余额');
    expect(find.textContaining('CNY'), findsWidgets);

    // 收尾：把面板关掉，别让它的动画定时器挂到测试结束。
    await tester.tapAt(const Offset(200, 60));
    await settle(tester);
  });
}
