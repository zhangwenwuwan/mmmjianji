import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v25 迁移：老库的默认 emoji 图标 → 设计师插画（`ic:`）。
///
/// 两条同样重要：
///   1. 「还是默认 emoji」的必须换 —— 否则升级后一半账户是插画、一半是 emoji，
///      看着像坏了；
///   2. **用户自己挑过的绝对不能动** —— 人家特意选的 🐳 / 🥑 被冲掉，
///      比不换还糟（而且没有任何提示，只能自己发现）。
void main() {
  late Directory tmp;

  setUp(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = await Directory.systemTemp.createTemp('glyphmig');
  });

  tearDown(() async {
    await databaseFactory.deleteDatabase('${tmp.path}/t.db');
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('v24 老库升级：默认 emoji 换成插画，自定义的原样保留', () async {
    final path = '${tmp.path}/t.db';

    // 先按 v25 建库（新库种子已经是 ic: 图标），再手动倒回 1.4.72 的样子
    final s = await LedgerStore.open(path: path);
    final bookId = (await s.books()).first.id;
    await s.addPocket(
      bookId: bookId,
      title: '支付宝',
      glyph: '🅰️',
      kind: PocketKind.bank,
      currency: 'CNY',
      openingCents: 0,
      typeId: 'alipay',
    );
    await s.addPocket(
      bookId: bookId,
      title: '我的卡',
      glyph: '🐳', // 用户自己挑的
      kind: PocketKind.bank,
      currency: 'CNY',
      openingCents: 0,
      typeId: 'bankcard',
    );
    await s.close();

    final raw = await databaseFactory.openDatabase(path);
    await raw.execute("UPDATE buckets SET glyph = '🍜' WHERE title = '食'");
    await raw.execute("UPDATE buckets SET glyph = '🥑' WHERE title = '购'");
    // 1.4.72 的收入分类叫「兼职」（不是新体系里的「副业」）
    await raw.execute(
        "UPDATE buckets SET title = '兼职', glyph = '💼' WHERE title = '副业'");
    await raw.execute('PRAGMA user_version = 24');
    await raw.close();

    final s2 = await LedgerStore.open(path: path);
    final outs = await s2.buckets(bookId, 'out', includeArchived: true);
    final ins = await s2.buckets(bookId, 'in', includeArchived: true);

    expect(outs.firstWhere((b) => b.title == '食').glyph, 'ic:out_food',
        reason: '默认 emoji 应该换成插画');
    expect(outs.firstWhere((b) => b.title == '购').glyph, '🥑',
        reason: '用户自己选的图标不能动');
    expect(ins.firstWhere((b) => b.title == '兼职').glyph, 'ic:in_sidejob',
        reason: '老分类名不变，只换图标');

    final pockets = await s2.allPockets();
    expect(pockets.firstWhere((p) => p.title == '支付宝').glyph,
        'ic:acc_alipay');
    expect(pockets.firstWhere((p) => p.title == '我的卡').glyph, '🐳',
        reason: '用户自己选的图标不能动');
    await s2.close();
  });

  test('新库直接就是插画图标，且分类是 9 支出 / 5 收入', () async {
    final s = await LedgerStore.open(path: '${tmp.path}/n.db');
    final bookId = (await s.books()).first.id;
    final outs = await s.buckets(bookId, 'out');
    final ins = await s.buckets(bookId, 'in');

    expect(outs.length, 9, reason: '4 列网格两行 + 其他');
    expect(ins.length, 5);
    expect(outs.map((b) => b.title).toList(),
        ['食', '行', '住', '购', '玩', '医', '学', '礼', '其他']);
    expect(outs.every((b) => b.glyph.startsWith('ic:')), isTrue);
    expect(ins.every((b) => b.glyph.startsWith('ic:')), isTrue);
    await s.close();
    await databaseFactory.deleteDatabase('${tmp.path}/n.db');
  });

  test('v27：删掉的账户类型归一成自定义，默认 emoji 换插画，用户挑的不动', () async {
    final path = '${tmp.path}/v27.db';
    final s = await LedgerStore.open(path: path);
    final bookId = (await s.books()).first.id;
    Future<void> add(String title, String glyph, PocketKind kind, String type) =>
        s.addPocket(
          bookId: bookId,
          title: title,
          glyph: glyph,
          kind: kind,
          currency: 'CNY',
          openingCents: 0,
          typeId: type,
        );
    await add('微信零钱', '💚', PocketKind.bank, 'wechat');
    await add('股票账户', '📈', PocketKind.bank, 'stock');
    await add('房贷', '🏠', PocketKind.debt, 'mortgage');
    await add('我的卡', '🐳', PocketKind.bank, 'bankcard');
    await s.close();

    final raw = await databaseFactory.openDatabase(path);
    await raw.execute("UPDATE books SET glyph = '📒' WHERE id = $bookId");
    await raw.execute('PRAGMA user_version = 26');
    await raw.close();

    final s2 = await LedgerStore.open(path: path);
    final ps = await s2.allPockets();
    Pocket one(String t) => ps.firstWhere((p) => p.title == t);

    expect(one('微信零钱').typeId, 'wechatWallet', reason: '同义类型并过去');
    expect(one('微信零钱').glyph, 'ic:acc_wechat');

    expect(one('股票账户').typeId, 'custom', reason: '类型没了 → 降级成自定义');
    expect(one('股票账户').kind, PocketKind.bank, reason: '口径不能跟着类型一起变');
    expect(one('股票账户').glyph, 'ic:acc_custom');

    expect(one('房贷').typeId, '', reason: '负债类没有可选类型，清空 type');
    expect(one('房贷').kind, PocketKind.debt,
        reason: 'kind 一改余额符号就翻转（欠 100 变存 100）');
    expect(one('房贷').glyph, 'ic:acc_custom_credit');

    expect(one('我的卡').glyph, '🐳', reason: '类型还在，用户自己挑的图标不能动');

    expect((await s2.books()).first.glyph, 'ic:obj_notebook',
        reason: '账本的旧 emoji 也要换成第二批插画');
    await s2.close();
  });

  test('迁移幂等：重复打开不会把用户的选择改回去', () async {
    final path = '${tmp.path}/t2.db';
    final s = await LedgerStore.open(path: path);
    final bookId = (await s.books()).first.id;
    final food = (await s.buckets(bookId, 'out'))
        .firstWhere((b) => b.title == '食');
    // 用户自己改成披萨
    await s.updateBucket(Bucket(
      id: food.id,
      bookId: food.bookId,
      title: food.title,
      glyph: '🍕',
      flow: food.flow,
      archived: food.archived,
    ));
    await s.close();

    final s2 = await LedgerStore.open(path: path);
    final again = await s2.buckets(bookId, 'out');
    expect(again.firstWhere((b) => b.title == '食').glyph, '🍕');
    await s2.close();
    await databaseFactory.deleteDatabase(path);
  });
}
