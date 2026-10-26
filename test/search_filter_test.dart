import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 搜索筛选的语义测试。
///
/// 这里钉的是**「同时满足 / 满足任一」到底怎么算**，而不是 UI 长什么样：
/// 这两个模式在 SQL 里差一个 OR，写错了用户会觉得"筛选失灵"但界面看不出来。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;
  late int cashId;
  late int cardId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-search-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
    final pockets = await store.allPockets(includeArchived: false);
    cashId = pockets.first.id;
    await store.addPocket(
      bookId: bookId,
      title: '信用卡',
      glyph: '💳',
      kind: PocketKind.credit,
      currency: 'CNY',
      openingCents: 0,
    );
    cardId =
        (await store.allPockets(includeArchived: false)).firstWhere((p) => p.title == '信用卡').id;
    final out = await store.buckets(bookId, 'out');
    // 默认支出分类 2026-10-26 起是「衣/食/住/行」，不再是「餐饮」
    final dining = out.firstWhere((b) => b.title.contains('食'));
    final day = DateTime(2026, 10, 10);

    // 三笔刻意设计的数据：
    // A：备注含"咖啡" + 打了"出差"标签 + 待报销 + 信用卡
    // B：备注含"咖啡" + 无标签 + 不报销 + 现金
    // C：备注含"打车" + "出差"标签 + 不报销 + 现金
    await store.addEntry(
      bookId: bookId,
      pocketId: cardId,
      bucketId: dining.id,
      flow: 'out',
      amountCents: 3800,
      memo: '咖啡',
      day: day,
      tags: '出差',
      reimburse: 1,
    );
    await store.addEntry(
      bookId: bookId,
      pocketId: cashId,
      bucketId: dining.id,
      flow: 'out',
      amountCents: 2500,
      memo: '咖啡',
      day: day,
    );
    await store.addEntry(
      bookId: bookId,
      pocketId: cashId,
      bucketId: dining.id,
      flow: 'out',
      amountCents: 1500,
      memo: '打车',
      day: day,
      tags: '出差',
    );
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  test('AND（同时满足）：关键词 + 标签 必须都命中', () async {
    final list = await store.searchEntriesEx(
      bookId,
      keyword: '咖啡',
      tags: ['出差'],
    );
    expect(list.length, 1);
    expect(list.first.memo, '咖啡');
    expect(list.first.tags, '出差');
  });

  test('OR（满足任一）：关键词 或 标签 命中即可', () async {
    final list = await store.searchEntriesEx(
      bookId,
      keyword: '咖啡',
      tags: ['出差'],
      matchAny: true,
    );
    // A(咖啡+出差) B(咖啡) C(打车+出差) 全部符合
    expect(list.length, 3);
  });

  test('AND 下两个互斥条件 → 空结果（不是取并集）', () async {
    final list = await store.searchEntriesEx(
      bookId,
      keyword: '打车',
      pocketIds: [cardId],
    );
    expect(list, isEmpty);
  });

  test('按账户筛：转账时转入方也算命中', () async {
    await store.addEntry(
      bookId: bookId,
      pocketId: cashId,
      toPocketId: cardId,
      flow: 'transfer',
      amountCents: 10000,
      memo: '还信用卡',
      day: DateTime(2026, 10, 11),
    );
    final byCard = await store.searchEntriesEx(bookId, pocketIds: [cardId]);
    // 一笔消费 + 一笔转入
    expect(byCard.length, 2);
  });

  test('报销状态筛选：待报销 只出标记为 1 的', () async {
    final pending = await store.searchEntriesEx(bookId, reimburse: 1);
    expect(pending.length, 1);
    expect(pending.first.memo, '咖啡');
    expect(pending.first.reimburse, 1);
  });

  test('reimburse=0 / null 视为「不限」', () async {
    final all = await store.searchEntriesEx(bookId);
    expect(all.length, 3);
    final zero = await store.searchEntriesEx(bookId, reimburse: 0);
    expect(zero.length, 3);
  });

  test('金额区间 + 日期区间仍然生效（回归）', () async {
    final list = await store.searchEntriesEx(
      bookId,
      minCents: 2000,
      from: DateTime(2026, 10, 1),
      to: DateTime(2026, 10, 31),
    );
    expect(list.length, 2);
  });

  test('book_id 永远 AND：不因 matchAny 泄漏到其它账本', () async {
    final other = await store.addBook('第二个账本', '📘', 'CNY');
    await store.addEntry(
      bookId: other,
      pocketId: (await store.allPockets(includeArchived: false)).first.id,
      flow: 'out',
      amountCents: 9999,
      memo: '咖啡',
      day: DateTime(2026, 10, 10),
    );
    final list = await store.searchEntriesEx(
      bookId,
      keyword: '咖啡',
      matchAny: true,
    );
    expect(list.every((e) => e.bookId == bookId), isTrue);
    expect(list.length, 2);
  });

  group('allTags', () {
    test('按出现次数降序，且拆分逗号分隔的多标签', () async {
      await store.addEntry(
        bookId: bookId,
        pocketId: cashId,
        flow: 'out',
        amountCents: 100,
        memo: '多标签',
        day: DateTime(2026, 10, 12),
        tags: '出差,报销',
      );
      final tags = await store.allTags(bookId);
      expect(tags.first, '出差'); // 3 次
      expect(tags, containsAll(['报销']));
      // 没有空串或残留逗号
      expect(tags.any((t) => t.trim().isEmpty), isFalse);
    });

    test('没有标签时返回空列表，不抛异常', () async {
      final empty = await store.addBook('空账本', '📗', 'CNY');
      expect(await store.allTags(empty), isEmpty);
    });
  });
}
