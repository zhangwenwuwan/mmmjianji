import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/state/settings.dart';
import 'package:jianji/ui/editor_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 2026-11-07 两个新逻辑的端到端断言：
///
/// 1. **优惠 = 实付减免**：界面输「原价 100」，优惠里选 9 折（省 10），
///    落库 amount 必须是 9000 分（90 元实付）、discount 1000 分。
///    以前语义是「金额记实付、优惠只作备注」，改成 App 代减之后，
///    落库口径必须钉死，否则统计/余额悄悄全错。
/// 2. **预选账户跟手上一次**：设了默认账户 A、上次用了 B，下一笔
///    必须预选 B（lastPocketId > defaultPocketId），而不是弹回 A。
///
/// ⚠️ 结构铁律（editor_save_amount_test 踩过的坑，别改）：
/// - 必须**单个 testWidgets**：多个 testWidgets 共享进程内同一个 sqflite
///   factory，各自 open 会抢文件锁，测试挂死。
/// - 不覆盖 databasePathProvider；setUpAll 清库。
/// - pop 转场走完再点宿主按钮；真实 IO 全部 runAsync。
/// - 视口用 1080×2340 / DPR 1.0（逻辑 1080 宽）：这个文件测**逻辑**不测
///   布局，宽视口让「优惠」chip 不用横滑就在视口内，tap 不会静默落空。
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
                  onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                      builder: (_) => const EntryEditorPage())),
                  child: const Text('打开记账'),
                ),
              ),
            ),
          ),
        ),
      );

  /// 等上一笔的编辑页卸载 → 打开新编辑页 → 等账户加载 + postFrame 预选落地。
  Future<void> openEditor(
      WidgetTester tester, ProviderContainer container) async {
    for (var i = 0; i < 15; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      if (find.byType(EntryEditorPage).evaluate().isEmpty &&
          find.text('打开记账').evaluate().isNotEmpty) {
        break;
      }
    }
    await tester.tap(find.text('打开记账'));
    await tester.pump();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 分类/账户从库里读，首帧后要等真实 IO（假时钟推不动 sqflite）
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      if (find.byKey(const Key('amount-display')).evaluate().isNotEmpty) break;
    }
    // 等账户数据加载完，再推两帧让 postFrame 里的预选 setState 落地。
    for (var i = 0; i < 50; i++) {
      final loaded =
          container.read(pocketsProvider).valueOrNull?.isNotEmpty ?? false;
      if (loaded) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    await tester.pump();
    await tester.pump();
  }

  /// 敲一串键（金额键盘）。
  Future<void> typeKeys(WidgetTester tester, List<String> keys) async {
    for (final k in keys) {
      await tester.tap(find.byKey(Key('key-$k')));
      await tester.pump();
    }
  }

  /// 点保存 → 等 pop → 读当天最新一笔。返回落库的 Entry。
  Future<Entry> saveAndReadLast(
      WidgetTester tester, ProviderContainer container, int baseCount) async {
    await tester.tap(find.text('保存'));
    String? blocked;
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      for (final t in const ['请选择账户', '请输入金额', '优惠不能等于或超过本笔金额']) {
        if (find.text(t).evaluate().isNotEmpty) blocked ??= t;
      }
      if (find.text('打开记账').evaluate().isNotEmpty &&
          find.byType(EntryEditorPage).evaluate().isEmpty) {
        break;
      }
    }
    if (blocked != null) fail('保存被拦下：$blocked');
    late Entry last;
    await tester.runAsync(() async {
      final store = await container.read(storeProvider.future);
      final book = await container.read(activeBookProvider.future);
      List<Entry> rows = const [];
      for (var i = 0; i < 40; i++) {
        rows = await store.entriesOfDay(book.id, DateTime.now());
        if (rows.length == baseCount + 1) break;
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
      expect(rows.length, baseCount + 1,
          reason: '保存后当天应该新增一笔（base=$baseCount）');
      last = rows.first; // ORDER BY id DESC，最新在最前
    });
    return last;
  }

  testWidgets('优惠实付落库 + 预选账户跟手上一次', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late int pocketA;
    late int pocketB;
    await tester.runAsync(() async {
      final store = await LedgerStore.open();
      final book = (await store.books()).first;
      await store.addPocket(
        bookId: book.id,
        title: '现金',
        glyph: '💵',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      await store.addPocket(
        bookId: book.id,
        title: '招行卡',
        glyph: '💳',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      // addPocket 返回 void，id 从列表反查（按创建顺序）。
      final pockets = await store.allPockets();
      pocketA = pockets.firstWhere((p) => p.title == '现金').id;
      pocketB = pockets.firstWhere((p) => p.title == '招行卡').id;
      await store.close();
    });
    SharedPreferences.setMockInitialValues({'default_pocket_id': pocketA});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(host(container));
    var baseCount = 0;

    // ---- 组 1：优惠 5 折 → 落库 amount=5000 / discount=5000 ----
    await openEditor(tester, container);
    await typeKeys(tester, const ['1', '0', '0']); // 原价 100
    await tester.tap(find.text('优惠'));
    await tester.pump();
    // ⚠️ 模态面板从底部上滑要 ~250ms：转场中 Slider 已在树里（只是还在
    // 屏幕外），所以等它出现没用，必须先把转场 pump 完再点按钮，
    // 否则 tap「确定」落在屏幕外（曾报 Offset y=2539 > 屏高 2340）。
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(Slider), findsOneWidget,
        reason: '优惠键盘上方应有折数滑条');
    // 点滑条正中央 = 精确 5.0 折（轨道两端 inset 对称，中点误差抵消），
    // 比拖拽确定性强：拖拽落点受起始 thumb 位置和轨道内边距影响。
    await tester.tap(find.byType(Slider));
    await tester.pump();
    expect(
      find.byKey(const Key('zhe-slider-hint')),
      findsOneWidget,
    );
    final hintText =
        (tester.widget(find.byKey(const Key('zhe-slider-hint'))) as Text)
            .data!;
    // 「5 折」是滑条右侧的独立标签，提示行只写省/实付
    expect(find.text('5 折'), findsOneWidget, reason: '滑条标签应为 5 折');
    expect(hintText, contains('省 50'), reason: '实际：$hintText');
    expect(hintText, contains('实付 50'), reason: '实际：$hintText');
    await tester.tap(find.text('确定'));
    await tester.pump();
    // 回到编辑器：实付提示行出现
    expect(find.byKey(const Key('discount-net-hint')), findsOneWidget);
    final netHint =
        (tester.widget(find.byKey(const Key('discount-net-hint'))) as Text)
            .data!;
    expect(netHint, contains('实付 50'), reason: '实际：$netHint');

    final e1 = await saveAndReadLast(tester, container, baseCount++);
    expect(e1.amountCents, 5000, reason: '实付 50 元入账');
    expect(e1.discountCents, 5000, reason: '优惠记省 50');

    // ---- 组 2：无优惠 → 落库 amount 原样 ----
    await openEditor(tester, container);
    await typeKeys(tester, const ['2', '5']);
    final e2 = await saveAndReadLast(tester, container, baseCount++);
    expect(e2.amountCents, 2500);
    expect(e2.discountCents, 0);

    // ---- 组 3：没记过账时预选 = 默认账户 A；记完之后 lastPocket=A ----
    // （组 1/2 都存进了默认预选的 A）
    expect(container.read(settingsProvider).lastPocketId, pocketA,
        reason: '保存成功后应记录上次账户');

    // ---- 组 4：上次用了 B → 下一笔预选 B，不再弹回默认账户 A ----
    await container
        .read(settingsProvider.notifier)
        .setLastPocket(pocketB);
    await openEditor(tester, container);
    await typeKeys(tester, const ['6']);
    final e4 = await saveAndReadLast(tester, container, baseCount++);
    expect(e4.pocketId, pocketB,
        reason: 'lastPocketId 应优先于 defaultPocketId');
  });
}
