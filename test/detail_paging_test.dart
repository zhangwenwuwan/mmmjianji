import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/ui/category_detail_page.dart';
import 'package:jianji/ui/ledger_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 分类详情「分批渲染」的回归测试。
///
/// 为什么要有：这个页面以前把「最近 300 笔」一次性建成 300 个 EntryRow，
/// 每行还要 watch 6 个 provider —— 真机上点进去会明显顿一下。
/// 现在首屏 60 行，剩下的点「再显示」。这个测试钉住两件事：
///   ① 首屏真的只有 60 行（不是"看起来 60 行"）；
///   ② 点一下按钮能把剩下的接上，且不丢行。
void main() {
  late Directory tmp;
  late String dbPath;
  late Bucket bucket;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-paging-');
    dbPath = '${tmp.path}/test.db';
    SharedPreferences.setMockInitialValues({});

    final store = await LedgerStore.open(path: dbPath);
    final book = (await store.books()).first;
    await store.addPocket(
      bookId: book.id,
      title: '钱包',
      glyph: '👛',
      kind: PocketKind.cash,
      currency: 'CNY',
      openingCents: 0,
    );
    final pocket = (await store.allPockets()).first;
    // addBucket 返回 void（和老 API 保持一致），id 只能回查
    await store.addBucket(
      bookId: book.id,
      title: '餐饮',
      glyph: '🍜',
      flow: 'out',
    );
    bucket = (await store.buckets(book.id, 'out'))
        .firstWhere((b) => b.title == '餐饮');
    final bucketId = bucket.id;
    // 70 笔：刚好跨过 60 这条线，能同时看到「60 行」和「还有 10 笔」
    for (var i = 0; i < 70; i++) {
      await store.addEntry(
        bookId: book.id,
        pocketId: pocket.id,
        bucketId: bucketId,
        flow: 'out',
        amountCents: 100 + i,
        memo: '第 $i 笔',
        day: DateTime(2026, 10, 20),
      );
    }
    await store.close();
  });

  tearDown(() async {
    try {
      await databaseFactory.deleteDatabase(dbPath);
    } catch (_) {}
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// sqflite 的查询挂在真实定时器上，假时钟推不动 → 得交替 runAsync / pump
  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('分类详情首屏只建 60 行，点「再显示」补齐剩下的', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [databasePathProvider.overrideWithValue(dbPath)],
      child: MaterialApp(home: CategoryDetailPage(bucket: bucket)),
    ));
    await settle(tester);

    final firstPage = find.byType(EntryRow).evaluate().length;
    expect(firstPage, 60, reason: '首屏应该只建 60 行，实际 $firstPage');

    final more = find.textContaining('再显示');
    expect(more, findsOneWidget, reason: '还有 10 笔，应该出现「再显示」按钮');
    expect(find.textContaining('还有 10 笔'), findsOneWidget);

    // 点一下 → 70 行全出来，按钮消失。
    // ⚠️ 必须先滚到按钮位置：60 行大约 3800dp 高，按钮在首屏视口之外，
    // 直接 tap 会静默落空（hitTestWarningShouldBeFatal 默认 false，不报错）。
    await tester.ensureVisible(more);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(more);
    await settle(tester, rounds: 4);

    final afterTap = find.byType(EntryRow).evaluate().length;
    expect(afterTap, 70, reason: '展开后应该是全部 70 行，实际 $afterTap');
    expect(find.textContaining('再显示'), findsNothing);
  });
}
