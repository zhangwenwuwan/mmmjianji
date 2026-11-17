import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 分类删除的边界：只有「真的没人用」才允许删。
///
/// 分类是历史流水的维度，删错了不会报错、只会在几个月后对不上账 ——
/// 所以这里逐条钉住：有流水 / 有子分类 / 有周期记账 → 拒绝；
/// 从属数据（快捷模板、分类预算）跟着收尾。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-bucket-del-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  Future<int> newBucket(String title, {int? parentId}) => store.addBucket(
        bookId: bookId,
        title: title,
        glyph: '✨',
        flow: 'out',
        parentId: parentId,
      );

  Future<bool> stillThere(int id) async {
    final list = await store.buckets(bookId, 'out', includeArchived: true);
    return list.any((b) => b.id == id);
  }

  test('没人用的分类可以删除', () async {
    final id = await newBucket('误建的分类');
    final impact = await store.bucketDeleteImpact(id);
    expect(impact.entries, 0);
    expect(impact.children, 0);
    expect(impact.recurring, 0);
    expect(impact.templates, 0);

    await store.deleteBucketIfEmpty(id);
    expect(await stillThere(id), isFalse);
  });

  test('有流水的分类不许删，分类要留着', () async {
    final id = await newBucket('有账的分类');
    final p = (await store.allPockets()).first;
    await store.addEntry(
      bookId: bookId,
      pocketId: p.id,
      bucketId: id,
      flow: 'out',
      amountCents: 1200,
      memo: '测试',
      day: DateTime(2026, 11, 17),
    );

    expect((await store.bucketDeleteImpact(id)).entries, 1);
    await expectLater(
      store.deleteBucketIfEmpty(id),
      throwsA(isA<StateError>()),
    );
    expect(await stillThere(id), isTrue);
  });

  test('回收站里的流水也算「在用」：删了分类，恢复出来就成未分类', () async {
    final id = await newBucket('回收站分类');
    final p = (await store.allPockets()).first;
    final entryId = await store.addEntry(
      bookId: bookId,
      pocketId: p.id,
      bucketId: id,
      flow: 'out',
      amountCents: 800,
      memo: '',
      day: DateTime(2026, 11, 16),
    );
    await store.deleteEntry(entryId);

    expect((await store.bucketDeleteImpact(id)).entries, 1,
        reason: '软删除的流水恢复后仍然指着这个分类');
    await expectLater(
      store.deleteBucketIfEmpty(id),
      throwsA(isA<StateError>()),
    );
  });

  test('有子分类不许删，先处理子分类', () async {
    final parent = await newBucket('父分类');
    await newBucket('子分类', parentId: parent);

    expect((await store.bucketDeleteImpact(parent)).children, 1);
    await expectLater(
      store.deleteBucketIfEmpty(parent),
      throwsA(isA<StateError>()),
    );
    expect(await stillThere(parent), isTrue);
  });

  test('删分类会清掉它的分类预算（预算不能挂在不存在的分类上）', () async {
    final id = await newBucket('带预算的分类');
    final month = DateTime(2026, 11, 1);
    await store.setBucketBudget(bookId, month, id, 50000);
    expect((await store.bucketBudgets(bookId, month))[id], 50000);

    await store.deleteBucketIfEmpty(id);
    expect((await store.bucketBudgets(bookId, month)).containsKey(id), isFalse);
  });

  test('快捷模板引用它时不拦删除，模板保留、分类置空', () async {
    final id = await newBucket('模板用的分类');
    final p = (await store.allPockets()).first;
    await store.addTemplate(
      bookId: bookId,
      title: '每天一杯',
      glyph: '☕',
      flow: 'out',
      pocketId: p.id,
      bucketId: id,
      amountCents: 1500,
      memo: '',
      tags: '',
    );

    expect((await store.bucketDeleteImpact(id)).templates, 1);
    await store.deleteBucketIfEmpty(id);
    expect(await stillThere(id), isFalse);
    final tpl = (await store.templates(bookId)).firstWhere((t) => t.title == '每天一杯');
    expect(tpl.bucketId, isNull, reason: '模板本身要留着，只是分类引用被清空');
  });
}
