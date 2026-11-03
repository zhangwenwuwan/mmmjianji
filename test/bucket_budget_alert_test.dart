import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 分类预算提醒的口径。
///
/// 这些用例守的是一个很容易悄悄坏掉的东西：**提醒和预算页必须用同一份算法**。
/// 只要有一处把子分类漏掉、或把 AA 他人承担算进来，就会出现
/// 「预算页说没超、手机却弹通知说超了」——用户直接不信这个功能了。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late LedgerStore store;
  late Book book;
  late int bookId;
  late Bucket food;
  late Bucket clothes;
  final month = DateTime(2026, 11);

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jj-bbalert-');
    store = await LedgerStore.open(path: '${tmp.path}/t.db');
    book = (await store.books()).first;
    bookId = book.id;
    final out = await store.buckets(bookId, 'out');
    food = out.firstWhere((b) => b.title == '食');
    clothes = out.firstWhere((b) => b.title == '衣');
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  Future<int> spend(int cents, Bucket bucket, {int split = 0}) async {
    final pocket = (await store.allPockets(includeArchived: false)).first;
    return store.addEntry(
      bookId: bookId,
      pocketId: pocket.id,
      bucketId: bucket.id,
      flow: 'out',
      amountCents: cents,
      memo: '测试',
      day: DateTime(2026, 11, 5),
      splitCents: split,
    );
  }

  test('设了预算的分类才出现在清单里，金额对得上', () async {
    await store.setBucketBudget(bookId, month, food.id, 50000);
    await spend(60000, food);
    // 衣没设预算，花了也不该出现
    await spend(9999, clothes);

    final s = await bucketBudgetStatusOf(store, book, month);
    expect(s.length, 1);
    expect(s.first.bucketId, food.id);
    expect(s.first.title, '食');
    expect(s.first.budgetCents, 50000);
    expect(s.first.spentCents, 60000);
  });

  test('子分类的钱并进父分类（给「食」设预算、钱记在「外卖」上）', () async {
    await store.setBucketBudget(bookId, month, food.id, 50000);
    await store.addBucket(
        bookId: bookId, title: '外卖', glyph: '🍱', flow: 'out', parentId: food.id);
    final takeout =
        (await store.buckets(bookId, 'out')).firstWhere((b) => b.title == '外卖');

    await spend(30000, takeout);
    final s = await bucketBudgetStatusOf(store, book, month);
    expect(s.length, 1);
    // 漏了这一步的话「食」永远显示已花 0，预算等于失效
    expect(s.first.spentCents, 30000);
  });

  test('AA 他人承担不占分类预算（只算我的份额）', () async {
    await store.setBucketBudget(bookId, month, food.id, 50000);
    await spend(30000, food, split: 20000);
    final s = await bucketBudgetStatusOf(store, book, month);
    expect(s.first.spentCents, 10000);
  });

  test('按「超出金额」降序，超得最多的排第一', () async {
    await store.setBucketBudget(bookId, month, food.id, 10000);
    await store.setBucketBudget(bookId, month, clothes.id, 10000);
    await spend(15000, food); // 超 5000
    await spend(40000, clothes); // 超 30000
    final s = await bucketBudgetStatusOf(store, book, month);
    expect(s.map((e) => e.title).toList(), ['衣', '食']);
  });

  test('没设任何分类预算时不返回清单（不白算一遍）', () async {
    await spend(60000, food);
    expect(await bucketBudgetStatusOf(store, book, month), isEmpty);
  });

  test('分类被归档后，残留的预算行不再参与提醒', () async {
    await store.setBucketBudget(bookId, month, clothes.id, 10000);
    await spend(40000, clothes);
    await store.archiveBucket(clothes.id, true);
    // 预算行还在表里，但分类已经不在「在用分类」里 —— 不该再报它
    expect((await store.bucketBudgets(bookId, month))[clothes.id], 10000);
    expect(await bucketBudgetStatusOf(store, book, month), isEmpty);
  });

  test('换算成主币种：跨币种支出按汇率折算后再比预算', () async {
    await store.setRate(bookId, 'USD', 7.2);
    await store.setBucketBudget(bookId, month, food.id, 5000);
    await store.addPocket(
      bookId: bookId,
      title: '美元卡',
      glyph: '💵',
      kind: PocketKind.cash,
      currency: 'USD',
      openingCents: 0,
    );
    final usd = (await store.allPockets())
        .firstWhere((p) => p.currency == 'USD' && !p.archived);
    await store.addEntry(
      bookId: bookId,
      pocketId: usd.id,
      bucketId: food.id,
      flow: 'out',
      amountCents: 1000, // 10.00 USD × 7.2 = 7200 分
      memo: '海外',
      day: DateTime(2026, 11, 6),
    );
    final s = await bucketBudgetStatusOf(store, book, month);
    expect(s.first.spentCents, 7200);
    expect(s.first.spentCents > s.first.budgetCents, isTrue);
  });
}
