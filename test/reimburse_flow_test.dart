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
}
