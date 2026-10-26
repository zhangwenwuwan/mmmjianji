import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 账本即作用域 = **全局余额**（用户 2026-10-23 拍板）的回归测试。
///
/// 语义：
///   · 账户跨账本共享 —— 余额 = 该账户在**所有账本**的流水之和
///   · 分类仍然按账本隔离（分类是账本自己的组织结构）
///   · 删账本不能删掉别的账本还在用的账户
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookA;
  late int bookB;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-global-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookA = (await store.books()).first.id;
    bookB = await store.addBook('第二个账本', '📘', 'CNY');
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  Future<Pocket> pocketByTitle(String t) async =>
      (await store.allPockets()).firstWhere((p) => p.title == t);

  Future<void> spend(int bookId, int pocketId, int cents,
      {String memo = '', DateTime? day}) {
    return store.addEntry(
      bookId: bookId,
      pocketId: pocketId,
      bucketId: null,
      flow: 'out',
      amountCents: cents,
      memo: memo,
      day: day ?? DateTime(2026, 10, 21),
      tags: '',
    );
  }

  group('全局余额', () {
    test('同一账户在两个账本记账，余额是两者之和', () async {
      final cash = await pocketByTitle('现金');
      await spend(bookA, cash.id, 3000); // 账本 A 花 30
      await spend(bookB, cash.id, 2000); // 账本 B 花 20

      final balances = {for (final b in await store.pocketBalances()) b.pocket.id: b.balanceCents};
      // 期初 0 + (-30) + (-20) = -50
      expect(balances[cash.id], -5000,
          reason: '全局余额必须把两个账本的流水加在一起');
    });

    test('切账本不影响余额（余额与当前账本无关）', () async {
      final cash = await pocketByTitle('现金');
      await spend(bookA, cash.id, 1000);
      final before = (await store.pocketBalances())
          .firstWhere((b) => b.pocket.id == cash.id)
          .balanceCents;
      // 切到账本 B 再查一次（pocketBalances 不接收账本参数）
      final after = (await store.pocketBalances())
          .firstWhere((b) => b.pocket.id == cash.id)
          .balanceCents;
      expect(after, before);
      expect(after, -1000);
    });

    test('转账两边都按全局累计（含手续费口径）', () async {
      final cash = await pocketByTitle('现金');
      final bank = await pocketByTitle('银行卡');
      await store.addEntry(
        bookId: bookA,
        pocketId: cash.id,
        toPocketId: bank.id,
        bucketId: null,
        flow: 'transfer',
        amountCents: 10000,
        feeCents: 200,
        memo: '取现',
        day: DateTime(2026, 10, 21),
      );
      await store.addEntry(
        bookId: bookB,
        pocketId: cash.id,
        toPocketId: bank.id,
        bucketId: null,
        flow: 'transfer',
        amountCents: 5000,
        memo: '再取',
        day: DateTime(2026, 10, 21),
      );
      final balances = {
        for (final b in await store.pocketBalances()) b.pocket.id: b.balanceCents
      };
      // 现金：-(100+2) - 50 = -152；银行卡：+100 + 50 = +150
      expect(balances[cash.id], -15200);
      expect(balances[bank.id], 15000);
    });

    test('账户流水跨账本（详情页列表和余额口径一致）', () async {
      final cash = await pocketByTitle('现金');
      await spend(bookA, cash.id, 1000, memo: 'A 账本的花费');
      await spend(bookB, cash.id, 2000, memo: 'B 账本的花费');
      final list = await store.entriesOfPocket(cash.id);
      expect(list.length, 2, reason: '两个账本的流水都要能看到');
      expect(list.map((e) => e.memo).toSet(), {'A 账本的花费', 'B 账本的花费'});
    });

    test('新建账本不再重复创建「现金/银行卡」（账户是共享的）', () async {
      final before = (await store.allPockets()).map((p) => p.title).toList();
      expect(before.where((t) => t == '现金').length, 1,
          reason: '首个账本 seed 出一份默认账户');
      final bookC = await store.addBook('第三个账本', '📗', 'CNY');
      final after = (await store.allPockets()).map((p) => p.title).toList();
      expect(after.where((t) => t == '现金').length, 1,
          reason: '新账本必须复用现有账户，不能再来一份重名的');
      // 但分类仍然是每个账本自己的
      expect((await store.buckets(bookC, 'out')).isNotEmpty, true);
    });

    test('allPockets 返回全部账本的账户', () async {
      await store.addPocket(
        bookId: bookB,
        title: 'B 账本专属卡',
        glyph: '💳',
        kind: PocketKind.credit,
        currency: 'CNY',
        openingCents: 0,
      );
      final all = await store.allPockets();
      final titles = all.map((p) => p.title).toSet();
      expect(titles, contains('现金'));
      expect(titles, contains('B 账本专属卡'));
      // 注意 allPockets() 默认**含归档**，查可用账户要显式传 false
      await store.archivePocket(
          (await store.allPockets())
              .firstWhere((p) => p.title == 'B 账本专属卡')
              .id,
          true);
      expect((await store.allPockets(includeArchived: false)).map((p) => p.title),
          isNot(contains('B 账本专属卡')));
      expect((await store.allPockets(includeArchived: true)).map((p) => p.title),
          contains('B 账本专属卡'));
    });
  });

  group('分类仍按账本隔离', () {
    test('账本 B 看不到账本 A 的分类', () async {
      final aBuckets = await store.buckets(bookA, 'out');
      final bBuckets = await store.buckets(bookB, 'out');
      expect(aBuckets.isNotEmpty, true);
      expect(bBuckets.isNotEmpty, true);
      // 两边都是默认 8 个一级分类，但 id 不重叠（各自独立）
      expect(aBuckets.map((b) => b.id).toSet().intersection(bBuckets.map((b) => b.id).toSet()),
          isEmpty,
          reason: '分类必须按账本隔离，不能跨账本共享');
    });

    test('在账本 B 新增分类不影响账本 A', () async {
      await store.addBucket(bookId: bookB, title: '只有 B 有', glyph: '🆕', flow: 'out');
      final aTitles = (await store.buckets(bookA, 'out')).map((b) => b.title).toSet();
      expect(aTitles, isNot(contains('只有 B 有')));
      final bTitles = (await store.buckets(bookB, 'out')).map((b) => b.title).toSet();
      expect(bTitles, contains('只有 B 有'));
    });
  });

  group('删账本保护共享账户', () {
    test('别的账本还在用的账户不能被删掉', () async {
      final cash = await pocketByTitle('现金');
      await spend(bookA, cash.id, 1000);
      await spend(bookB, cash.id, 2000); // 账本 B 也用了这个账户

      await store.deleteBook(bookB);

      final after = {for (final b in await store.pocketBalances()) b.pocket.id: b.balanceCents};
      expect(after.containsKey(cash.id), true,
          reason: '共享账户不能跟着账本一起消失');
      // 只剩账本 A 的那 10 块
      expect(after[cash.id], -1000);
    });

    test('只在本账本用过的账户，删账本时跟着删', () async {
      await store.addPocket(
        bookId: bookB,
        title: 'B 专属',
        glyph: '🧾',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 0,
      );
      final only = await pocketByTitle('B 专属');
      await spend(bookB, only.id, 500);

      await store.deleteBook(bookB);

      final titles = (await store.allPockets()).map((p) => p.title).toSet();
      expect(titles, isNot(contains('B 专属')),
          reason: '没人再用的账户应该跟着账本清掉，否则越攒越多');
      expect(titles, contains('现金'));
    });
  });
}
