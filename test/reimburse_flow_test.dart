import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 报销入账（2026-10-28 用户要求）的回归测试。
///
/// 关键点不是"标记位变了"，而是**钱真的到了账户上、撤回来的时候又会退回去**。
/// 这两件事以前都没有，靠肉眼也看不出余额少了一截。
void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;
  late Pocket wallet;
  late Pocket bank;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-reimburse-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
    await store.addPocket(
      bookId: bookId,
      title: '钱包',
      glyph: '👛',
      kind: PocketKind.cash,
      currency: 'CNY',
      openingCents: 0,
    );
    await store.addPocket(
      bookId: bookId,
      title: '工资卡',
      glyph: '🏦',
      kind: PocketKind.bank,
      currency: 'CNY',
      openingCents: 0,
    );
    final all = await store.allPockets();
    wallet = all.firstWhere((p) => p.title == '钱包');
    bank = all.firstWhere((p) => p.title == '工资卡');
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  Future<int> addPending({int cents = 12000, String? currency}) => store.addEntry(
        bookId: bookId,
        pocketId: wallet.id,
        flow: 'out',
        amountCents: cents,
        memo: '打车去客户',
        day: DateTime(2026, 10, 20),
        reimburse: 1,
        currency: currency,
      );

  Future<int> balanceOf(int pocketId) async {
    final rows = await store.pocketBalances();
    return rows.firstWhere((r) => r.pocket.id == pocketId).balanceCents;
  }

  test('标记已报销：钱记到指定账户，原流水变已报销', () async {
    final id = await addPending();
    expect(await balanceOf(wallet.id), -12000);

    final created = await store.reimburseTo(id, bank.id, day: DateTime(2026, 10, 25));
    expect(created, greaterThan(0));

    final entry = (await store.entriesOfMonth(bookId, DateTime(2026, 10)))
        .firstWhere((e) => e.id == id);
    expect(entry.reimburse, 2, reason: '原流水要变成已报销');
    expect(entry.reimburseEntryId, created, reason: '要存下入账流水的 id');

    // 目标账户凭空多出一笔收入
    expect(await balanceOf(bank.id), 12000);

    final credit = (await store.entriesOfMonth(bookId, DateTime(2026, 10)))
        .firstWhere((e) => e.id == created);
    expect(credit.flow, 'in');
    expect(credit.pocketId, bank.id);
    expect(credit.amountCents, 12000);
    expect(credit.memo, contains('报销'));
    expect(credit.tags, '报销');
  });

  test('撤回报销：入账那笔一起删掉，余额回落', () async {
    final id = await addPending();
    final created = await store.reimburseTo(id, bank.id);
    expect(await balanceOf(bank.id), 12000);

    await store.unreimburse(id);

    expect(await balanceOf(bank.id), 0, reason: '撤回后不能再留一笔收入');
    final entry = (await store.entriesOfMonth(bookId, DateTime(2026, 10)))
        .firstWhere((e) => e.id == id);
    expect(entry.reimburse, 1);
    expect(entry.reimburseEntryId, isNull);
    final all = await store.entriesOfMonth(bookId, DateTime(2026, 10));
    expect(all.where((e) => e.id == created), isEmpty, reason: '入账流水要真删掉');
  });

  test('重复标记不会重复入账', () async {
    final id = await addPending();
    final first = await store.reimburseTo(id, bank.id);
    final second = await store.reimburseTo(id, bank.id);
    expect(second, first, reason: '第二次直接返回已有入账流水');
    expect(await balanceOf(bank.id), 12000, reason: '钱只加一次');
  });

  test('报销到原账户也算数（自己先垫的钱回到自己卡上）', () async {
    final id = await addPending();
    await store.reimburseTo(id, wallet.id);
    // 支出 -12000 + 收入 +12000
    expect(await balanceOf(wallet.id), 0);
  });

  test('外币流水：币种跟着带到入账流水上', () async {
    final id = await addPending(currency: 'USD');
    final created = await store.reimburseTo(id, bank.id);
    final credit = (await store.entriesOfMonth(bookId, DateTime(2026, 10)))
        .firstWhere((e) => e.id == created);
    expect(credit.currency, 'USD');
  });

  // ---------------------------------------------------------------
  // 级联删除（2026-10-28）
  //
  // 报销入账是「派生流水」，删任何一边都必须管另一边，否则余额永久对不上。
  // 这组用例盯的就是钱：每一步都断言**两个账户的余额**，不只看标记位。
  // ---------------------------------------------------------------

  test('删掉已报销的原流水：入账收入一起进回收站，余额双双回落', () async {
    final id = await addPending();
    final created = await store.reimburseTo(id, bank.id);
    expect(await balanceOf(wallet.id), -12000);
    expect(await balanceOf(bank.id), 12000);

    await store.deleteEntry(id);

    expect(await balanceOf(wallet.id), 0, reason: '支出没了，钱包该回到 0');
    expect(await balanceOf(bank.id), 0, reason: '钱没真回来，收入也要一起走');
    final bin = [for (final e in await store.recycleBinEntries(bookId)) e.id];
    expect(bin, containsAll(<int>[id, created]), reason: '两条都要在回收站里');
  });

  test('从回收站恢复原流水：入账收入跟着回来，余额恢复原样', () async {
    final id = await addPending();
    final created = await store.reimburseTo(id, bank.id);
    await store.deleteEntry(id);

    final restored = await store.restoreEntries([id]);
    expect(restored, 2, reason: '恢复的是两条：原流水 + 派生收入');

    expect(await balanceOf(wallet.id), -12000);
    expect(await balanceOf(bank.id), 12000);
    final entry = (await store.entriesOfMonth(bookId, DateTime(2026, 10)))
        .firstWhere((e) => e.id == id);
    expect(entry.reimburse, 2);
    expect(entry.reimburseEntryId, created, reason: '指针要还在，否则「撤回」找不到那笔钱');
  });

  test('只删那笔报销收入：原流水退回待报销，不会再显示「已报销」', () async {
    final id = await addPending();
    final created = await store.reimburseTo(id, bank.id);

    await store.deleteEntry(created);

    expect(await balanceOf(bank.id), 0);
    final entry = (await store.entriesOfMonth(bookId, DateTime(2026, 10)))
        .firstWhere((e) => e.id == id);
    expect(entry.reimburse, 1, reason: '钱没进来，就不能还挂着已报销');
    expect(entry.reimburseEntryId, isNull, reason: '指针要清掉，否则撤回会去删一个不存在的 id');
  });

  test('永久删除原流水：入账收入一并消失', () async {
    final id = await addPending();
    final created = await store.reimburseTo(id, bank.id);

    final removed = await store.purgeEntries([id]);
    expect(removed, 2);

    final all = await store.entriesOfMonth(bookId, DateTime(2026, 10));
    expect(all.where((e) => e.id == id), isEmpty);
    expect(all.where((e) => e.id == created), isEmpty);
    expect(await balanceOf(bank.id), 0);
  });

  test('两条一起删再恢复：不会变成「待报销」导致重复入账', () async {
    final id = await addPending();
    final created = await store.reimburseTo(id, bank.id);

    // 批量勾选两条一起删（用户可能这么干，界面上两行都在流水里）
    await store.softDeleteEntries([id, created]);
    // 只恢复原流水，派生收入当时是跟着删的，恢复时也应当自动跟回来
    await store.restoreEntries([id]);

    final entry = (await store.entriesOfMonth(bookId, DateTime(2026, 10)))
        .firstWhere((e) => e.id == id);
    expect(entry.reimburse, 2,
        reason: '同时删的时候不能把标记退回待报销，否则恢复后再点一次就重复入账');
    expect(await balanceOf(bank.id), 12000);

    // 再点一次「已报销」也只会返回原来那笔
    final again = await store.reimburseTo(id, bank.id);
    expect(again, created);
    expect(await balanceOf(bank.id), 12000, reason: '钱不能再加一次');
  });
}
