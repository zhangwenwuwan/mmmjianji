import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/ui/bucket_manage_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 分类管理页的渲染冒烟。
///
/// 重点是「嵌套的 ReorderableListView 不炸」——一级一组、组内一层，
/// 两个滚动组件套在一起最容易在真机上白屏（viewport 无界 / 手势打架）。
/// 拖拽后的顺序逻辑由 core/bucket_order.dart 的纯函数测试覆盖：
/// 真拖拽在假时钟下会卡住（自动滚动不会收敛），不值得为了它牺牲稳定性。
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
  });

  WidgetController.hitTestWarningShouldBeFatal = true;

  Future<void> drain(WidgetTester tester, {int rounds = 24}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('一级 + 二级分类都渲染出来，每个分类都有拖拽手柄', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      final store = await LedgerStore.open();
      final book = (await store.books()).first;
      for (final b in await store.buckets(book.id, 'out', includeArchived: true)) {
        await store.deleteBucketIfEmpty(b.id);
      }
      final food = await store.addBucket(
          bookId: book.id, title: '食', glyph: '🍜', flow: 'out');
      await store.addBucket(
          bookId: book.id, title: '衣', glyph: '🛍️', flow: 'out');
      await store.addBucket(
          bookId: book.id, title: '住', glyph: '🏠', flow: 'out');
      await store.addBucket(
          bookId: book.id, title: '早餐', glyph: '🥐', flow: 'out', parentId: food);
      await store.addBucket(
          bookId: book.id, title: '午餐', glyph: '🍚', flow: 'out', parentId: food);
      await store.close();
    });

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: BucketManagePage()),
    ));
    await tester.pump();
    await drain(tester);

    expect(find.text('分类管理'), findsOneWidget);
    expect(find.text('食'), findsOneWidget);
    expect(find.text('衣'), findsOneWidget);
    expect(find.text('住'), findsOneWidget);
    expect(find.text('早餐'), findsOneWidget);
    expect(find.text('午餐'), findsOneWidget);

    // 一级 3 个 + 二级 2 个，每个都要有手柄（拖拽的唯一入口）
    expect(find.byIcon(Icons.drag_handle), findsNWidgets(5));

    expect(tester.takeException(), isNull, reason: '嵌套 ReorderableListView 不能抛异常');

    // 一级分类仍能点进详情（手柄不该抢掉整行的点击）
    await tester.tap(find.text('衣'));
    await tester.pump();
    await drain(tester, rounds: 10);
    expect(find.text('衣'), findsWidgets);

    await drain(tester);
  });
}
