import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/ui/voice_entry_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 语音记账页的端到端：输入一句话 → 出草稿 → 保存 → 库里真的有一笔。
///
/// 解析器已有 28 条纯函数用例，这里只钉「页面接得上」：下拉框 value 是否
/// 合法、TextField 监听是否触发、addEntry 是否按解析结果落库。
/// 遵循 editor_save_amount_test 的结构铁律：单个 testWidgets、不覆盖
/// databasePathProvider（widget 测试里覆盖会卡住 provider 图）、真实 IO 用 runAsync。
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    final dir = await databaseFactory.getDatabasesPath();
    final path = '$dir/jianji_ledger.db';
    await databaseFactory.deleteDatabase(path);
    // 新装 App 不预置账户（withSamplePockets: false）。在 widget 测试之外
    // 先把「现金」建好，页面走默认库就能读到 —— 在 testWidgets 里用
    // runAsync 操作 ProviderContainer 会和假时钟抢 provider 图，实测会挂死。
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
                  onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                      builder: (_) => const VoiceEntryPage())),
                  child: const Text('打开语音记账'),
                ),
              ),
            ),
          ),
        ),
      );

  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('输入一句话 → 草稿 → 保存 → 落库 3500 分', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(host(container));
    await settle(tester);

    await tester.tap(find.text('打开语音记账'));
    await settle(tester);
    expect(find.byType(VoiceEntryPage), findsOneWidget);

    // 第一个 TextField 是「说一句」输入框；输入后监听器会即时重解析。
    await tester.enterText(
        find.byType(TextField).first, '今天午饭花了 35 元');
    await settle(tester);

    expect(find.text('账单草稿'), findsOneWidget);
    expect(find.textContaining('金额 35 元'), findsWidgets);
    expect(find.text('说一句 / 粘贴一句话'), findsOneWidget);

    await tester.tap(find.text('保存这笔'));
    await settle(tester, rounds: 16);

    // 保存成功会 pop 回宿主页面。
    expect(find.byType(VoiceEntryPage), findsNothing);

    final store = await container.read(storeProvider.future);
    final book = await container.read(activeBookProvider.future);
    final rows = await tester.runAsync(
        () => store.entriesOfDay(book.id, DateTime.now()));
    expect(rows, isNotNull);
    expect(rows!.first.amountCents, 3500);
    expect(rows.first.flow, 'out');
  });
}
