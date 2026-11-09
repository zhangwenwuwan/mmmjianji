// URL Scheme → 记账页端到端：预填、按名匹配分类/账户、auto=1 自动落库。
//
// ⚠️ 沿用 editor_save_amount_test 的结构铁律：单个 testWidgets、不覆盖
// databasePathProvider、只 pumpWidget 一次、读库走 runAsync、
// push 转场走完再断言。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/scheme.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/ui/editor_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
  });

  WidgetController.hitTestWarningShouldBeFatal = true;

  testWidgets('jianji://add?money=25.5&note=午饭&bucket=食&pocket=微信&auto=1 '
      '→ 自动落库，分类/账户按名命中', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // ⚠️ 建库/建分类/建账户都是真实磁盘 IO，必须在 runAsync 里做：
    // 直接 await 会挂在假时钟的 zone 里（测试「did not complete」）。
    late final LedgerStore store;
    late final int bookId;
    late final int weixinId;
    late final int shiId;
    await tester.runAsync(() async {
      store = await container.read(storeProvider.future);
      final book = await container.read(activeBookProvider.future);
      bookId = book.id;
      await store.addBucket(
          bookId: book.id, title: '食', glyph: '🍜', flow: 'out');
      await store.addPocket(
        bookId: book.id,
        title: '微信',
        glyph: '💬',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      weixinId =
          (await store.allPockets()).firstWhere((p) => p.title == '微信').id;
      shiId = (await store.buckets(book.id, 'out'))
          .firstWhere((b) => b.title == '食')
          .id;
    });

    final draft = parseScheme(
        'jianji://add?money=25.5&note=午饭&bucket=食&pocket=微信&auto=1')!.draft!;

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                    builder: (_) =>
                        EntryEditorPage(schemeDraft: draft))),
                child: const Text('打开记账'),
              ),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('打开记账'));
    await tester.pump();
    // push 转场 + 首帧 + 分类/账户按名匹配（真实 IO）+ auto 落库 + pop，
    // 交替推真实/假时钟直到编辑页完全卸载。
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(EntryEditorPage).evaluate().isEmpty) break;
    }
    expect(find.byType(EntryEditorPage), findsNothing,
        reason: 'auto=1 应该在预填完成后自动保存并退出编辑页');

    final rows = (await tester.runAsync(
        () => store.entriesOfDay(bookId, DateTime.now())))!;
    expect(rows.length, 1, reason: '只落一笔');
    final e = rows.first;
    expect(e.amountCents, 2550, reason: '金额按分落库');
    expect(e.memo, '午饭');
    expect(e.flow, 'out');
    expect(e.bucketId, shiId, reason: '分类按名精确命中');
    expect(e.pocketId, weixinId, reason: '账户按名精确命中');
    expect(e.currency, isNull, reason: '未带币种参数，跟随账户');
  });
}
