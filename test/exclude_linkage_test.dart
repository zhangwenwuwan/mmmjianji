import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/ui/editor_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 「不计入收支」⇒「不计入预算」的联动（2026-11-03 用户拍板的语义）。
///
/// 为什么需要它：两个开关原来是互相独立的，于是可以造出「收支都不算、却还占预算」
/// 这种数据 —— 预算提醒弹「超支」，统计页支出却看着没那么多，用户会以为账算错了。
/// 现在勾前者会自动勾上后者（反向不联动：只排预算、仍进收支是合理用法）。
///
/// ⚠️ 结构沿用 `editor_save_amount_test.dart` 的铁律：
/// - **不覆盖 `databasePathProvider`**（widget 测试里覆盖会把 provider 图卡住）；
/// - 全程只 pumpWidget 一次；读库/等待一律 `runAsync` + `pump` 双推。
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 不覆盖数据库路径 → 所有用例写同一个库，跑之前必须清掉。
    final dir = await databaseFactory.getDatabasesPath();
    final dbPath = '$dir/jianji_ledger.db';
    await databaseFactory.deleteDatabase(dbPath);

    // App 故意不预置账户（`withSamplePockets: false`），新库里一个账户都没有；
    // 记账页在没账户时不显示字段 chip 行（「更多」也就不存在）。这里补一个现金账户，
    // 让页面处于正常可记账的状态。
    final store = await LedgerStore.open(path: dbPath, withSamplePockets: false);
    final book = (await store.books()).first;
    if ((await store.allPockets(includeArchived: false)).isEmpty) {
      await store.addPocket(
        bookId: book.id,
        title: '现金',
        glyph: '💵',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
    }
    await store.close();
  });

  // tap 落空默认只打 warning，会让"点了没反应"的布局问题静默通过。
  WidgetController.hitTestWarningShouldBeFatal = true;

  /// 等异步（sqflite / 转场 / 弹层动画）都走完。
  Future<void> settle(WidgetTester tester, {int rounds = 14}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 取某个开关当前的值。
  bool switchValue(WidgetTester tester, String label) {
    final tile = find.ancestor(
      of: find.text(label),
      matching: find.byType(SwitchListTile),
    );
    return tester.widget<SwitchListTile>(tile.first).value;
  }

  testWidgets('勾上「不计入收支」会连带勾上「不计入预算」', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
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
    ));
    await tester.pump();
    await tester.tap(find.text('打开记账'));
    await settle(tester);

    // 「更多」chip 打开更多选项弹层
    await tester.tap(find.textContaining('更多').first);
    await settle(tester);

    // 初始两项都关着
    expect(switchValue(tester, '不计入收支'), isFalse);
    expect(switchValue(tester, '不计入预算'), isFalse);

    await tester.tap(find.text('不计入收支'));
    await settle(tester);

    expect(switchValue(tester, '不计入收支'), isTrue);
    expect(switchValue(tester, '不计入预算'), isTrue,
        reason: '勾「不计入收支」后必须自动勾上「不计入预算」');

    // 反向不联动：取消「不计入预算」不应把「不计入收支」也关掉
    await tester.tap(find.text('不计入预算'));
    await settle(tester);
    expect(switchValue(tester, '不计入预算'), isFalse);
    expect(switchValue(tester, '不计入收支'), isTrue);
  });
}
