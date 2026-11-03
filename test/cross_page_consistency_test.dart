import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/currency.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 跨页面口径一致性。
///
/// 记账 App 最伤信任的 bug 不是崩溃，而是**同一个月两个页面报不同数字**：
/// 首页说花了 660、统计页说 680、预算页说 740 —— 用户一旦发现，就再也不信任何数字了。
///
/// 本项目有两套聚合实现，天然有分裂风险：
/// 1. **Dart 逐笔累加**（`totalsProvider` / `budgetSpentOf`）—— 首页、统计卡片用；
/// 2. **SQL 聚合**（`monthTotalsByFlow` / `bucketSpent`）—— 分类排行、趋势、预算页用。
///
/// 这个文件就是用一笔明细账把两套实现钉在一起，顺带把几条容易搞错的语义
/// （AA 只算我的份额、跨币种折算、转账不进统计、两个"不计入"开关各自管什么）
/// 变成可执行的断言。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late String dbPath;
  final month = DateTime(2026, 11);

  // 明细账（单位：分）。特意把每条路径都铺到：
  //   ① 普通支出 100 元
  //   ② AA 支出：垫付 300，他人承担 200 → 我的份额 100
  //   ③ 外币支出：10.00 USD × 7.2 = 72 元
  //   ④ 「不计入收支」的支出 80 元
  //   ⑤ 「不计入预算」的支出 60 元
  //   ⑥ 收入 5000 元
  //   ⑦ 账户间转账 200 元（不该进任何统计）
  //   ⑧ 子分类「外卖」支出 40 元（要并进父分类「食」）
  const e1Food = 10000;
  const e2AaAmount = 30000;
  const e2AaSplit = 20000;
  const e2Mine = e2AaAmount - e2AaSplit; // 10000
  const e3UsdCents = 5000; // 10.00 USD

  late int bookId;
  late int cnyPocketId;
  late int usdPocketId;
  late int foodId;
  late int clothesId;
  late int liveId;
  late int moveId;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jj-consist-');
    dbPath = '${tmp.path}/c.db';
    final store = await LedgerStore.open(path: dbPath);
    final book = (await store.books()).first;
    bookId = book.id;
    await store.setRate(bookId, 'USD', 7.2);

    final pockets = await store.allPockets(includeArchived: false);
    cnyPocketId = pockets.first.id;
    await store.addPocket(
      bookId: bookId,
      title: '美元卡',
      glyph: '💵',
      kind: PocketKind.cash,
      currency: 'USD',
      openingCents: 0,
    );
    usdPocketId = (await store.allPockets())
        .firstWhere((p) => p.currency == 'USD' && !p.archived)
        .id;

    final buckets = await store.buckets(bookId, 'out');
    foodId = buckets.firstWhere((b) => b.title == '食').id;
    clothesId = buckets.firstWhere((b) => b.title == '衣').id;
    liveId = buckets.firstWhere((b) => b.title == '住').id;
    moveId = buckets.firstWhere((b) => b.title == '行').id;

    Future<void> add({
      required int cents,
      int? bucketId,
      int? pocketId,
      String flow = 'out',
      int split = 0,
      bool noStats = false,
      bool noBudget = false,
      String? currency,
      int day = 5,
    }) =>
        store.addEntry(
          bookId: bookId,
          pocketId: pocketId ?? cnyPocketId,
          bucketId: bucketId,
          flow: flow,
          amountCents: cents,
          memo: '明细',
          day: DateTime(2026, 11, day),
          splitCents: split,
          excludeFromStats: noStats,
          excludeFromBudget: noBudget,
          currency: currency,
        );

    await add(cents: e1Food, bucketId: foodId); // ①
    await add(
        cents: e2AaAmount, bucketId: foodId, split: e2AaSplit, day: 6); // ②
    await add(
        cents: e3UsdCents,
        bucketId: clothesId,
        pocketId: usdPocketId,
        currency: 'USD',
        day: 7); // ③
    await add(
        cents: 8000, bucketId: liveId, noStats: true, day: 8); // ④
    await add(
        cents: 6000, bucketId: moveId, noBudget: true, day: 9); // ⑤
    await add(cents: 500000, flow: 'in', day: 10); // ⑥
    await store.addEntry(
      bookId: bookId,
      pocketId: cnyPocketId,
      toPocketId: usdPocketId,
      flow: 'transfer',
      amountCents: 20000,
      memo: '转账',
      day: DateTime(2026, 11, 11),
    ); // ⑦
    await store.addBucket(
        bookId: bookId, title: '外卖', glyph: '🍱', flow: 'out', parentId: foodId);
    final takeout =
        (await store.buckets(bookId, 'out')).firstWhere((b) => b.title == '外卖');
    await add(cents: 4000, bucketId: takeout.id, day: 12); // ⑧

    await store.close();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  ProviderContainer makeContainer() {
    final c = ProviderContainer(
      overrides: [databasePathProvider.overrideWithValue(dbPath)],
    );
    addTearDown(c.dispose);
    // 首页/统计/预算都读 monthProvider，先把它挪到测试月
    c.read(monthProvider.notifier).state = month;
    return c;
  }

  test('首页合计（Dart 逐笔累加）与 SQL 聚合给出同一个数', () async {
    final c = makeContainer();
    final store = await c.read(storeProvider.future);
    final book = await c.read(activeBookProvider.future);

    final dartTotals = await c.read(totalsProvider.future);
    final sqlTotals = await store.monthTotalsByFlow(book.id, month);

    // 支出：100 + 100(AA后) + 360(外币折算) + 60(不计预算但仍算收支) + 40(外卖)
    // 不含：80(不计收支)、200(转账)
    const expectedExpense = e1Food + e2Mine + 36000 + 6000 + 4000;
    expect(dartTotals.expenseCents, expectedExpense);
    expect(sqlTotals['out'], expectedExpense, reason: 'SQL 与 Dart 的支出口径必须一致');

    const expectedIncome = 500000;
    expect(dartTotals.incomeCents, expectedIncome);
    expect(sqlTotals['in'], expectedIncome, reason: 'SQL 与 Dart 的收入口径必须一致');
  });

  test('预算已花：Dart 累加与 SQL 分类汇总一致，且两者都排除「不计入预算」', () async {
    final c = makeContainer();
    final store = await c.read(storeProvider.future);
    final book = await c.read(activeBookProvider.future);

    final dartSpent = await budgetSpentOf(store, book, month);
    final rates = await store.rates(book.id);
    final rows = await store.bucketSpent(book.id, month);
    var sqlSpent = 0;
    for (final r in rows) {
      sqlSpent += toBaseCents(r.cents, r.currency, book.baseCurrency, rates);
    }

    // 预算口径 = 支出统计口径，再去掉「不计入预算」的 60 元，加上「不计收支」的 80 元
    // （两个开关互相独立，见文件末尾那条用例）
    const expected = e1Food + e2Mine + 36000 + 8000 + 4000;
    expect(dartSpent, expected);
    expect(sqlSpent, expected, reason: '预算页和首页提示条必须同一个数，否则一边说超一边说没超');
  });

  test('分类预算清单的「已花」与分类预算页同源（子分类已并入父分类）', () async {
    final store = await LedgerStore.open(path: dbPath);
    final book = (await store.books()).first;
    await store.setBucketBudget(book.id, month, foodId, 50000);
    await store.setBucketBudget(book.id, month, clothesId, 10000);
    await store.close();

    final c = makeContainer();
    final status = await bucketBudgetStatusOf(
        await c.read(storeProvider.future),
        await c.read(activeBookProvider.future),
        month);
    final providerMap = await c.read(bucketSpentProvider.future);

    for (final s in status) {
      expect(s.spentCents, providerMap[s.bucketId] ?? 0,
          reason: '${s.title} 的已花在两个实现里不一致');
    }
    final food = status.firstWhere((s) => s.title == '食');
    // 100 + 100 + 40(外卖并进父分类)
    expect(food.spentCents, 24000);
    expect(food.budgetCents, 50000);

    final clothes = status.firstWhere((s) => s.title == '衣');
    expect(clothes.spentCents, 36000, reason: '外币要折算成主币种再比预算');
    expect(clothes.spentCents > clothes.budgetCents, isTrue);
  });

  test('按天汇总加起来必须等于整月（两个 SQL 聚合同口径）', () async {
    final c = makeContainer();
    final store = await c.read(storeProvider.future);

    final monthMap = await store.monthTotalsByFlow(bookId, month);
    final daily = await store.dailyTotalsByFlow(bookId, month);
    var out = 0;
    var inc = 0;
    for (final m in daily.values) {
      out += m['out'] ?? 0;
      inc += m['in'] ?? 0;
    }
    expect(out, monthMap['out'], reason: '日历按天加起来应与首页整月一致');
    expect(inc, monthMap['in']);
  });

  test('数据层仍允许「只排收支、不排预算」的组合（UI 已禁止产生它）', () async {
    final store = await LedgerStore.open(path: dbPath);
    final book = (await store.books()).first;
    await store.setBucketBudget(book.id, month, liveId, 5000);
    final status = await bucketBudgetStatusOf(store, book, month);
    await store.close();

    final live = status.firstWhere((s) => s.title == '住');
    // 这笔在种子数据里是 excludeFromStats=true / excludeFromBudget=false，
    // 属于**绕过 UI 直接写库**才可能出现的组合。数据层保持"两个开关各管各的"，
    // 但 `editor_page.dart` 已做成联动（勾「不计收支」自动勾「不计预算」），
    // 并在保存时兜一层 `_excludeBudget || _excludeStats`，正常操作不会造出这种数据。
    // 保留这条断言是为了钉住"层与层的职责"：口径由保存端保证，聚合端不必特判。
    expect(live.spentCents, 8000);
    expect(live.spentCents > live.budgetCents, isTrue);
  });
}
