import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/ui/editor_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 真机复现：转账页点「选择账户开始」没有任何反应（连遮罩都不出现，
/// 按一次返回直接退出编辑器 → 说明 showModalBottomSheet 压根没 push）。
///
/// 这个用例把那条路径钉死：切到转账 tab → 点按钮 → 必须出现金额面板。
/// 如果这里能过而真机不过，问题就在构建/设备层，不在 Dart 逻辑。
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
  });

  WidgetController.hitTestWarningShouldBeFatal = true;

  /// 真实 IO 与假时钟交替推进（同 app_smoke_test 的 drainAll）：
  /// 只推假时钟时 sqflite 排队查询的 10s timer 等不到完成回调，收尾会报
  /// 'A Timer is still pending'。
  Future<void> drain(WidgetTester tester, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('转账页入口能打开金额面板', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

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
      await store.close();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(
                    MaterialPageRoute(builder: (_) => const EntryEditorPage())),
                child: const Text('打开记账'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开记账'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 等分类/账户从库里读出来（假时钟推不动 sqflite 的真实 IO）
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      if (container.read(pocketsProvider).valueOrNull?.isNotEmpty ?? false) {
        break;
      }
    }

    // 切到「转账」tab
    await tester.tap(find.text('转账'));
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('选择账户开始'), findsOneWidget,
        reason: '转账 tab 应该显示「选择账户开始」按钮');

    expect(find.text('转账'), findsOneWidget,
        reason: '面板没打开前，屏幕上只有 tab 那一个「转账」');

    // 点它：必须弹出金额面板（面板标题也是「转账」→ 出现第二个）
    await tester.tap(find.text('选择账户开始'));
    await tester.pump();
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await drain(tester, rounds: 10);

    expect(find.text('转账'), findsNWidgets(2),
        reason: '点「选择账户开始」后应该出现转账金额面板（标题 + tab 各一个）');

    // 收尾：把库里排队的查询 timer 跑完，否则 tearDown 报 timersPending
    await drain(tester);
  });
}
