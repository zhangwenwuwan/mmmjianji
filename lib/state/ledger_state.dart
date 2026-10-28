import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/aggregate.dart';
import '../core/budget_rules.dart';
import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../services/biometric_service.dart';
import 'settings.dart';

/// 数据库文件路径。null = 用默认位置（应用私有目录）。
/// 测试里覆盖它来隔离数据，避免多个测试用例抢同一个库文件。
final databasePathProvider = Provider<String?>((ref) => null);

/// 数据库句柄
///
/// `withSamplePockets: false`：**新装 App 不预置「现金 / 银行卡」**（2026-10-25
/// 用户要求，账户数从 0 开始，自己建）。预置的两个名字对不上真实账户，
/// 用户第一件事就是删掉它们再建自己的，反而多两步。
/// 测试仍走默认值 true（它们依赖默认账户，见 store.dart 里的说明）。
final storeProvider = FutureProvider<LedgerStore>((ref) async {
  final store = await LedgerStore.open(
    path: ref.watch(databasePathProvider),
    withSamplePockets: false,
  );
  ref.onDispose(store.close);
  return store;
});

/// 设备是否**具备**生物识别能力（不看有没有录入）。
///
/// 桌面/模拟器上直接 false（见 BiometricService 的平台判断）。
/// 注意别再拿「已录入」当开关可用条件 —— 那会让没录指纹的机器上开关永远点不动。
final biometricSupportedProvider =
    FutureProvider<bool>((ref) => BiometricService.isSupported());

/// 系统里是否已经录了指纹 / 面容（只影响设置页的提示文案）。
final biometricEnrolledProvider =
    FutureProvider<bool>((ref) => BiometricService.hasEnrolled());

/// 写入后自增，所有读类 provider 都 watch 它。
final revisionProvider = StateProvider<int>((ref) => 0);

/// 让所有依赖 revisionProvider 的查询重读。
///
/// ⚠️ 必须在 await 之后调用也安全：保存过程中用户按返回键退出时，
/// widget 已 dispose，`ref.read` 会抛
///   StateError: Cannot use "ref" after the widget was disposed.
/// 那时数据其实已经写库了，revision 不自增只是界面不刷新；
/// 抛异常反而会把未捕获异步错误送进 AppLog，看起来像崩溃。
void bumpRevision(WidgetRef ref) {
  try {
    ref.read(revisionProvider.notifier).state++;
  } on StateError catch (_) {
    // 已 dispose，忽略
  }
}

/// 当前账本 id（null = 用第一个账本兜底）
final activeBookIdProvider = StateProvider<int?>((ref) => null);

final booksProvider = FutureProvider<List<Book>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  ref.watch(revisionProvider);
  return store.books();
});

/// 当前账本
final activeBookProvider = FutureProvider<Book>((ref) async {
  final books = await ref.watch(booksProvider.future);
  final id = ref.watch(activeBookIdProvider);
  for (final b in books) {
    if (b.id == id) return b;
  }
  return books.first;
});

/// 当前浏览月份（当月 1 号）
final monthProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month);
});

/// 把浏览月份归位到当月。
///
/// 2026-10-26 起首页**只看本月**（顶栏删掉了月份条和收支条，没有切月的出口了），
/// 但 monthProvider 是全局的：日历页翻到 9 月、预算页改成 9 月之后，
/// 回首页就会看到 9 月而且退不回来。所有「会离开首页的月份写入点」
/// 都要在返回时调一次这个，别各自 copy 一份 DateTime.now() 拼。
void resetMonthToNow(WidgetRef ref) {
  final now = DateTime.now();
  ref.read(monthProvider.notifier).state = DateTime(now.year, now.month);
}


// ---------------------------------------------------------------- 基础数据

/// 可用账户（不含归档）。**跨账本**：记账时能看到所有账本共用的账户。
final pocketsProvider = FutureProvider<List<Pocket>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  ref.watch(revisionProvider);
  return store.allPockets(includeArchived: false);
});

/// 含归档账户（改旧流水/账户详情时要能认出归档账户）。同样跨账本。
final allPocketsProvider = FutureProvider<List<Pocket>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  ref.watch(revisionProvider);
  return store.allPockets(includeArchived: true);
});

/// 全部分类（含归档，收入 + 支出）。
///
/// 列表行必须用它：归档 ≠ 删除，历史流水仍要显示原来的分类名。
/// 只查未归档的话，一归档，**所有历史流水都会变成「未分类」**。
/// 账户那边早就用的是 allPocketsProvider，分类这侧要对齐。
final allBucketsProvider = FutureProvider<List<Bucket>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  final out = await store.buckets(book.id, 'out', includeArchived: true);
  final inn = await store.buckets(book.id, 'in', includeArchived: true);
  return [...out, ...inn];
});

/// 已归档的分类（分类管理页用）。
///
/// 归档原本是**单向**操作：列表默认 excludeArchived，一归档就从界面上消失，
/// 而全项目没有任何 `archiveBucket(id, false)` 调用 —— 用户点一下就再也回不来。
/// 这里专门给一个出口。
final archivedBucketsProvider =
    FutureProvider.family<List<Bucket>, String>((ref, flow) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  final all = await store.buckets(book.id, flow, includeArchived: true);
  return [for (final b in all) if (b.archived) b];
});

final bucketsProvider =
    FutureProvider.family<List<Bucket>, String>((ref, flow) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.buckets(book.id, flow);
});

final ratesProvider = FutureProvider<Map<String, double>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.rates(book.id);
});

/// 各账户余额（本币种分）
/// 各账户余额（原币种分）。**跨账本汇总**，所以这里不再需要账本。
final balancesProvider =
    FutureProvider<List<({Pocket pocket, int balanceCents})>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  ref.watch(revisionProvider);
  return store.pocketBalances();
});

/// 待报复合计（折算成账本主币的分）。
///
/// 资产页要把这一层单独列出来：它**不是账户余额**，却实实在在是应收，
/// 漏掉就会让「净资产」低估。这和 一木记账 的「报销资产」是同一个心智。
///
/// 币种按每一笔账单所属账户折算，不能直接用账本主币算 —— 报销常常是
/// 出差刷的外币卡。
final pendingReimburseProvider = FutureProvider<int>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  final rates = await ref.watch(ratesProvider.future);
  final pockets = await ref.watch(allPocketsProvider.future);
  final entries = await store.reimburseEntries(book.id, reimburse: 1);
  final byId = {for (final p in pockets) p.id: p};
  var sum = 0;
  for (final e in entries) {
    // 同上：报销常常是出差刷的外币卡，且那一笔还可能单独选过币种
    final code = e.currency ?? byId[e.pocketId]?.currency ?? book.baseCurrency;
    sum += toBaseCents(e.amountCents, code, book.baseCurrency, rates);
  }
  return sum;
});

// ---------------------------------------------------------------- 月度
final entriesProvider = FutureProvider<List<Entry>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final month = ref.watch(monthProvider);
  ref.watch(revisionProvider);
  return store.entriesOfMonth(book.id, month);
});

/// 「我的」页用：累计笔数 + 最早记账日（算坚持天数）。
final profileStatsProvider =
    FutureProvider<({int count, DateTime? earliest})>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final stats = await store.entryStats(book.id);
  // 用 store 的 parseDay：原来这里 split('-') 后 int.parse，
  // 一旦 day 带时间部分（外部导入）就抛 RangeError，
  // 整个 provider 失败 →「我的」页静默显示 0 天 / 0 笔。
  final earliest =
      stats.earliestDay == null ? null : LedgerStore.parseDay(stats.earliestDay!);
  return (count: stats.count, earliest: earliest);
});

/// 月收支（主币种分）。跨币种必须逐笔折算再求和——SQL 里直接 SUM 会把
/// 美元分和人民币分加在一起，这是算错账，不能图省事。
final totalsProvider =
    FutureProvider<({int incomeCents, int expenseCents})>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final month = ref.watch(monthProvider);
  ref.watch(revisionProvider);
  final entries = await store.entriesOfMonth(book.id, month);
  final pocketList = await store.allPockets();
  final currencyOf = {for (final p in pocketList) p.id: p.currency};
  var income = 0;
  var expense = 0;
  for (final e in entries) {
    if (e.flow != 'in' && e.flow != 'out') continue;
    // 「不计入收支」的笔不进合计（余额照算，只是不参与统计）
    if (e.excludeFromStats) continue;
    final from = e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency;
    final base = toBaseCents(e.amountCents, from, book.baseCurrency, rates);
    if (e.flow == 'in') {
      income += base;
    } else {
      expense += base;
    }
  }
  return (incomeCents: income, expenseCents: expense);
});

// slicesProvider 已删除（2026-10-27）：它是早期「首页分类占比」用的，
// 后来统计页的 insightSlicesProvider 接管了同一件事（支持周/年/自定义区间），
// 这个就再没人 watch 了 —— 留着只会误导下一个改这里的人。
// bucketSlices / rankSlices 仍然活着（insightSlicesProvider 在用），别一起删。

/// 每日收支（主币种分），key 是 dayKey '2026-10-21'。
///
/// 收入与支出分开累计，日历可以同时展示；转账和「不计入统计」的流水不参与。
final dailyTotalsProvider = FutureProvider<
    Map<String, ({int incomeCents, int expenseCents})>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final month = ref.watch(monthProvider);
  ref.watch(revisionProvider);
  final entries = await store.entriesOfMonth(book.id, month);
  final pocketList = await store.allPockets();
  final currencyOf = {for (final p in pocketList) p.id: p.currency};
  final map = <String, ({int incomeCents, int expenseCents})>{};
  for (final e in entries) {
    if (e.flow != 'in' && e.flow != 'out') continue;
    if (e.excludeFromStats) continue;
    // ⚠️ 必须带上 e.currency：本笔可以单独选币种。
    // 漏了它，首页「本月支出」是折算后的，日历格子却是裸数字，同一屏两个口径。
    final from = e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency;
    final base = toBaseCents(e.amountCents, from, book.baseCurrency, rates);
    final key = dayKey(e.day);
    final current = map[key] ?? (incomeCents: 0, expenseCents: 0);
    map[key] = e.flow == 'in'
        ? (
            incomeCents: current.incomeCents + base,
            expenseCents: current.expenseCents,
          )
        : (
            incomeCents: current.incomeCents,
            expenseCents: current.expenseCents + base,
          );
  }
  return map;
});

// ---------------------------------------------------------------- 预算

final budgetProvider = FutureProvider<int>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final month = ref.watch(monthProvider);
  ref.watch(revisionProvider);
  return store.budgetOf(book.id, month);
});

/// 上期预算结转到本期的金额（分，可为负）。
///
/// 只在上期**确实设过预算**时才结转（见 core/budget_rules.dart 的说明），
/// 免得用户上个月忘了设预算就凭空多一笔"超支"。
/// 某月「预算口径」支出（主币分）：逐笔折算 + 排除「不计入预算」。
///
/// 总预算原来吃的是 totalsProvider（只排 exclude_from_stats），
/// 而分类预算吃的是 exclude_from_budget —— 同一笔勾了「不计入预算」的支出，
/// 在总预算里算、在分类预算里不算，两个数字当场打架，用户的开关形同虚设。
/// [store]/[book] 由调用方传入：provider 里拿到的是 FutureProviderRef，
/// 不是 WidgetRef，硬传会类型不匹配。
Future<int> budgetSpentOf(LedgerStore store, Book book, DateTime month) async {
  final rates = await store.rates(book.id);
  final entries = await store.entriesOfMonth(book.id, month);
  final pocketList = await store.allPockets();
  final currencyOf = {for (final p in pocketList) p.id: p.currency};
  var spent = 0;
  for (final e in entries) {
    if (e.flow != 'out') continue;
    if (e.excludeFromBudget) continue;
    final from = e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency;
    spent += toBaseCents(e.amountCents, from, book.baseCurrency, rates);
  }
  return spent;
}

/// 本月预算口径支出
/// 已报销笔数（资产页入口卡用）
final reimburseDoneProvider = FutureProvider<int>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  final rows = await store.reimburseEntries(book.id, reimburse: 2);
  return rows.length;
});

final budgetSpentProvider = FutureProvider<int>((ref) async {
  ref.watch(revisionProvider);
  ref.watch(monthProvider);
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  return budgetSpentOf(store, book, ref.watch(monthProvider));
});

final budgetCarryProvider = FutureProvider<int>((ref) async {
  final settings = ref.watch(settingsProvider);
  if (!settings.budgetCarryEnabled) return 0;

  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final month = ref.watch(monthProvider);
  ref.watch(revisionProvider);

  // 「上期」按自然月算：预算本身是月键存储的，换周期起始日是另一件事，
  // 那条要连存储一起改，不在这一版里做。
  final prev = DateTime(month.year, month.month - 1, 1);
  final prevBudget = await store.budgetOf(book.id, prev);
  if (prevBudget <= 0) return 0;
  // 结转也必须按预算口径算：原来走 monthTotalsByFlow（SQL 裸 SUM），
  // 既不排除「不计入预算」，跨币种还会把美元分和人民币分加在一起。
  final prevSpent = await budgetSpentOf(store, book, prev);

  return budgetCarryCents(
    prevBudget: prevBudget,
    prevSpent: prevSpent,
    addUnused: settings.budgetCarryUnused,
    deductOver: settings.budgetDeductOver,
  );
});

/// 本期**实际可用**预算 = 基础预算 + 结转（不低于 0）。
///
/// 所有"还能花多少"的地方都该读这个，而不是 [budgetProvider]。
final effectiveBudgetProvider = FutureProvider<int>((ref) async {
  final base = await ref.watch(budgetProvider.future);
  if (base <= 0) return 0;
  final carry = await ref.watch(budgetCarryProvider.future);
  return effectiveBudgetCents(base: base, carry: carry);
});

// ---------------------------------------------------------------- 分类预算

/// 当月各分类预算：bucketId → 主币种分
final bucketBudgetsProvider = FutureProvider<Map<int, int>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final month = ref.watch(monthProvider);
  ref.watch(revisionProvider);
  return store.bucketBudgets(book.id, month);
});

/// 当月各分类已花（主币种分）：bucketId（null → 未分类用 0 占位不参与）
final bucketSpentProvider = FutureProvider<Map<int?, int>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final month = ref.watch(monthProvider);
  ref.watch(revisionProvider);
  final raw = await store.bucketSpent(book.id, month);
  final map = <int?, int>{};
  for (final r in raw) {
    map[r.bucketId] = (map[r.bucketId] ?? 0) +
        toBaseCents(r.cents, r.currency, book.baseCurrency, rates);
  }
  // 二级分类的支出必须并进父分类：给「餐饮」设了 1000 预算，
  // 结果钱都记在子分类「外卖」上，父分类显示已花 0 —— 预算等于失效。
  final tree = await ref.watch(bucketsProvider('out').future);
  final parentOf = <int, int?>{for (final b in tree) b.id: b.parentId};
  for (final entry in List.of(map.entries)) {
    final parentId = parentOf[entry.key];
    if (parentId == null) continue;
    map[parentId] = (map[parentId] ?? 0) + entry.value;
  }
  return map;
});

/// 本月各标签支出（主币种分），按金额降序。
///
/// 注意：一笔账单有多个标签时会**在每个标签下各计一次**，所以各项相加
/// 可能大于当月总支出。统计页必须写清楚，否则用户会以为算错了。
final tagTotalsProvider =
    FutureProvider<List<({String tag, int cents})>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final month = ref.watch(monthProvider);
  ref.watch(revisionProvider);
  final raw = await store.tagSpent(book.id, month);
  final acc = <String, int>{};
  for (final r in raw) {
    acc[r.tag] = (acc[r.tag] ?? 0) +
        toBaseCents(r.cents, r.currency, book.baseCurrency, rates);
  }
  final list = [
    for (final e in acc.entries) (tag: e.key, cents: e.value),
  ]..sort((a, b) => b.cents.compareTo(a.cents));
  return list;
});

/// 本月各账户支出（主币种分），按金额降序
final pocketTotalsProvider =
    FutureProvider<List<({Pocket pocket, int cents})>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final month = ref.watch(monthProvider);
  ref.watch(revisionProvider);
  final raw = await store.pocketSpent(book.id, month);
  final pockets = await ref.watch(allPocketsProvider.future);
  final byId = {for (final p in pockets) p.id: p};
  final acc = <int, int>{};
  for (final r in raw) {
    acc[r.pocketId] = (acc[r.pocketId] ?? 0) +
        toBaseCents(r.cents, r.currency, book.baseCurrency, rates);
  }
  final list = <({Pocket pocket, int cents})>[];
  for (final e in acc.entries) {
    final p = byId[e.key];
    if (p == null) continue; // 账户被删了但账单还在，跳过而不是崩
    list.add((pocket: p, cents: e.value));
  }
  list.sort((a, b) => b.cents.compareTo(a.cents));
  return list;
});

// ---------------------------------------------------------------- 多月序列

/// 近 N 个月（含当月）的收支，主币种分，按时间正序。
class MonthPoint {
  const MonthPoint(
      {required this.month,
      required this.incomeCents,
      required this.expenseCents});
  final DateTime month;
  final int incomeCents;
  final int expenseCents;
  int get netCents => incomeCents - expenseCents;
}

final monthSeriesProvider =
    FutureProvider.family<List<MonthPoint>, int>((ref, count) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final anchorMonth = ref.watch(monthProvider);
  ref.watch(revisionProvider);

  final pockets = await store.allPockets();
  final currencyOf = {for (final p in pockets) p.id: p.currency};

  final points = <MonthPoint>[];
  for (var i = count - 1; i >= 0; i--) {
    final month = DateTime(anchorMonth.year, anchorMonth.month - i);
    final entries = await store.entriesOfMonth(book.id, month);
    var income = 0;
    var expense = 0;
    for (final e in entries) {
      if (e.flow != 'in' && e.flow != 'out') continue;
      if (e.excludeFromStats) continue;
      final base = toBaseCents(
          e.amountCents,
          e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency,
          book.baseCurrency,
          rates);
      if (e.flow == 'in') {
        income += base;
      } else {
        expense += base;
      }
    }
    points.add(
        MonthPoint(month: month, incomeCents: income, expenseCents: expense));
  }
  return points;
});

// ---------------------------------------------------------------- 洞察 / 维护

/// 最近 90 天流水（预测、热力、情绪用）
final recentEntriesProvider = FutureProvider<List<Entry>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.entriesRecent(book.id, days: 90);
});

/// 最近 180 天流水（订阅识别要多看几个月）
final halfYearEntriesProvider = FutureProvider<List<Entry>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.entriesRecent(book.id, days: 180);
});

/// 回收站里的流水（软删除的）。供回收站页面展示、恢复、永久删除。
final recycleBinProvider = FutureProvider<List<Entry>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.recycleBinEntries(book.id);
});

final tableCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  ref.watch(revisionProvider);
  return store.tableCounts();
});

final databaseBytesProvider = FutureProvider<int>((ref) async {
  final store = await ref.watch(storeProvider.future);
  ref.watch(revisionProvider);
  return store.databaseBytes();
});

final orphanStatsProvider =
    FutureProvider<({int badPocket, int badBucket})>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.orphanStats(book.id);
});

/// 借贷 / 愿望

final debtsProvider = FutureProvider<List<Debt>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.debts(book.id);
});

/// 已结清的借贷（单独一栏看历史）
final closedDebtsProvider = FutureProvider<List<Debt>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  final all = await store.debts(book.id, includeClosed: true);
  return all.where((d) => d.closed).toList();
});

final debtPaidProvider = FutureProvider<Map<int, int>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.debtPaidMap(book.id);
});

final wishesProvider = FutureProvider<List<Wish>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.wishes(book.id);
});

// ---------------------------------------------------------------- 标签

final tagStatsProvider =
    FutureProvider<List<({String tag, int count})>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.tagStats(book.id);
});

final tagEntriesProvider =
    FutureProvider.family<List<Entry>, String>((ref, tag) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.entriesOfTag(book.id, tag);
});

// ---------------------------------------------------------------- 分类走势

/// 某分类自身 + 它的直接子分类 id。
///
/// 父分类的「合计、走势、流水」都必须含子分类——不然排行榜里「餐饮」
/// 显示 1300，点进去只看到 1000（外卖的 300 没算），两个数打架。
List<int> bucketFamilyIds(List<Bucket> all, int id) => [
      id,
      for (final b in all)
        if (b.parentId == id) b.id,
    ];

final categoryMonthlyProvider = FutureProvider.family<
    List<({String month, int cents})>,
    ({int id, String flow})>((ref, key) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  ref.watch(revisionProvider);
  final tree = await ref.watch(bucketsProvider(key.flow).future);
  // 走势跟着用户选中的月份走，不是永远看最近 6 个月
  final anchor = ref.watch(monthProvider);
  final raw = await store.bucketMonthly(
    book.id,
    bucketFamilyIds(tree, key.id),
    flow: key.flow,
    anchor: anchor,
  );
  final merged = <String, int>{};
  for (final r in raw) {
    merged[r.month] = (merged[r.month] ?? 0) +
        toBaseCents(r.cents, r.currency, book.baseCurrency, rates);
  }
  final keys = merged.keys.toList()..sort();
  return [for (final k in keys) (month: k, cents: merged[k]!)];
});

// ---------------------------------------------------------------- 净资产走势

/// 近 N 个月月末净资产（主币种分），外币按汇率折算，负债记负
final netWorthSeriesProvider =
    FutureProvider.family<List<({DateTime month, int netCents})>, int>(
        (ref, months) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  ref.watch(revisionProvider);
  final rows = await store.monthEndBalances(months: months);
  final sum = <DateTime, int>{};
  for (final r in rows) {
    final cents = toBaseCents(
            r.balanceCents.abs(), r.currency, book.baseCurrency, rates) *
        (r.balanceCents < 0 ? -1 : 1);
    sum[r.month] = (sum[r.month] ?? 0) + cents;
  }
  final keys = sum.keys.toList()..sort();
  return [for (final k in keys) (month: k, netCents: sum[k]!)];
});

/// 一根月 K。字段顺序固定：开 / 高 / 低 / 收。
typedef NetWorthCandle = ({
  DateTime month,
  int openCents,
  int highCents,
  int lowCents,
  int closeCents,
});

/// 把逐日净值按月切成 K 线。
///
/// 单独拎出来是为了能单测：开/高/低/收 只要错一根，图上就是一根假 K，
/// 但页面看上去仍然「正常」，靠肉眼发现不了。
List<NetWorthCandle> monthlyCandles(
  List<({DateTime day, int netCents})> daily, {
  /// 区间开始之前的净值：当月第一笔流水发生前的值，也就是「开盘价」。
  int baselineCents = 0,
}) {
  final out = <NetWorthCandle>[];
  DateTime? month;
  var open = baselineCents, high = baselineCents, low = baselineCents;
  var close = baselineCents;

  void flush() {
    final m = month;
    if (m == null) return;
    out.add((
      month: m,
      openCents: open,
      highCents: high,
      lowCents: low,
      closeCents: close,
    ));
  }

  for (final d in daily) {
    final key = DateTime(d.day.year, d.day.month);
    if (month == null || key != month) {
      flush();
      month = key;
      // 月开盘 = 上个月收盘；当月第一笔之前就是它
      open = close;
      high = low = close;
      if (d.netCents > high) high = d.netCents;
      if (d.netCents < low) low = d.netCents;
      close = d.netCents;
    } else {
      if (d.netCents > high) high = d.netCents;
      if (d.netCents < low) low = d.netCents;
      close = d.netCents;
    }
  }
  flush();
  return out;
}

/// 近 N 个月的**净资产蜡烛线**（开/高/低/收，主币种分）。
///
/// 数据来源是 [LedgerStore.netWorthDaily] 的逐日净值 —— 光有月末余额只能
/// 得到「收」，影线的高低点只能编；有了日线才能按月切出真实的最高/最低。
///
/// 口径：本月第一天的净值 = 开盘，本月最后一天的净值 = 收盘，
/// 期间所有日净值（含被流水改变的当天）的最值 = 影线端点。
final netWorthCandlesProvider =
    FutureProvider.family<List<NetWorthCandle>, int>((ref, months) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  ref.watch(revisionProvider);

  final now = DateTime.now();
  final from = DateTime(now.year, now.month - (months - 1), 1);
  final series = await store.netWorthDaily(
    from: from,
    toBase: (cents, currency) =>
        toBaseCents(cents, currency, book.baseCurrency, rates),
  );
  return monthlyCandles(series.days, baselineCents: series.baselineCents);
});

// ---------------------------------------------------------------- 目标 / 周期

final goalsProvider = FutureProvider<List<Goal>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.goals(book.id);
});

final recurringsProvider = FutureProvider<List<Recurring>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.recurrings(book.id);
});

/// 待报销笔数（「我的」页角标用）
final pendingReimburseCountProvider = FutureProvider<int>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return (await store.reimburseEntries(book.id, reimburse: 1)).length;
});

/// 已被退款的原支出 id。反向查询只跑一次，30 行共享同一份缓存。
final refundedSourceIdsProvider = FutureProvider<Set<int>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.refundedSourceIds(book.id);
});

/// 每笔流水挂了几张附件（列表里显示 📎）
final attachmentCountsProvider = FutureProvider<Map<int, int>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.attachmentCounts(book.id);
});

/// 常用备注（备注历史），复刻原版备注框左侧的时钟图标
final frequentMemosProvider = FutureProvider<List<String>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  return store.frequentMemos(book.id);
});

// ---------------------------------------------------------------- 洞察（可切换）

/// 洞察页统计范围：本月 / 本年 / 全部 / 自定义
/// 统计口径的周期粒度。顺序 == UI 分段控件的顺序（周 / 月 / 年 / 全部 / 范围）。
///
/// 2026-10-26 用户要求把统计页头部改成「周/月/年/全部/范围」五段 + 一行日期，
/// 原来只有 month/year/all/custom 四档，缺 week。
enum InsightScope { week, month, year, all, custom }

/// 统计页的**区间锚点**（带日，因为「周」需要知道是哪个星期）。
///
/// 为什么不复用 `monthProvider`：那是首页/预算页的「当前月份」，
/// 统计页翻到 2025 年 3 月不该把预算卡（本月预算）和首页一起带跑。
/// 分开之后，统计页怎么翻都不影响别处 —— 预算卡永远是本月。
final insightAnchorProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
});

/// 洞察页统计口径：支出 / 收入 / 结余
enum InsightType { expense, income, balance }

final insightScopeProvider =
    StateProvider<InsightScope>((ref) => InsightScope.month);

/// 自定义范围的起止（含两端）。null = 用户还没选过。
///
/// 用记录类型而不是 Material 的 `DateTimeRange`：这一层是状态层，
/// 不该为了一个结构体把 flutter/material 拉进来。
final insightCustomRangeProvider =
    StateProvider<({DateTime from, DateTime to})?>((ref) => null);

final insightTypeProvider =
    StateProvider<InsightType>((ref) => InsightType.expense);

/// [day] 所在的自然周（周一 ~ 周日，国内习惯）。
///
/// ⚠️ 先把 [day] 归一化到当天零点再减：anchor 若带时分秒（用户从"现在"进来的），
/// 减出来的 from 会带着同样的时分秒，UI 拼日期时容易显示成前一天。
({DateTime from, DateTime to}) weekRangeOf(DateTime day) {
  final d = DateTime(day.year, day.month, day.day);
  final from = d.subtract(Duration(days: d.weekday - 1));
  return (from: from, to: from.add(const Duration(days: 6)));
}

/// 把范围翻译成起止日期。all 用一个足够宽的空间区间兜底。
///
/// [custom] 只在 `scope == InsightScope.custom` 时生效；为 null（用户还没选）
/// 时回退到本月——绝不能返回一个无效区间，否则统计会静默变空。
({DateTime from, DateTime to}) insightRange(
    InsightScope scope, DateTime anchor,
    {({DateTime from, DateTime to})? custom}) {
  return switch (scope) {
    InsightScope.week => weekRangeOf(anchor),
    InsightScope.month => (
        from: DateTime(anchor.year, anchor.month),
        to: DateTime(anchor.year, anchor.month + 1, 0),
      ),
    InsightScope.year => (
        from: DateTime(anchor.year, 1, 1),
        to: DateTime(anchor.year, 12, 31),
      ),
    InsightScope.all => (
        // 放得足够宽：原来 2000~2100，导入一张日期打错的账单
        // （2101-01-05）或更早的老账，在「全部」里会静默消失，
        // 而明细页还能看到 —— 两个页面对不上。
        from: DateTime(1900, 1, 1),
        to: DateTime(2200, 12, 31),
      ),
    // 两端都含：entriesBetween 内部用 dayKey 做字符串比较，
    // 所以这里只要保留日期部分，不需要补到 23:59:59。
    InsightScope.custom => custom == null
        ? (
            from: DateTime(anchor.year, anchor.month),
            to: DateTime(anchor.year, anchor.month + 1, 0),
          )
        : (
            from: DateTime(custom.from.year, custom.from.month, custom.from.day),
            to: DateTime(custom.to.year, custom.to.month, custom.to.day),
          ),
  };
}

/// 洞察页收支合计（主币种分），随范围切换。
final insightTotalsProvider =
    FutureProvider<({int incomeCents, int expenseCents})>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final anchor = ref.watch(insightAnchorProvider);
  final scope = ref.watch(insightScopeProvider);
  ref.watch(revisionProvider);

  final r = insightRange(scope, anchor,
      custom: ref.watch(insightCustomRangeProvider));
  final entries = await store.entriesBetween(book.id, r.from, r.to);
  final pocketList = await store.allPockets();
  final currencyOf = {for (final p in pocketList) p.id: p.currency};
  var income = 0;
  var expense = 0;
  for (final e in entries) {
    if (e.flow != 'in' && e.flow != 'out') continue;
    if (e.excludeFromStats) continue;
    final from = e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency;
    final base = toBaseCents(e.amountCents, from, book.baseCurrency, rates);
    if (e.flow == 'in') {
      income += base;
    } else {
      expense += base;
    }
  }
  return (incomeCents: income, expenseCents: expense);
});

/// 洞察页分类排行（对齐原版 category_rank_row）：
/// 一级分类带着金额 + 占比，子分类也一起回，UI 里可展开。
final insightRankProvider = FutureProvider<List<RankNode>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final anchor = ref.watch(insightAnchorProvider);
  final scope = ref.watch(insightScopeProvider);
  final type = ref.watch(insightTypeProvider);
  ref.watch(revisionProvider);

  if (type == InsightType.balance) return const [];

  final r = insightRange(scope, anchor,
      custom: ref.watch(insightCustomRangeProvider));
  final raw = await store.bucketRank(
    book.id,
    flow: type == InsightType.income ? 'in' : 'out',
    from: r.from,
    to: r.to,
  );

  // 折算成主币种并按 bucket 合并
  final centsOf = <int?, int>{};
  final meta = <int?, ({String label, String glyph})>{};
  for (final row in raw) {
    final base = toBaseCents(row.cents, row.currency, book.baseCurrency, rates);
    centsOf[row.bucketId] = (centsOf[row.bucketId] ?? 0) + base;
    meta[row.bucketId] = (label: row.label, glyph: row.glyph);
  }

  // 分类层级
  final buckets = <Bucket>[
    ...?ref.watch(bucketsProvider('out')).valueOrNull,
    ...?ref.watch(bucketsProvider('in')).valueOrNull,
  ];
  final parentOf = <int, int?>{for (final b in buckets) b.id: b.parentId};

  final roots = <RankNode>[];
  final childrenOf = <int, List<RankNode>>{};
  for (final e in centsOf.entries) {
    if (e.value <= 0) continue;
    final id = e.key;
    final m = meta[id];
    final node = RankNode(
      bucketId: id,
      label: m?.label ?? (id == null ? '未分类' : '已删分类'),
      glyph: m?.glyph ?? '🧾',
      cents: e.value,
      children: const [],
    );
    final pid = id == null ? null : parentOf[id];
    if (pid != null) {
      childrenOf.putIfAbsent(pid, () => []).add(node);
    } else {
      roots.add(node);
    }
  }

  // 把子分类挂到父节点上；父分类自身没金额时也要补一条
  final result = <RankNode>[];
  for (final n in roots) {
    // ⚠️ 必须复制成**可增长**列表再排序。
    // 原来写的是 `childrenOf[...] ?? const <RankNode>[]`，没有子分类时拿到的是
    // const 空列表，紧跟的 .sort() 会抛
    //   "Unsupported operation: Cannot modify an unmodifiable list"
    // 而「父分类没有子分类」恰恰是最常见的情况 —— 空库测不出来，
    // 一旦有真实账单，分类排行整块就变成「排行读取失败」。
    final kids = <RankNode>[...?childrenOf[n.bucketId]];
    kids.sort((a, b) => b.cents.compareTo(a.cents));
    result.add(RankNode(
      bucketId: n.bucketId,
      label: n.label,
      glyph: n.glyph,
      cents: n.cents + kids.fold<int>(0, (s, k) => s + k.cents),
      children: kids,
    ));
  }
  // 父分类下只有子分类有金额的情况
  for (final pid in childrenOf.keys) {
    if (result.any((n) => n.bucketId == pid)) continue;
    final b = buckets.where((x) => x.id == pid).firstOrNull;
    final kids = childrenOf[pid]!..sort((a, b2) => b2.cents.compareTo(a.cents));
    result.add(RankNode(
      bucketId: pid,
      label: b?.title ?? '分类',
      glyph: b?.glyph ?? '🧾',
      cents: kids.fold<int>(0, (s, k) => s + k.cents),
      children: kids,
    ));
  }
  result.sort((a, b) => b.cents.compareTo(a.cents));
  return result;
});

/// 分类排行的一行（可带子分类）
class RankNode {
  const RankNode({
    required this.bucketId,
    required this.label,
    required this.glyph,
    required this.cents,
    required this.children,
  });

  final int? bucketId;
  final String label;
  final String glyph;

  /// 含子分类合计
  final int cents;
  final List<RankNode> children;

  bool get hasChildren => children.isNotEmpty;
}

/// 当前账本 + 当前月份的手写总结。空串 = 没写过。
final monthNoteProvider = FutureProvider<String>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  // 跟统计页的锚点走（_MonthNoteCard 传进来的就是 anchor）
  final anchor = ref.watch(insightAnchorProvider);
  ref.watch(revisionProvider);
  return store.monthNote(book.id, anchor);
});

/// 上月同期：分类 → 主币种分。
///
/// 「同期」不是「上月整月」：看本月时按**上月 1 号到上月同一日**取，
/// 否则 10 月 24 日拿 9 月整月比，永远是"这个月花得少"的错觉。
/// 看历史月份时取该月整月。
///
/// 只在 `scope == month` 下有意义，其他口径返回空表（UI 据此隐藏卡片）。
final insightPrevRankProvider = FutureProvider<Map<int?, int>>((ref) async {
  final scope = ref.watch(insightScopeProvider);
  if (scope != InsightScope.month) return const {};
  final type = ref.watch(insightTypeProvider);
  if (type == InsightType.balance) return const {};

  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final anchor = ref.watch(insightAnchorProvider);
  ref.watch(revisionProvider);

  final prev = DateTime(anchor.year, anchor.month - 1);
  final now = DateTime.now();
  final viewingCurrent = anchor.year == now.year && anchor.month == now.month;
  final prevLastDay = DateTime(prev.year, prev.month + 1, 0).day;
  final day = viewingCurrent ? now.day : prevLastDay;

  final raw = await store.bucketRank(
    book.id,
    flow: type == InsightType.income ? 'in' : 'out',
    from: DateTime(prev.year, prev.month, 1),
    to: DateTime(prev.year, prev.month, day.clamp(1, prevLastDay)),
  );

  final out = <int?, int>{};
  for (final r in raw) {
    final base = toBaseCents(r.cents, r.currency, book.baseCurrency, rates);
    out[r.bucketId] = (out[r.bucketId] ?? 0) + base;
  }
  return out;
});

/// 洞察页分类占比（主币种分），随范围与口径切换。
final insightSlicesProvider = FutureProvider<List<Slice>>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final anchor = ref.watch(insightAnchorProvider);
  final scope = ref.watch(insightScopeProvider);
  final type = ref.watch(insightTypeProvider);
  ref.watch(revisionProvider);

  // 结余口径没有「分类占比」可言，返回空让 UI 走净额展示。
  if (type == InsightType.balance) return const [];

  final r = insightRange(scope, anchor,
      custom: ref.watch(insightCustomRangeProvider));
  final raw = await store.bucketSlices(
    book.id,
    anchor,
    flow: type == InsightType.income ? 'in' : 'out',
    from: r.from,
    to: r.to,
  );
  final merged = <String, int>{};
  for (final s in raw) {
    merged[s.label] = (merged[s.label] ?? 0) +
        toBaseCents(s.cents, s.currency, book.baseCurrency, rates);
  }
  return rankSlices([
    for (final e in merged.entries) Slice(label: e.key, cents: e.value),
  ]);
});

// ---------------------------------------------------------------- 桑基图

/// 桑基图的一个节点：一个分类 + 折算成主币种的金额。
typedef SankeyFlow = ({String label, String glyph, int cents});

/// 桑基图数据：钱从哪来（收入分类）→ 到哪去（支出分类 + 结余）。
///
/// 为什么是「来源 → 水池 → 去向」三列，而不是来源×去向全连接：
/// 全连接要画 n×m 条带子，8 个收入分类 × 8 个支出分类就是 64 条，
/// 小屏上就是一坨毛线，谁也读不出比例。中间加一个水池节点既能保住
/// 「流入 = 流出」的守恒，又能一眼看出「进来多少、出去多少、剩多少」。
///
/// 口径与统计页其它卡完全一致：同范围、剔掉不计入收支的笔、外币按当前汇率折算。
final sankeyProvider = FutureProvider<
    ({
      List<SankeyFlow> sources,
      List<SankeyFlow> sinks,
      int income,
      int expense
    })>((ref) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  final rates = await ref.watch(ratesProvider.future);
  final anchor = ref.watch(insightAnchorProvider);
  final scope = ref.watch(insightScopeProvider);
  ref.watch(revisionProvider);

  final r = insightRange(scope, anchor,
      custom: ref.watch(insightCustomRangeProvider));

  Future<List<SankeyFlow>> side(String flow) async {
    final raw =
        await store.bucketRank(book.id, flow: flow, from: r.from, to: r.to);
    final cents = <int?, int>{};
    final meta = <int?, ({String label, String glyph})>{};
    for (final row in raw) {
      final base =
          toBaseCents(row.cents, row.currency, book.baseCurrency, rates);
      cents[row.bucketId] = (cents[row.bucketId] ?? 0) + base;
      meta[row.bucketId] = (label: row.label, glyph: row.glyph);
    }
    final list = <SankeyFlow>[
      for (final e in cents.entries)
        if (e.value > 0)
          (
            label: meta[e.key]?.label ?? '未分类',
            glyph: meta[e.key]?.glyph ?? '🧾',
            cents: e.value,
          ),
    ]..sort((a, b) => b.cents.compareTo(a.cents));
    return _mergeSankeyTail(list);
  }

  final sources = await side('in');
  final sinks = await side('out');
  final income = sources.fold<int>(0, (s, e) => s + e.cents);
  final expense = sinks.fold<int>(0, (s, e) => s + e.cents);

  if (income > expense) {
    sinks.add((label: '结余', glyph: '🐷', cents: income - expense));
  } else if (expense > income) {
    // 花得比赚得多：差额来自以前的存款（或借的钱）。
    // 不编造来源，就标「存款补足」——否则左边加起来对不上右边，图就是错的。
    sources.add((label: '存款补足', glyph: '🏦', cents: expense - income));
  }
  return (sources: sources, sinks: sinks, income: income, expense: expense);
});

/// 分类太多时把尾部合成「其他」：两边各挂 20 个节点，带子细得看不见。
List<SankeyFlow> _mergeSankeyTail(List<SankeyFlow> list, {int keep = 5}) {
  if (list.length <= keep + 1) return list;
  final head = list.take(keep).toList();
  final sum = list.skip(keep).fold<int>(0, (s, e) => s + e.cents);
  return [...head, (label: '其他', glyph: '📦', cents: sum)];
}
