import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 分类拖拽排序的落库口径。
///
/// 用户在分类管理页拖的是「展开后的整棵树」：一级分类后面紧跟它自己的
/// 二级分类。store 只认这一串 id，按顺序重写 rank；查询时 `buckets()`
/// 按 `rank, id` 排。这里钉住三件事：
/// 1. 拖完顺序真的能读回来；
/// 2. 老数据 rank 有重复值（COUNT(*) 生成 + 删过分类）时也能重排干净；
/// 3. 一级与二级共用 rank 空间，但同层之间仍然按 rank 相对顺序排。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-bucket-order-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
    // 新库会预置「衣食住行」四个分类（_seedIfEmpty）。这里清空，
    // 让每个用例只面对自己建的那几条，断言不用去数种子数据。
    for (final b in await store.buckets(bookId, 'out', includeArchived: true)) {
      await store.deleteBucketIfEmpty(b.id);
    }
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  Future<int> newBucket(String title, {int? parentId, String flow = 'out'}) =>
      store.addBucket(
        bookId: bookId,
        title: title,
        glyph: '✨',
        flow: flow,
        parentId: parentId,
      );

  Future<List<String>> titles(String flow) async {
    final list = await store.buckets(bookId, flow);
    return list.map((b) => b.title).toList();
  }

  test('重排一级分类：读回来的顺序与拖拽一致', () async {
    final a = await newBucket('衣');
    final b = await newBucket('食');
    final c = await newBucket('住');
    expect(await titles('out'), ['衣', '食', '住']);

    // 把「住」拖到最前面
    await store.reorderBuckets([c, a, b]);
    expect(await titles('out'), ['住', '衣', '食']);
  });

  test('重排二级分类：只影响同父下的相对顺序', () async {
    final food = await newBucket('食');
    final clothes = await newBucket('衣');
    final breakfast = await newBucket('早餐', parentId: food);
    final lunch = await newBucket('午餐', parentId: food);
    final dinner = await newBucket('晚餐', parentId: food);

    // 展开树：一级在前，紧跟其子分类
    await store.reorderBuckets(
        [clothes, food, dinner, breakfast, lunch]);

    final all = await store.buckets(bookId, 'out');
    final tops = all.where((e) => e.isTop).map((e) => e.title).toList();
    final kids = all
        .where((e) => e.parentId == food)
        .map((e) => e.title)
        .toList();
    expect(tops, ['衣', '食'], reason: '一级顺序跟着整体重排走');
    expect(kids, ['晚餐', '早餐', '午餐'], reason: '同父下的顺序按 rank 排列');
  });

  test('老数据 rank 重复时也能重排干净', () async {
    final a = await newBucket('衣');
    final b = await newBucket('食');
    final c = await newBucket('住');

    // 模拟历史遗留：删过分类、rank 全部撞成 0
    await store.debugSetBucketRank(a, 0);
    await store.debugSetBucketRank(b, 0);
    await store.debugSetBucketRank(c, 0);

    await store.reorderBuckets([b, c, a]);
    expect(await titles('out'), ['食', '住', '衣']);
  });

  test('归档分类不参与主列表，但顺序照样保住', () async {
    final a = await newBucket('衣');
    await newBucket('食');
    await store.archiveBucket(a, true);

    expect(await titles('out'), ['食']);
    final archived = await store.buckets(bookId, 'out', includeArchived: true);
    expect(archived.map((e) => e.title), ['衣', '食'],
        reason: '归档只是隐藏，不改变 rank 顺序');

    // 恢复后回到原位（衣 rank 仍是 0）
    await store.archiveBucket(a, false);
    expect(await titles('out'), ['衣', '食']);
  });
}
