import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/ui/editor_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// **端到端金额断言**：屏幕上显示多少，落库就必须是多少（分）。
///
/// 为什么要有这个文件：1.0.1 里出过一次「17 × 2 存成 3400 元」——
/// 乘除在「分」域直接相乘，凭空放大 100 倍。当时只有 UI 文本断言
/// （而且期望值是照着错误行为写的 `'3,400'`），所以 bug 一路溜到用户手里。
/// 这类 bug 的共同点是**静态合法、UI 看着合理**，只有把「显示值」和「库里的值」
/// 对起来才能抓住。
///
/// ⚠️ 结构铁律（反复踩过，别改）：
/// - 必须**单个 testWidgets**：多个 testWidgets 共享进程内同一个 sqflite
///   factory，各自 open 会抢文件锁/连接，测试挂死（不是超时，是卡住）。
/// - 必须**不用 `databasePathProvider` 覆盖**：widget 测试里 override 会把
///   provider 图卡住（实测，editor_keypad_test 也这么注释）。所以走默认库。
/// - 全程**只 pumpWidget 一次**，组间靠编辑页「保存→pop 回宿主」衔接；
///   绝不在组间重复 pumpWidget（残留旧编辑页 → key 重复匹配）。
/// - 保存后必须等编辑页**完全卸载**（pop 转场结束）再进入下一组，否则宿主
///   按钮虽渲染但不可点。等待用 runAsync+pump 双推真实/假时钟。
/// - 读库是真实 IO，必须 `tester.runAsync`。
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // ⚠️ 必须清库：本测试刻意不覆盖 databasePathProvider（widget 测试里覆盖会把
    // provider 图卡死），于是所有用例写进磁盘上同一个库。不清库的话第二遍运行
    // 就会读到上轮累积的流水，`rows.length == base+1` 断言必然失败。
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
  });

  // ⚠️ tap 落空在 flutter_test 里默认只打 warning 不失败。曾经因此漏掉一个真 bug：
  // 键盘运算符键被排到屏幕外，点击静默无效，`12+5×2` 变成数字拼接 `1252`，
  // 而测试仍然"跑完"。设为致命，让布局/命中问题立刻暴露。
  WidgetController.hitTestWarningShouldBeFatal = true;

  /// 宿主页面：记账页保存成功后会 Navigator.pop，
  /// 直接把 EntryEditorPage 当 home 的话 pop 会把路由栈清空。
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

  /// 走一屏键盘 → 保存 → 读库，返回（屏幕显示文本, 库里最后一笔的分）。
  ///
  /// 组间衔接：上一组保存会 pop 回宿主；本函数开头等编辑页卸载后再点「打开记账」。
  Future<(String, int)> record(WidgetTester tester, ProviderContainer container,
      List<String> keys, int baseCount) async {
    // 等上一组保存的编辑页完全卸载（pop 转场结束），宿主按钮才真正可点。
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
    // ⚠️ 必须把 push 转场走完（MaterialPageRoute 约 300ms）再点按键。
    // 少这一步，页面还在从右侧滑入，键盘整体右移 ~20% 屏宽，
    // 最右侧的运算符键就被挤出视口 → tap 落空（以前只 warning，静默无效）。
    // pumpAndSettle 不能用：记账页有常驻动画，假时钟下永远 settle 不了。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    // ⚠️ 不能用 pumpAndSettle：记账页有常驻动画，假时钟下永远 settle 不了。
    // 分类从库里读，首帧后要等真实 IO（假时钟推不动 sqflite），只能轮询。
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      if (find.byKey(const Key('amount-display')).evaluate().isNotEmpty) break;
    }

    String amount() =>
        (tester.widget(find.byKey(const Key('amount-display'))) as Text).data!;

    for (final k in keys) {
      await tester.tap(find.byKey(Key('key-$k')));
      await tester.pump();
    }
    final shown = amount();

    // 等账户数据加载完，再由 postFrame 自动选中第一个账户。
    // ⚠️ 不能用 `find.text('账户')` 判断"是否已选"：账户 chip 在横向 ListView 的
    // 右侧，窄屏（真机逻辑宽 ~393）下不在视口内 → 压根不会被 build →
    // 永远"找不到"，循环第一轮就 break，等于完全没等，保存必被「请选择账户」拦下。
    for (var i = 0; i < 50; i++) {
      final loaded =
          container.read(pocketsProvider).valueOrNull?.isNotEmpty ?? false;
      if (loaded) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    // 再推两帧：让 addPostFrameCallback 里的 setState(_pocketId) 落地。
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('保存'));
    // 保存要跑真实 DB 写入 + 成功对勾动画，假时钟推不动
    String? blocked;
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      for (final t in const ['请选择账户', '请输入金额']) {
        if (find.text(t).evaluate().isNotEmpty) blocked ??= t;
      }
      // 宿主按钮出现 = 编辑页已 pop；再等它彻底卸载（下一组才没有 key 残留）。
      if (find.text('打开记账').evaluate().isNotEmpty &&
          find.byType(EntryEditorPage).evaluate().isEmpty) {
        break;
      }
    }
    if (blocked != null) {
      fail('保存被拦下：$blocked（页面没按预期保存）');
    }

    // ⚠️ 读库是真实 IO，必须 runAsync。pop 未必等 DB 写入完成，这里轮询直到
    // 本组这一笔真正落库（当天笔数 = base+1）再取最新一笔。
    var cents = 0;
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
      // ⚠️ entriesOfDay 是 ORDER BY id DESC（最新在最前），要取 rows.first。
      // 取 rows.last 拿到的是当天最旧那笔：前两组金额都是 3400 时恰好蒙对，
      // 第三组（50-8=42）就会拿到 3400 而误判——这就是之前"偶尔过"的根源。
      cents = rows.first.amountCents;
    });
    return (shown, cents);
  }

  testWidgets('金额端到端：屏幕显示与落库一致（17×2 / 12+5×2 / 减法 / 小数）',
      (tester) async {
    // 视口用**真机逻辑尺寸**：1080×2340 / DPR 2.75 → 逻辑 392.7×850.9，
    // 与实机 OPPO PBEM00 一致。之前是 DPR 1.0（逻辑宽 1080dp，等于平板窗口），
    // 窄屏才会暴露的真实问题（字段条要横滑、账户 chip 默认在视口外）全被掩盖。
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(); // 默认库，不覆盖
    addTearDown(container.dispose);

    // ⚠️ 2026-10-25：App 改成「新装不预置账户」（storeProvider 传
    // withSamplePockets: false），编辑页没有可选账户，保存会被
    // 「请选择账户」拦下。这里按老行为补一个账户，让测试继续验金额逻辑。
    // 必须先关掉自己的连接，再让 widget 侧的 provider 去开同一个库。
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
      await store.close();
    });

    await tester.pumpWidget(host(container));

    var baseCount = 0;
    // 每组：按键 → 期望显示 → 期望落库分。同库累积，断言只看当天最后一笔。
    const cases = <(List<String>, String, int)>[
      (['1', '7', '×', '2'], '34', 3400), // 34 元，不是 3400 元
      (['1', '2', '+', '5', '×', '2'], '34', 3400),
      (['5', '0', '-', '8'], '42', 4200),
      (['1', '2', '.', '5'], '12.5', 1250),
    ];
    for (final c in cases) {
      final (keys, shownWant, centsWant) = c;
      final (shown, cents) = await record(tester, container, keys, baseCount);
      expect(shown, shownWant);
      expect(cents, centsWant);
      baseCount++; // 本组已落库
    }
  });
}
