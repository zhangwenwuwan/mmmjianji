import 'app_glyph.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/aggregate.dart';
import '../core/home_modules.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../services/app_log.dart';
import '../services/icon_service.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'book_manage_page.dart';
import 'report_page.dart';
import 'boot_reveal.dart';
import 'budget_page.dart';
import 'common.dart';
import 'daily_receipt_page.dart';
import 'editor_page.dart';
import 'wheel_date_picker.dart';
import 'export_page.dart';
import 'glass.dart';
import 'illustrations.dart';
import 'month_summary_page.dart';
import 'motion.dart';
import 'pull_to_add.dart';
import 'recycle_bin_page.dart';
import 'voice_fab.dart';
import 'search_page.dart';
import 'theme.dart';

/// 首页（流水列表）的滚动控制器：由 [LedgerPage] 建，由底栏「再点一次回顶部」消费。
///
/// 为什么是模块级变量而不是 provider：Riverpod **不允许在 initState/dispose 里
/// 修改别的 provider**（会抛 "Tried to modify a provider"），而控制器恰好要在
/// 这两个时机挂上/摘下。首页全 App 只有一个实例，用单点变量是安全的，
/// 消费方（底栏）每次都判 `hasClients`。
ScrollController? homeScrollController;

/// 账目：按月看流水，按日分组。
///
/// 顶栏两行（对齐参考版）：
/// 第一行 账本选择器 + 搜索；第二行 年月大字 + 下拉（点开年月选择）。
/// 列表内含收支合计、上月报告卡、预算引导卡，再按日分组。
class LedgerPage extends ConsumerStatefulWidget {
  const LedgerPage({super.key, this.onCalendar});

  /// 右上角「日历」图标（在搜索左边）：2026-10-25 起日历不再占底部 tab，
  /// 改从这里进。日历是「查历史某天」的高频动作，放首页右上角比塞进底栏更省位置。
  final VoidCallback? onCalendar;

  @override
  ConsumerState<LedgerPage> createState() => _LedgerPageState();
}

class _LedgerPageState extends ConsumerState<LedgerPage> {
  /// 批量选择模式：长按任意一条流水进入，点行切换勾选。
  bool _batch = false;
  final Set<int> _selected = <int>{};

  /// 首页滚动控制器：挂到 CustomScrollView 上，同时放进 [homeScrollProvider]，
  /// 让底栏「再点一次首页」能把它滚回顶部。
  ScrollController? _scroll;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
    homeScrollController = _scroll;
  }

  @override
  void dispose() {
    if (homeScrollController == _scroll) homeScrollController = null;
    _scroll?.dispose();
    _scroll = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(monthProvider);
    final entriesAsync = ref.watch(entriesProvider);
    final totalsAsync = ref.watch(totalsProvider);
    final bookAsync = ref.watch(activeBookProvider);
    // 用「本期可用」（含上月结转），否则顶部"还能花多少"会和预算页对不上
    final budget = ref.watch(effectiveBudgetProvider).valueOrNull ?? 0;
    // 本月预算口径已花（和预算页同口径），用于首页超支提示。
    final budgetSpent = ref.watch(budgetSpentProvider).valueOrNull ?? 0;
    final totals = totalsAsync.valueOrNull ?? (incomeCents: 0, expenseCents: 0);
    final settings = ref.watch(settingsProvider);
    final coverPath = settings.coverPath;
    // 批量选择要判断"是否已全选"，这里先算出当前可见流水（已排除"隐藏转账"的）
    final entriesNow = entriesAsync.valueOrNull ?? const <Entry>[];
    final visibleNow = _visibleEntries(entriesNow, settings.hideTransfers);

    // 首页只看本月（顶栏已经没有月份切换了）。
    //
    // monthProvider 是全局的：日历页翻到 9 月、预算页改成 9 月之后回到首页，
    // 会看到一个「没有出口的 9 月」。这里在首页**重新成为最上层路由**时归位。
    //
    // 为什么用 ModalRoute.isCurrent 而不是直接判 month != now：
    // 首页一直挂在 IndexedStack 里，日历/预算页推上来时它照样会 rebuild，
    // 不加这个判断的话，用户在日历页翻月，首页会在底下把月份抢回当月，
    // 日历页就会莫名其妙跳回今天。
    final routeCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    final nowMonth = DateTime(DateTime.now().year, DateTime.now().month);
    if (routeCurrent && month != nowMonth) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(monthProvider.notifier).state = nowMonth;
      });
    }

    // 日分组净额要逐笔折算成主币。LedgerPage 是 ConsumerWidget，
    // _buildGroups 是普通方法拿不到 ref，所以在这里把换算闭包传下去。
    final rates =
        ref.watch(ratesProvider).valueOrNull ?? const <String, double>{};
    final pocketsForRate =
        ref.watch(allPocketsProvider).valueOrNull ?? const <Pocket>[];
    final currencyOf = {for (final p in pocketsForRate) p.id: p.currency};
    final baseCurrency =
        ref.watch(activeBookProvider).valueOrNull?.baseCurrency ?? 'CNY';
    // 日期头「当日收支净额」和日历页 dailyTotalsProvider 是同一个统计口径，
    // 都必须扣掉 AA 他人承担部分，否则同一天在两处显示的支出对不上。
    // 注意：下面每条流水行仍显示 amountCents 全额（那是实际垫付的流水），
    // 差额靠行上的「AA 代付」标记解释。
    int toBaseOf(Entry e) => toBaseCents(
          e.statsCents,
          e.currency ?? currencyOf[e.pocketId] ?? baseCurrency,
          baseCurrency,
          rates,
        );

    // 折叠头部 + 列表都放在同一个 CustomScrollView 里（对齐原版 PrimaryHeader 的做法）
    //
    // 顶部下拉的手势给「记一笔」，不再做数据刷新：本地优先 App 的数据是
    // provider 响应式更新的，下拉刷新近似空操作；而「记一笔」是全 App 最高频的动作。
    // 读取失败的重试路径仍在（ErrorRetryView.onRetry → _refresh），没有丢。
    final Widget body = PullToAdd(
      onTrigger: () => openEntryEditor(context, ref),
      child: CustomScrollView(
        controller: _scroll,
        // 内容不够一屏时也要能下拉，否则短列表在顶部根本拉不动、触发不了记账
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _LedgerHeader(
              bookAsync: bookAsync,
              topPadding: MediaQuery.of(context).viewPadding.top,
              onSearch: () => _push(context, const SearchPage()),
              onCalendar: widget.onCalendar,
              coverPath: coverPath,
              coverLuminance: settings.coverLuminance,
            ),
          ),
          ...entriesAsync.when<List<Widget>>(
            // 下拉刷新 / 重算时保留旧列表，不闪骨架屏
            skipLoadingOnReload: true,
            loading: () => [
              // 骨架也占第 1 个序号：数据还没到时幕已经开了，
              // 让骨架自己浮上来，比"空一下突然出现"顺。
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    BootRevealItem(
                      index: 1,
                      // 圆角必须和真卡片一致（Panel = AppRadius.card = 8）。
                      // 原来是 16，加载完圆角一下收一半，看着像跳了一下。
                      child: const Skeleton(height: 64, radius: AppRadius.card),
                    ),
                    const SizedBox(height: 14),
                    // 流水骨架画成「一张卡 + 分隔线」。
                    // 真实流水是一整张 Panel 里的平铺行（只有外层 8 圆角），
                    // 之前每行都画成 radius 14 的独立药丸，加载完成的瞬间
                    // 六七个药丸"啪"地并成一张卡 —— 这一跳比数字刷新还显眼。
                    for (var g = 0; g < 2; g++) ...[
                      const Skeleton(height: 14, expand: true, radius: 7),
                      const SizedBox(height: 8),
                      Panel(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (var i = 0; i < 3; i++) ...[
                              if (i > 0)
                                const Divider(height: 1, indent: 56),
                              const Skeleton(height: 64, radius: 0),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                  ]),
                ),
              ),
            ],
            error: (e, _) => [
              SliverToBoxAdapter(
                child: ErrorRetryView(
                  message: '账目读取失败',
                  detail: '$e',
                  onRetry: () => _refresh(ref),
                ),
              ),
            ],
            data: (entries) => [
              // 冷启动时这几块按 [BootRevealItem] 的序号依次浮上来：
              // 顶栏 → 本月概览 → 各模块 → 流水。序号让 _stagger 排。
              SliverPadding(
                // 底部 88（给悬浮胶囊让位）不在这里，挪到流水之后 ——
                // 分组改成 sliver 之后它们不再共用同一个 SliverPadding。
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                    // 「本月概览」固定钉在最上面：不再参与模块顺序与显隐。
                    // 2026-10-26 用户要求「本月概览固定显示」——删掉顶栏那条
                    // 重复的收支三段后，这张卡就是首页唯一的数据概览，
                    // 允许它被拖到列表中间或被关掉都很荒唐。
                    BootRevealItem(
                      index: 1,
                      child: _HomeHeroCard(
                        expenseCents: totals.expenseCents,
                        incomeCents: totals.incomeCents,
                        budgetCents: budget,
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 首页模块的顺序和显隐由「首页模块」设置页决定，
                    // 清单见 core/home_modules.dart。
                    ..._stagger(
                      _homeModuleWidgets(
                        modules: settings.modulesVisible,
                        month: month,
                        totals: totals,
                        budget: budget,
                        spent: budgetSpent,
                      ),
                      2,
                    ),
                    if (visibleNow.isEmpty)
                      BootRevealItem(
                        index: 6,
                        // 空态后面要留底部空白（滚动区结束），否则最后一行贴着屏幕底边
                        // 开了「隐藏转账」且这个月只有转账时，不能说「还没有记录」
                        // （明明记了 3 笔，还引导他再去记一笔）。
                        child: entriesNow.isNotEmpty
                            ? _EmptyHome(
                                title: '这个月只有转账',
                                subtitle: '转账已在设置里隐藏，没别的流水可显示',
                                icon: Icons.swap_horiz_rounded,
                                onAction: () => openEntryEditor(context, ref),
                              )
                            : _EmptyHome(
                                onAction: () => openEntryEditor(context, ref),
                              ),
                      ),
                  ]),
                ),
              ),
              // 流水（分组自带日期吸顶头，所以是独立的 sliver，不再塞进上面的列表）
              if (visibleNow.isNotEmpty)
                ..._buildGroups(context, visibleNow, toBaseOf),
              // 底部留白给悬浮胶囊 + 右下角语音按钮让位：滚到底时最后一笔
              // 流水要能完整露出来，不能被这两层压住还滚不出去。
              SliverToBoxAdapter(
                  child: SizedBox(height: voiceFabClearance(context))),
            ],
          ),
        ],
      ),
    );
    // 首页是 tab body，拿不到 Scaffold 的 bottomNavigationBar / FAB 插槽，
    // 所以批量条和语音悬浮按钮都用 Stack 叠一层，也不会让列表被挤压重排。
    return Stack(
      children: [
        Positioned.fill(child: body),
        if (_batch)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: _BatchBar(
              count: _selected.length,
              allSelected: visibleNow.isNotEmpty &&
                  _selected.length == visibleNow.length,
              onSelectAll: () => _selectAll(visibleNow),
              onBucket: _batchChangeBucket,
              onDay: _batchChangeDay,
              onDelete: _batchDelete,
              onCancel: _exitBatch,
            ),
          ),
        // 右下角独立的语音记账悬浮按钮。批量操作时收起，避免和批量条抢位置。
        // 用带约束的 Positioned（而非 fill + Align），按钮以外的地方不吃手势。
        if (!_batch)
          Positioned(
            right: 14,
            bottom: voiceFabBottom(context),
            // 和底栏同为第 0 块：冷启动时一起从下方浮上来。
            child: const BootRevealItem(
              index: 0,
              y: 22,
              child: VoiceFab(),
            ),
          ),
      ],
    );
  }

  /// 给一组块编上连续的出场序号（冷启动时依次浮上来）。
  ///
  /// 只在启动那一次有效：时间线失效后 [BootRevealItem] 自己会直接显示，
  /// 这里不用判断时机。
  List<Widget> _stagger(List<Widget> blocks, int from) => [
        for (var i = 0; i < blocks.length; i++)
          BootRevealItem(index: from + i, child: blocks[i]),
      ];

  // ---------------------------------------------------------------- 批量选择

  void _toggleEntry(Entry e) {
    setState(() {
      _batch = true;
      if (!_selected.add(e.id)) _selected.remove(e.id);
    });
  }

  void _exitBatch() => setState(() {
        _batch = false;
        _selected.clear();
      });

  void _selectAll(Iterable<Entry> entries) => setState(() {
        if (_selected.length == entries.length) {
          _selected.clear();
        } else {
          _selected
            ..clear()
            ..addAll(entries.map((e) => e.id));
        }
      });

  /// 批量改分类。
  ///
  /// 转账没有分类概念，必须跳过——同 search_page 的处理：硬把 bucket_id 写到
  /// 转账行上会留下脏数据，之后按分类统计就出鬼账。
  Future<void> _batchChangeBucket() async {
    final buckets = ref.read(bucketsProvider('out')).valueOrNull ?? const [];
    final picked = await showAppSheet<int>(
      context: context,
      title: '改到哪个分类',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.clear, size: 18),
            title: const Text('设为未分类'),
            onTap: () => Navigator.pop(ctx, 0),
          ),
          const Divider(height: 1),
          for (final b in buckets)
            ListTile(
              dense: true,
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppGlyph(b.glyph, size: 16),
                  const SizedBox(width: 6),
                  Flexible(
                      child: Text(b.title, overflow: TextOverflow.ellipsis)),
                ],
              ),
              onTap: () => Navigator.pop(ctx, b.id),
            ),
        ],
      ),
    );
    if (picked == null) return;

    final entries = ref.read(entriesProvider).valueOrNull ?? const <Entry>[];
    final transferIds = entries
        .where((e) => _selected.contains(e.id) && e.isTransfer)
        .map((e) => e.id)
        .toSet();
    final targets =
        _selected.where((id) => !transferIds.contains(id)).toList();
    if (targets.isEmpty) {
      _toast('选中的都是转账，转账没有分类');
      return;
    }
    final store = await ref.read(storeProvider.future);
    final count = await store.updateEntriesBucket(
        targets, picked == 0 ? null : picked);
    bumpRevision(ref);
    if (!mounted) return;
    _exitBatch();
    _toast(transferIds.isEmpty
        ? '已修改 $count 条'
        : '已修改 $count 条，跳过 ${transferIds.length} 条转账');
  }

  /// 批量改日期（整理补记最常用）。
  Future<void> _batchChangeDay() async {
    final now = DateTime.now();
    final picked = await pickDateWheel(
      context,
      now,
      includeDay: true,
      title: '改到哪一天',
    );
    if (picked == null) return;
    final store = await ref.read(storeProvider.future);
    final count = await store.updateEntriesDay(_selected.toList(), picked);
    bumpRevision(ref);
    if (!mounted) return;
    _exitBatch();
    _toast('已把 $count 条改到 ${picked.month} 月 ${picked.day} 日');
  }

  Future<void> _batchDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除选中的 ${_selected.length} 条？'),
        content: const Text('会移入回收站，可随时恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('删除', style: TextStyle(color: Palette.expense))),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(storeProvider.future);
    final count = await store.deleteEntries(_selected.toList());
    bumpRevision(ref);
    if (!mounted) return;
    _exitBatch();
    _showRecycledHint(count);
  }

  /// 批量删除后的提示：带「查看」，一键进回收站。
  /// 之前只有一句 2 秒 toast —— 删错了得走 我的 → 数据管理 → 回收站 三层才找得回。
  void _showRecycledHint(int count) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('已移入回收站 $count 条'),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: '查看',
          onPressed: () => Navigator.of(context)
              .push(AppPageRoute(page: const RecycleBinPage())),
        ),
      ));
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).toast(msg);
  }

  /// 按用户配置顺序生成首页卡片。
  ///
  /// 间距说明：除「记一笔」以外的卡片**自带下边距**
  /// （比如 SafeToSpend 内部就是 Padding(bottom: 14)），所以这里只给它
  /// 补显式 SizedBox —— 它原本就是靠相邻的 SizedBox 分隔的，
  /// 变成可拖拽顺序后不能再依赖"谁在谁后面"。
  ///
  /// 「本月概览」不在这里生成：它固定渲染在列表最前面（见 build）。
  List<Widget> _homeModuleWidgets({
    required List<HomeModule> modules,
    required DateTime month,
    required ({int incomeCents, int expenseCents}) totals,
    required int budget,
    required int spent,
  }) {
    final out = <Widget>[];
    for (final m in modules) {
      switch (m) {
        case HomeModule.hero:
          // 已固定在最前，见 build 里的 _HomeHeroCard
          break;
        case HomeModule.addEntry:
          out.add(_AddEntryButton());
          out.add(const SizedBox(height: 10));
        case HomeModule.safeToSpend:
          out.add(_SafeToSpendCard(budgetCents: budget, totals: totals));
        case HomeModule.budgetHint:
          out.add(_BudgetHintCard(budgetCents: budget, spentCents: spent));
        case HomeModule.backupHint:
          out.add(const _BackupHintCard());
        case HomeModule.lastMonth:
          out.add(_LastMonthCard(month: month));
        case HomeModule.annualReport:
          out.add(_AnnualReportCard(month: month));
      }
    }
    return out;
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(AppPageRoute(page: page));
  }

  /// 下拉刷新 / 失败重试：把相关 provider 全部失效重读。
  Future<void> _refresh(WidgetRef ref) async {
    ref.invalidate(entriesProvider);
    ref.invalidate(totalsProvider);
    ref.invalidate(dailyTotalsProvider);
    ref.invalidate(budgetProvider);
    ref.invalidate(budgetCarryProvider);
    ref.invalidate(effectiveBudgetProvider);
    ref.invalidate(balancesProvider);
    ref.invalidate(allBucketsProvider);
    ref.invalidate(goalsProvider);
    ref.invalidate(insightTotalsProvider);
    ref.invalidate(insightSlicesProvider);
    // 等一轮，让 RefreshIndicator 的转圈至少可见
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }

  /// 首页要展示的流水（「隐藏转账流水」生效时剔掉 transfer）。
  ///
  /// 提醒：这里**只影响展示**。合计、预算、统计都吃原始 entries，
  /// 所以隐藏转账不会让「本月支出」变小（转账本来就不计入收支）。
  List<Entry> _visibleEntries(List<Entry> entries, bool hideTransfers) =>
      hideTransfers
          ? [
              for (final e in entries)
                if (e.flow != 'transfer') e
            ]
          : entries;

  /// 按日分组的流水。返回的是 **sliver**（不是普通 widget）：
  /// 日期头是 `SliverPersistentHeader(pinned: true)`，滚到月中时它停在顶栏下面，
  /// 否则屏幕上没有任何地方告诉你现在看的是几号。
  List<Widget> _buildGroups(
      BuildContext context, List<Entry> entries, int Function(Entry) toBase) {
    final groups = <String, List<Entry>>{};
    for (final e in entries) {
      groups.putIfAbsent(dayKey(e.day), () => []).add(e);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final widgets = <Widget>[];
    for (var gi = 0; gi < keys.length; gi++) {
      final key = keys[gi];
      final list = groups[key]!;
      // 时间轴按时间倒序（晚 → 早），最近的一笔在最上面。
      // 没记时分的老账排在最后，彼此按 id 倒序。
      list.sort((a, b) {
        final ta = a.timeMinutes;
        final tb = b.timeMinutes;
        if (ta == null && tb == null) return b.id.compareTo(a.id);
        if (ta == null) return 1;
        if (tb == null) return -1;
        final c = tb.compareTo(ta);
        return c != 0 ? c : b.id.compareTo(a.id);
      });
      final day = list.first.day;
      // 转账不算收支，「不计入收支」的笔也不算
      final net = list.fold<int>(0, (sum, e) {
        if (e.isTransfer || e.excludeFromStats) return sum;
        final cents = toBase(e);
        return sum + (e.flow == 'in' ? cents : -cents);
      });
      final delay = Duration(milliseconds: (40 * gi).clamp(0, 240));
      // 日期头吸顶（pinned）。多个 pinned header 会依次堆叠，
      // 所以它停在首页顶栏（_LedgerHeader）的正下方，不会盖住它。
      widgets.add(SliverPersistentHeader(
        pinned: true,
        delegate: _DayHeaderDelegate(
          day: day,
          net: net,
          onReceipt: () => Navigator.of(context).push(
            AppPageRoute(page: DailyReceiptPage(day: day)),
          ),
        ),
      ));
      widgets.add(SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
        sliver: SliverToBoxAdapter(
          child: Reveal(
            delay: delay,
            child: Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < list.length; i++) ...[
                    // 时间轴不需要横向分隔线：竖线本身就是分隔。
                    if (i > 0) const SizedBox.shrink(),
                    // 非批量模式：左滑直接删除（记错一笔金额是最高频的纠错）。
                    // 以前要走「点行 → 编辑页 → 点删除 → 确认」四步。
                    // 批量模式不套 Dismissible：那会儿点行是勾选，横向拖动会和它打架。
                    if (_batch)
                      EntryRow(
                        key: ValueKey('entry-${list[i].id}'),
                        entry: list[i],
                        // 非 null = 显示勾选框
                        selected: _selected.contains(list[i].id),
                        onLongPress: () => _toggleEntry(list[i]),
                        onTap: () => _toggleEntry(list[i]),
                        timeline: true,
                        isFirst: i == 0,
                        isLast: i == list.length - 1,
                      )
                    else
                      Dismissible(
                        key: ValueKey('swipe-${list[i].id}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 18),
                          color: Palette.expense.withValues(alpha: 0.10),
                          child: Icon(Icons.delete_outline,
                              size: 18, color: Palette.expense),
                        ),
                        confirmDismiss: (_) =>
                            _swipeDelete(context, list[i].id),
                        onDismissed: (_) {},
                        child: EntryRow(
                          key: ValueKey('entry-${list[i].id}'),
                          entry: list[i],
                          onLongPress: () => _toggleEntry(list[i]),
                          timeline: true,
                          isFirst: i == 0,
                          isLast: i == list.length - 1,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ));
      widgets.add(const SliverToBoxAdapter(child: SizedBox(height: 8)));
    }
    return widgets;
  }

  /// 左滑删除：软删除 + 5 秒可撤销（和编辑页删除同一条路径、同一套文案）。
  ///
  /// 返回 true 才真正把这一行滑走。删除失败时返回 false，行会弹回来，
  /// 不会出现"行没了但数据还在"的幻觉。
  Future<bool> _swipeDelete(BuildContext context, int entryId) async {
    try {
      final store = await ref.read(storeProvider.future);
      await store.softDeleteEntries([entryId]);
      bumpRevision(ref);
      if (context.mounted) _offerUndoDelete(context, ref, entryId);
      return true;
    } catch (e) {
      AppLog.error('ledger', '左滑删除失败', e);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .toast('删除失败，详情见「我的 → 数据管理 → 日志中心」');
      }
      return false;
    }
  }

  static String _weekday(DateTime d) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][d.weekday - 1];
}

/// 吸顶的日期头（「10 月 3 日 · 周五　-120」）。
///
/// 为什么必须钉住：首页顶栏 2026-10-26 起瘦成一行（账本 chip + 日历 + 搜索），
/// 年月条被删了，往下滚两屏之后屏幕上没有任何地方写着"现在看的是几号"。
///
/// ⚠️ 背景必须**不透明**：pinned header 是浮在内容上的，半透明会让流水从底下穿过去。
/// 正在被下一组顶掉（overlapsContent）时补一条 hairline 底边，边界才清楚。
class _DayHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DayHeaderDelegate(
      {required this.day, required this.net, required this.onReceipt});

  final DateTime day;
  final int net;

  /// 点右侧小票图标 → 这一天的「每日小票」。
  final VoidCallback onReceipt;

  static const double _height = 30;

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Palette.paper(context),
      decoration: overlapsContent
          ? BoxDecoration(
              border: Border(
                  bottom: BorderSide(color: Palette.hairline(context))))
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Text('${day.month} 月 ${day.day} 日',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Palette.inkSoft(context))),
          Text(' · ${_LedgerPageState._weekday(day)}',
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          const Spacer(),
          MoneyText(net,
              flow: net >= 0 ? 'in' : 'out',
              showSymbol: false,
              style: TextStyle(
                  fontSize: 12,
                  color: Palette.inkFaint(context),
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(width: 6),
          // 入口放在日期头上：哪一天的票就从哪一天的头进，
          // 不用再造一个"每日小票"的功能页入口。
          GestureDetector(
            onTap: onReceipt,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Icon(Icons.receipt_long_outlined,
                  size: 16, color: Palette.inkFaint(context)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _DayHeaderDelegate oldDelegate) =>
      oldDelegate.day != day ||
      oldDelegate.net != net ||
      oldDelegate.onReceipt != onReceipt;
}

/// 年度账单提醒卡（对齐原版 home_page 的年度报告提醒）：
/// 每年 12 月 15 日之后到次年 1 月底，提示当年的年度账单已生成。
class _AnnualReportCard extends StatelessWidget {
  const _AnnualReportCard({required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    // 12/15 ~ 12/31 提醒「今年」；1/1 ~ 1/31 提醒「去年」
    final int? reportYear = switch ((now.month, now.day)) {
      (12, >= 15) => now.year,
      (1, _) => now.year - 1,
      _ => null,
    };
    if (reportYear == null) return const SizedBox.shrink();
    // 正在翻看历史月份时不打扰
    if (month.year != now.year || month.month != now.month) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Reveal(
        // 整卡可点（行高 ≈52，远超 48），不再用一个 12px 的文字按钮当唯一入口 ——
        // 那个按钮的实际点击区只有 20dp 出头，手指稍微偏一点就没反应。
        child: PressScale(
          scale: 0.98,
          onTap: () => Navigator.of(context)
              .push(AppPageRoute(page: const ReportPage())),
          child: Panel(
            child: Row(
              children: [
                Icon(Icons.auto_graph_rounded,
                    size: 18, color: Palette.brand(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style:
                          TextStyle(fontSize: 13, color: Palette.ink(context)),
                      children: [
                        TextSpan(
                          text: '$reportYear 年度账单',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Palette.brand(context)),
                        ),
                        const TextSpan(text: ' 已生成'),
                      ],
                    ),
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 16, color: Palette.inkFaint(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 今日安全可花（对齐参考版首页的标志性卡片）：
/// （本月预算 − 本月已花 − 待扣账单）÷ 剩余天数 − 今日已花。
///
/// 与 BudgetProgress.safeDailyCents 的差别：它给的是**日均值**（每天一样），
/// 这里是**今天**还能花多少，所以要把今天已经花掉的减掉。少了这一步，
/// 今天花 500 和花 0 显示同一个数，用户只会以为算错了。
class _SafeToSpendCard extends ConsumerWidget {
  const _SafeToSpendCard({required this.budgetCents, required this.totals});

  final int budgetCents;
  final ({int incomeCents, int expenseCents}) totals;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final now = DateTime.now();
    final month = ref.watch(monthProvider);
    // 只看本月；翻历史月不显示
    if (month.year != now.year || month.month != now.month) {
      return const SizedBox.shrink();
    }
    if (budgetCents <= 0) return const SizedBox.shrink();

    final daysLeft = daysLeftInMonth(now);
    if (daysLeft <= 0) return const SizedBox.shrink();

    // 未来待扣的周期账单：照这个花会超支，先扣掉
    final recurrings = ref.watch(recurringsProvider).valueOrNull ?? const [];
    var pending = 0;
    for (final r in recurrings) {
      if (!r.enabled || r.flow != 'out') continue;
      if (r.dayOfMonth >= now.day &&
          r.lastRunMonth != '${now.year}-${_two(now.month)}') {
        pending += r.amountCents;
      }
    }

    // 今日已花。必须走 dailyTotalsProvider 折算后的口径：
    // 上面大字显示的「本月支出」是折算成主币种的，这里若拿裸金额来减，
    // 外币卡刷一笔就会算出离谱的数。
    final todaySpent = ref
            .watch(dailyTotalsProvider)
            .valueOrNull?[dayKey(now)]?.expenseCents ??
        0;

    final safe = safeToSpendCents(
      budgetCents: budgetCents,
      spentCents: totals.expenseCents,
      todaySpentCents: todaySpent,
      pendingCents: pending,
      daysLeft: daysLeft,
    );
    final over = safe < 0;
    // ⚠️ safe 的单位是「分」。之前直接 toStringAsFixed 当元打印，
    // 导致预算 2000 元、剩 10 天时显示成「¥20000」（20000 分）。
    // 日均不足 1 元（100 分）时保留 1 位小数，否则 ¥0.08 会显示成 ¥0。
    final text = settings.hideAmounts
        ? '****'
        : safe.abs() < 100
            ? (safe.abs() / 100).toStringAsFixed(1)
            : centsToText(safe.abs().round());

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Reveal(
        delay: const Duration(milliseconds: 40),
        child: Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.shield_outlined,
                      size: 18, color: Palette.brand(context)),
                  const SizedBox(width: 8),
                  Text('今日安全可花',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Palette.inkSoft(context))),
                  const Spacer(),
                  if (pending > 0)
                    Text('已扣待付 ${settings.symbol}${centsToText(pending)}',
                        style: TextStyle(
                            fontSize: 10.5, color: Palette.inkFaint(context))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${over ? '-' : ''}${settings.symbol}$text',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: over ? Palette.expense : Palette.ink(context),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      over ? '今天已超支' : '还剩 $daysLeft 天',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkSoft(context)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _two(int v) => v.toString().padLeft(2, '0');
}

/// 明细页折叠头部（复刻原版 PrimaryHeader + HomeBudgetSummary 的分层：
/// 展开时三行「账本条 / 年月 / 收支三段」，滚动后收起第一、三行，
/// 只留「年月 + 紧凑收支」，并压到顶栏位置）。
class _LedgerHeader extends SliverPersistentHeaderDelegate {
  _LedgerHeader({
    required this.bookAsync,
    required this.topPadding,
    required this.onSearch,
    this.onCalendar,
    this.coverPath = '',
    this.coverLuminance = 0.5,
  });

  final AsyncValue<Book> bookAsync;
  final double topPadding;
  final VoidCallback onSearch;

  /// 右上角「日历」图标；null = 不显示
  final VoidCallback? onCalendar;

  /// 首页主封面（用户自己的照片）。空串 = 不显示封面。
  final String coverPath;

  /// 封面平均亮度（0~1），决定遮罩压多重。
  final double coverLuminance;

  /// 2026-10-26：顶栏瘦成**一行不折叠**的「账本 + 日历/搜索」。
  ///
  /// 用户要求「去掉顶部的月份条和收支条，本月概览固定显示」。
  /// 原来那两条是重复信息：月份条（‹ 2026年10月 ›）已无处可去（首页只看本月，
  /// 翻历史月去日历页），收支条（收入 | 支出 | 结余）和下面的「本月概览」大卡
  /// 讲的是同一件事。删掉后重心回到概览卡上。
  ///
  /// 顺带把折叠动效整套砍了：现在 maxExtent == minExtent，SliverPersistentHeader
  /// 退化成一条常驻顶栏，不用再维护「哪一行按 t 归零」这种一改就断言的计算。
  static const _barHeight = 48.0;

  @override
  double get maxExtent => _barHeight + topPadding;

  // 不折叠：pinned 但高度恒定，滚动时只有下方列表在动。
  @override
  double get minExtent => _barHeight + topPadding;

  @override
  bool shouldRebuild(covariant _LedgerHeader old) =>
      old.topPadding != topPadding ||
      old.coverPath != coverPath ||
      old.coverLuminance != coverLuminance ||
      old.bookAsync.valueOrNull?.id != bookAsync.valueOrNull?.id ||
      old.bookAsync.valueOrNull?.title != bookAsync.valueOrNull?.title ||
      old.onSearch != onSearch ||
      old.onCalendar != onCalendar;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    // 有封面时顶栏是"照片底"，深色字必然糊，所以文字整体转白。
    final hasCover = coverPath.isNotEmpty;
    final coverInkSoft = hasCover
        ? Colors.white.withValues(alpha: 0.82)
        : Palette.inkFaint(context);

    // 顶栏是第 0 块：它浮得最早、幅度也最小 —— 它是"钉"在顶上的，
    // 下沉 22px 会在它上方露出一条背景色的缝。
    // 无封面时顶栏是**玻璃**：下面就是流水列表，滚动时金额会从玻璃底下走过去。
    // 有封面时封面本身就是底图，再叠模糊只会把照片糊掉，保持实色。
    final bar = Container(
      // 有封面时底色交给封面自己画；这里给深色兜底，
      // 封面文件被删掉 / 恢复备份后丢失时白字仍然读得出来。
      // 内容滚到顶栏下面时再补一条细阴影分层。
      decoration: BoxDecoration(
        color: hasCover ? const Color(0xFF1F2422) : Colors.transparent,
        boxShadow: overlapsContent
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Stack(
          children: [
            if (hasCover)
              Positioned.fill(
                child: _CoverBackdrop(
                  path: coverPath,
                  // 顶栏不再折叠，位移项恒为 0
                  shrinkOffset: 0,
                  luminance: coverLuminance,
                ),
              ),
            Padding(
              padding: EdgeInsets.only(top: topPadding),
              child: SizedBox(
                height: _barHeight,
                child: Row(
                  children: [
                    const SizedBox(width: 12),
                    _BookChip(bookAsync: bookAsync, onCover: hasCover),
                    const Spacer(),
                    // 语音记账不占顶栏：它是首页右下角那颗独立的悬浮按钮，
                    // 单手可达、也不会被封面/浅色顶栏吃掉对比度。
                    // 顶栏只留「账本 + 日历 + 搜索」。
                    // 日历：搜索左边。查历史某天是高频动作，
                    // 之前占着一个底部 tab，现在收进这里。
                    if (onCalendar != null)
                      IconButton(
                        tooltip: '日历',
                        visualDensity: VisualDensity.compact,
                        onPressed: onCalendar,
                        icon: Icon(Icons.calendar_today_outlined,
                            size: 18, color: coverInkSoft),
                      ),
                    IconButton(
                      tooltip: '搜索',
                      visualDensity: VisualDensity.compact,
                      onPressed: onSearch,
                      icon: Icon(Icons.search, size: 18, color: coverInkSoft),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
          ],
        ),
    );

    return BootRevealItem(
      index: 0,
      y: 8,
      child: hasCover ? ClipRect(child: bar) : Glass(blur: 18, child: bar),
    );
  }
}


/// 上月报告卡：看本月时提示上月收支，点进去看**该月报告**。
///
/// 注意：不能在这里改 `monthProvider` 翻月。首页是「只看本月」的，
/// `LedgerPage.build` 一旦发现 month != 当月就会立刻归位（第 107 行），
/// 点了等于没点（2026-11-02 用户报的 bug）。改成 push 独立页。
class _LastMonthCard extends ConsumerWidget {
  const _LastMonthCard({required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    // 只看本月时提示；翻历史月不再刷这条
    if (month.year != now.year || month.month != now.month) {
      return const SizedBox.shrink();
    }
    final series =
        ref.watch(monthSeriesProvider((count: 2, anchor: month))).valueOrNull;
    if (series == null || series.length < 2) return const SizedBox.shrink();
    final prev = series[0];
    if (prev.incomeCents == 0 && prev.expenseCents == 0) {
      return const SizedBox.shrink();
    }
    final prevMonth = DateTime(month.year, month.month - 1);
    // 看过就不再提：token 用**被归档的那个月**，所以同一个月只会出现一次。
    // （不走"本月内不再显示"，因为这张卡讲的是别的月份的事，看过就结束了。）
    final token = AppSettings.hintToken('archive', prevMonth);
    if (ref.watch(settingsProvider).isHintDismissed(token)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Reveal(
        // 整卡可点：点哪儿都翻到上个月（原来只有「查看」两个小字能点）
        child: PressScale(
          scale: 0.98,
          // 跳到独立的「该月报告」页：不改 monthProvider，避免被首页归位抹掉。
          onTap: () {
            // 先记"看过了"再跳：从报告页返回时首页已经重建，卡片自然不再出现。
            ref.read(settingsProvider.notifier).dismissHint(token);
            Navigator.of(context).push(
                AppPageRoute(page: MonthSummaryPage(month: prevMonth)));
          },
          child: Panel(
            child: Row(
              children: [
                Icon(Icons.auto_awesome,
                    size: 18, color: Palette.brand(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style:
                          TextStyle(fontSize: 13, color: Palette.ink(context)),
                      children: [
                        TextSpan(
                          text: '${prevMonth.month} 月',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Palette.brand(context)),
                        ),
                        const TextSpan(text: ' 收支已归档'),
                      ],
                    ),
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 16, color: Palette.inkFaint(context)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 预算引导卡：没设预算时给一个直达入口，可关掉。
class _BudgetHintCard extends ConsumerStatefulWidget {
  const _BudgetHintCard({required this.budgetCents, required this.spentCents});

  final int budgetCents;
  final int spentCents;

  @override
  ConsumerState<_BudgetHintCard> createState() => _BudgetHintCardState();
}

class _BudgetHintCardState extends ConsumerState<_BudgetHintCard> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final budget = widget.budgetCents;
    final settings = ref.watch(settingsProvider);
    final symbol = settings.symbol;

    // 「点过就不再烦」：token 按月，本月内不再出现，下个月重新提醒一次。
    // 以前这张卡只能本次会话关，冷启动又原样弹回来 —— 用户点了、进了预算页、
    // 也没设预算，下次开机还是那条，久了就当装饰看了。
    //
    // ⚠️ 引导态和预警态**必须用不同的 token**：用户把「设个月度预算」关掉之后
    // 很可能就顺手去设了预算，若共用一个 token，这个月真超支了也再也看不到 ——
    // 等于把最该响的警报静音了。关掉的是「劝」，不是「报」。
    final month = ref.watch(monthProvider);
    final guideToken = AppSettings.hintToken('budget', month);
    final warnToken = AppSettings.hintToken('budgetwarn', month);

    // 分类超支：总额可能还宽裕，但某个分类已经爆了 —— 这才是最该提醒的情形。
    // 之前这张卡只算总预算，分类超支在首页完全看不出来。
    final overBuckets = [
      for (final b in ref.watch(bucketBudgetStatusProvider).valueOrNull ??
          const <BucketBudgetStatus>[])
        if (b.spentCents > b.budgetCents) b,
    ];

    // ① 没设总预算 → 引导卡（可关）；但若已有分类超支，优先报超支。
    if (budget <= 0) {
      if (overBuckets.isNotEmpty) {
        return _overShell(context, overBuckets, symbol, warnToken);
      }
      if (settings.isHintDismissed(guideToken)) {
        return const SizedBox.shrink();
      }
      return _shell(
        context,
        token: guideToken,
        leading: Icon(Icons.pie_chart_outline,
            size: 18, color: Palette.brand(context)),
        child: const Text('设个月度预算，超支前会提醒你',
            style: TextStyle(fontSize: 13)),
      );
    }
    // ② 设了预算：只在「快用完 / 已超支」时露出来，平时不占屏。
    final spent = widget.spentCents;
    final ratio = budget == 0 ? 0.0 : spent / budget;
    if (ratio < 0.8) {
      if (overBuckets.isNotEmpty) {
        return _overShell(context, overBuckets, symbol, warnToken);
      }
      return const SizedBox.shrink();
    }
    if (settings.isHintDismissed(warnToken)) return const SizedBox.shrink();
    final over = spent >= budget;
    final color = over ? Palette.expense : const Color(0xFFB26A00);
    final pct = (ratio * 100).round();
    final text = over
        ? '本月预算已超支 $symbol${centsToText(spent - budget)}'
        : '本月预算已用 $pct%，还能花 $symbol${centsToText(budget - spent)}';
    return _shell(
      context,
      token: warnToken,
      leading: Icon(
          over ? Icons.error_outline : Icons.warning_amber_rounded,
          size: 18,
          color: color),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: color)),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 5,
              color: color,
              backgroundColor: color.withValues(alpha: 0.15),
            ),
          ),
        ],
      ),
    );
  }

  /// 统一的提示条外壳：整卡可点进预算页；右侧 ✕ 与「点进去」都记一次本月已提示。
  Widget _shell(BuildContext context,
      {required Widget leading,
      required Widget child,
      required String token}) {
    void dismiss() =>
        ref.read(settingsProvider.notifier).dismissHint(token);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Reveal(
        delay: const Duration(milliseconds: 40),
        // 整卡可点：提示条本身就是入口，右边那个 ✕ 仍然独立（IconButton 自带
        // 48 的点击区，会先吃掉落在它身上的点击，不会误跳预算页）。
        child: PressScale(
          scale: 0.98,
          onTap: () {
            dismiss(); // 先记账再跳，返回时这张卡就已经不在了
            Navigator.of(context).push(AppPageRoute(page: const BudgetPage()));
          },
          child: Panel(
            child: Row(
              children: [
                leading,
                const SizedBox(width: 10),
                Expanded(child: child),
                Icon(Icons.chevron_right,
                    size: 16, color: Palette.inkFaint(context)),
                IconButton(
                  tooltip: '本月不再提示',
                  onPressed: () {
                    dismiss();
                    setState(() => _dismissed = true); // 立刻消失，不等重建
                  },
                  icon: Icon(Icons.close,
                      size: 18, color: Palette.inkFaint(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 分类超支提示：只说「哪个分类超了多少」，不画进度条——总预算可能还没到线，
  /// 再堆一条进度条反而让人以为总额也危险了。
  Widget _overShell(BuildContext context, List<BucketBudgetStatus> items,
      String symbol, String token) {
    final head = items.length == 1
        ? '「${items.first.title}」已超预算 '
            '$symbol${centsToText(items.first.spentCents - items.first.budgetCents)}'
        : '${items.length} 个分类超预算：'
            '${items.take(2).map((b) => '${b.title} $symbol${centsToText(b.spentCents - b.budgetCents)}').join('、')}'
            '${items.length > 2 ? ' 等' : ''}';
    return _shell(
      context,
      token: token,
      leading:
          Icon(Icons.error_outline, size: 18, color: Palette.expense),
      child: Text(head,
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Palette.expense)),
    );
  }
}

/// 备份提醒：从没导出过 / 太久没导出，就在首页给一条提示条。
///
/// 阈值取 7 天是按「丢数据的容忍窗口」拍的：超过一周没备份，
/// 手机一坏丢的就是一周的账。刚备份过就完全不出现 —— 天天弹等于没有，
/// 用户会把它当成装饰而不是提醒。
///
/// 关掉后**本月不再出现**（落盘，`backup:YYYY-MM`）：以前只在本次会话关，
/// 冷启动又原样弹回来，用户点过、也进过导出页，下次开机还是那条。
/// 下个月如果还没备份，会重新提醒一次 —— 备份这件事不该永久静音。
class _BackupHintCard extends ConsumerStatefulWidget {
  const _BackupHintCard();

  @override
  ConsumerState<_BackupHintCard> createState() => _BackupHintCardState();
}

class _BackupHintCardState extends ConsumerState<_BackupHintCard> {
  static const _thresholdDays = 7;
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final days = settings.daysSinceBackup;
    final String text;
    if (days == null) {
      text = '还没导出过备份，数据只存在这台手机上';
    } else if (days >= _thresholdDays) {
      text = days >= 60
          ? '距上次备份已 ${days ~/ 30} 个月，建议导出一份'
          : '距上次备份已 $days 天，建议导出一份';
    } else {
      return const SizedBox.shrink();
    }
    final hintToken = AppSettings.hintToken('backup', DateTime.now());
    if (_dismissed || settings.isHintDismissed(hintToken)) {
      return const SizedBox.shrink();
    }
    void dismiss() => ref.read(settingsProvider.notifier).dismissHint(hintToken);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Reveal(
        delay: const Duration(milliseconds: 40),
        // 整卡可点（同上）
        child: PressScale(
          scale: 0.98,
          onTap: () {
            dismiss(); // 先记账再跳，返回时这张卡就已经不在了
            Navigator.of(context)
                .push(AppPageRoute(page: const ExportPage()));
          },
          child: Panel(
            child: Row(
              children: [
                Icon(Icons.backup_outlined,
                    size: 18, color: Palette.brand(context)),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(text, style: const TextStyle(fontSize: 13))),
                Icon(Icons.chevron_right,
                    size: 16, color: Palette.inkFaint(context)),
                IconButton(
                  tooltip: '本月不再提示',
                  onPressed: () {
                    dismiss();
                    setState(() => _dismissed = true); // 立刻消失，不等重建
                  },
                  icon: Icon(Icons.close,
                      size: 18, color: Palette.inkFaint(context)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BookChip extends ConsumerWidget {
  const _BookChip({required this.bookAsync, this.onCover = false});

  final AsyncValue<Book> bookAsync;

  /// 压在封面照片上时用半透明白胶囊，主色胶囊在照片里会糊掉。
  final bool onCover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pillColor = onCover
        ? Colors.white.withValues(alpha: 0.18)
        : Palette.brand(context).withValues(alpha: 0.10);
    final inkColor = onCover ? Colors.white : Palette.brand(context);

    return bookAsync.when(
      loading: () => const SizedBox(width: 16),
      error: (e, _) => const SizedBox(width: 16),
      data: (book) => PressScale(
        scale: 0.9,
        onTap: () => _showBookSheet(context, ref, book),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: pillColor,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppGlyph(book.glyph, size: 13),
              const SizedBox(width: 4),
              Text(book.title,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: inkColor)),
              const SizedBox(width: 2),
              Icon(Icons.keyboard_arrow_down, size: 14, color: inkColor),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showBookSheet(
      BuildContext context, WidgetRef ref, Book current) async {
    final store = await ref.read(storeProvider.future);
    final books = await store.books();
    if (!context.mounted) return;
    await showAppSheet<void>(
      context: context,
      title: '切换账本',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final b in books)
            ListTile(
              leading: AppGlyph(b.glyph, size: 18),
              title: Text(b.title),
              subtitle: Text('主币种 ${nameOf(b.baseCurrency)}'),
              trailing: b.id == current.id ? const Icon(Icons.check) : null,
              onTap: () {
                ref.read(activeBookIdProvider.notifier).state = b.id;
                Navigator.pop(ctx);
              },
            ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('管理账本 / 汇率'),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.of(context)
                  .push(AppPageRoute(page: const BookManagePage()));
            },
          ),
        ],
      ),
    );
  }
}

/// 单条流水：转账显示 A → B；报销中的支出带角标；外币账户金额带币种后缀。
/// 批量操作条：长按任意流水后从底部升起。
///
/// 为什么放底部而不是改 AppBar：首页是 tab body，没有自己的 Scaffold；
/// 用 Stack 叠一条底部条最省事，也不会让列表因为布局变化而跳动。
class _BatchBar extends StatelessWidget {
  const _BatchBar({
    required this.count,
    required this.allSelected,
    required this.onSelectAll,
    required this.onBucket,
    required this.onDay,
    required this.onDelete,
    required this.onCancel,
  });

  final int count;
  final bool allSelected;
  final VoidCallback onSelectAll;
  final VoidCallback onBucket;
  final VoidCallback onDay;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final enabled = count > 0;
    return Material(
      elevation: 10,
      color: Palette.card(context),
      child: SafeArea(
        top: false,
        child: Container(
          height: 58,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Palette.hairline(context))),
          ),
          child: Row(
            children: [
              Text(
                count == 0 ? '选择流水' : '已选 $count 条',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Palette.ink(context),
                ),
              ),
              const Spacer(),
              _action(context, Icons.select_all,
                  allSelected ? '取消全选' : '全选', onSelectAll),
              _action(context, Icons.category_outlined, '分类', onBucket,
                  enabled: enabled),
              _action(context, Icons.event_outlined, '日期', onDay,
                  enabled: enabled),
              _action(context, Icons.delete_outline, '删除', onDelete,
                  enabled: enabled, danger: true),
              _action(context, Icons.close, '退出', onCancel),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool enabled = true,
    bool danger = false,
  }) {
    final color = !enabled
        ? Palette.inkFaint(context)
        : (danger ? Palette.expense : Palette.inkSoft(context));
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: PressScale(
        scale: 0.9,
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: 46,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(height: 1),
              Text(label,
                  maxLines: 1,
                  style: TextStyle(fontSize: 10.5, height: 1.1, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

class EntryRow extends ConsumerWidget {
  const EntryRow({
    super.key,
    required this.entry,
    this.onTap,
    this.onLongPress,
    this.selected,
    this.timeline = false,
    this.isFirst = false,
    this.isLast = false,
  });

  final Entry entry;

  /// 自定义点击行为（搜索页批量模式用）；为空则进编辑页
  final VoidCallback? onTap;

  /// 长按（首页流水进入批量选择用）；为空则不接管
  final VoidCallback? onLongPress;

  /// 非空 = 选择模式，行前显示勾选框
  final bool? selected;

  /// 时间轴模式（2026-11-03 首页启用）：
  /// 左侧显示时分、中间一列竖线 + 分类节点，右侧内容和金额不变。
  /// 日历 / 账户详情 / 分类详情仍用原来的紧凑行 —— 那里一屏要放更多行。
  final bool timeline;

  /// 当天第一行 / 最后一行：竖线在首尾各收一段，不往上下伸出。
  final bool isFirst;
  final bool isLast;

  /// 时间轴行的上下留白。
  /// 竖线必须延伸到这段留白之外，行与行之间才连得上 —— 所以画线和 padding
  /// 必须共用同一个值，改一个忘另一个就会出现"一节一节的短线"。
  static const double _timelinePadV = 10;

  /// 'HH:mm'；没记时分的老账显示 '--:--'（不编时间）。
  String get _timeText {
    final m = entry.timeMinutes;
    if (m == null) return '--:--';
    return '${(m ~/ 60).toString().padLeft(2, '0')}:'
        '${(m % 60).toString().padLeft(2, '0')}';
  }

  /// 时间轴中间那一列：贯穿的竖线 + 分类节点。
  ///
  /// 用 Stack 而不是 Column + Expanded：节点要贴行顶（和时间、标题同一基线），
  /// 而 Column 会把它放在行垂直中心，时间文字就和标题错位了。
  Widget _rail(BuildContext context, String glyph, bool isTransfer,
      String? categoryTitle) {
    final line = Palette.hairline(context);
    final tint = (isTransfer
            ? Palette.inkFaint(context)
            : Palette.categoryColor(context, categoryTitle ?? '未分类'))
        .withValues(alpha: 0.14);
    return SizedBox(
      width: 28,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 单笔（既是首行也是末行）不画线：否则节点上方会多出一小截断头线。
          // 其余情况让线越过行的上下 padding（-padV），相邻两行的线段才会接上。
          if (!(isFirst && isLast)) ...[
            if (isLast)
              Positioned(
                  left: 13.25,
                  top: -_timelinePadV,
                  height: _timelinePadV + 13,
                  child: Container(width: 1.5, color: line))
            else
              Positioned(
                  left: 13.25,
                  top: isFirst ? 13 : -_timelinePadV,
                  bottom: -_timelinePadV,
                  child: Container(width: 1.5, color: line)),
          ],
          Positioned(
            top: 0,
            left: 1,
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // 必须不透明：节点用半透明底时，竖线会从底下透出来，
                // 看着像"线插进了图标里"。按卡片底色混合出不透明浅色。
                color: Color.alphaBlend(tint, Palette.card(context)),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: (isTransfer
                          ? Palette.inkFaint(context)
                          : Palette.categoryColor(
                              context, categoryTitle ?? '未分类'))
                      .withValues(alpha: 0.20),
                  width: 1,
                ),
              ),
              child: IconService.isImage(glyph)
                  ? AppGlyph(glyph, size: 26, fill: true, radius: 8)
                  : AppGlyph(glyph, size: 14),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 必须含归档分类：归档 ≠ 删除，否则一归档全部旧账都显示「未分类」。
    // 走 id → 对象 的索引（见 bucketByIdProvider），不再每行线性扫一遍。
    final bucket = ref.watch(bucketByIdProvider)[entry.bucketId];
    final pocketMap = ref.watch(pocketByIdProvider);
    final fromPocket = pocketMap[entry.pocketId];
    final toPocket = pocketMap[entry.toPocketId];
    final base =
        ref.watch(activeBookProvider).valueOrNull?.baseCurrency ?? 'CNY';
    // 币种后缀要优先用「本笔币种」，否则在人民币账户上记一笔美元，
    // 金额后面不会显示 USD，看着像人民币。
    final entryCurrency = entry.currency ?? fromPocket?.currency ?? base;
    final suffix = amountSuffix(entryCurrency, base);
    // 列表行主标题：备注优先（默认）还是分类名优先。另一个挪到副标题，信息不丢。
    final categoryAsTitle =
        ref.watch(settingsProvider).noteDisplay == 'category';
    // 有凭证的流水给个 📎，不然用户不知道里面有图
    final attachCount =
        ref.watch(attachmentCountsProvider).valueOrNull?[entry.id] ?? 0;
    // 退款关系要双向可见：这笔是退款 / 这笔已经被退款
    final refundedSources =
        ref.watch(refundedSourceIdsProvider).valueOrNull ?? const <int>{};

    final isTransfer = entry.isTransfer;
    final categoryTitle = bucket?.title ?? '未分类';
    final noteTitle = entry.memo.isNotEmpty ? entry.memo : categoryTitle;
    final title = isTransfer
        ? '${fromPocket?.title ?? '账户'} → ${toPocket?.title ?? '账户'}'
        : (categoryAsTitle ? categoryTitle : noteTitle);
    final glyph = isTransfer
        ? '🔄'
        : (bucket?.glyph ?? (entry.flow == 'in' ? '💰' : '🧾'));

    // 副标题 = 账户名 + 原有附加信息（标签 / 优惠 / 转账信息）。
    // 参考效果：标题是分类名（如「彩票」），第二行要能看见账户（如「支付宝」）。
    final accountLabel = isTransfer ? null : fromPocket?.displayName;
    final extra = _subtitle(bucket, isTransfer, categoryAsTitle);
    final subtitleText = [
      if (accountLabel != null && accountLabel.trim().isNotEmpty)
        accountLabel.trim(),
      // AA 分摊：欠款人 + 他承担的金额写进副标题（主金额仍是实际垫付全额），
      // 用户一眼能解释「日期头净额为什么比这一行小」。
      if (entry.hasSplit &&
          (entry.aaCounterparty ?? '').trim().isNotEmpty)
        (entry.aaCounterparty!).trim(),
      if (entry.hasSplit) 'AA 代付 ${centsToText(entry.splitCents)}',
      if (extra != null && extra.isNotEmpty) extra,
    ].join(' · ');

    return PressScale(
      scale: 0.97,
      onLongPress: onLongPress,
      onTap: onTap ??
          () {
            openEntryEditor(context, ref, existing: entry);
          },
      child: Padding(
        padding: EdgeInsets.symmetric(
            horizontal: 14, vertical: timeline ? _timelinePadV : 12),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: timeline
                ? CrossAxisAlignment.stretch
                : CrossAxisAlignment.center,
            children: [
            // 批量选择模式：行前勾选框
            if (selected != null) ...[
              Icon(
                selected! ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 20,
                color: selected!
                    ? Palette.brand(context)
                    : Palette.inkFaint(context),
              ),
              const SizedBox(width: 10),
            ],
            if (timeline) ...[
              _rail(context, glyph, isTransfer, bucket?.title),
              const SizedBox(width: 8),
            ] else ...[
              // 自定义图片图标：铺满正方形、不要灰底（对齐参考图）。
              // emoji / 默认图标放「分类固定色 14%」的圆角盒 ——
              // 2026-10-28 之前是无彩灰底，一屏全是灰方块，等于没有颜色。
              // 转账没有分类，用中性灰，否则「转账」会跟着某个分类的颜色跑。
              if (IconService.isImage(glyph))
                SizedBox(
                  width: 40,
                  height: 40,
                  child: AppGlyph(glyph, size: 40, fill: true, radius: 4),
                )
              else
                Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (isTransfer
                            ? Palette.inkFaint(context)
                            : Palette.categoryColor(
                                context, bucket?.title ?? '未分类'))
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: AppGlyph(glyph, size: 18),
                ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // 时间轴内侧：时分紧跟在节点右边、标题前面。
                      if (timeline) ...[
                        SizedBox(
                          width: 40,
                          child: Text(_timeText,
                              maxLines: 1,
                              style: TextStyle(
                                fontSize: 11,
                                color: Palette.inkFaint(context),
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ],
                              )),
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Palette.ink(context))),
                      ),
                      if (entry.hasSplit) ...[
                        const SizedBox(width: 6),
                        _badge(context, 'AA', done: true),
                      ],
                      if (entry.reimburse == 1) ...[
                        const SizedBox(width: 6),
                        _badge(context, '报销中'),
                      ],
                      if (entry.reimburse == 2) ...[
                        const SizedBox(width: 6),
                        _badge(context, '已报销', done: true),
                      ],
                      // 对账产生的校准流水单独标「校准」；它同时也 excludeFromStats，
                      // 但两个角标挤在一起反而看不清，校准优先。
                      if (entry.adjustment) ...[
                        const SizedBox(width: 6),
                        _badge(context, '校准', muted: true),
                      ] else if (entry.excludeFromStats) ...[
                        // 不计入收支的笔要标出来，否则用户会以为统计算错了
                        const SizedBox(width: 6),
                        _badge(context, '不计收支', muted: true),
                      ],
                      if (entry.refundOfId != null) ...[
                        const SizedBox(width: 6),
                        _badge(context, '退款', muted: true),
                      ],
                      if (refundedSources.contains(entry.id)) ...[
                        const SizedBox(width: 6),
                        _badge(context, '已退款', done: true),
                      ],
                      if (attachCount > 0) ...[
                        const SizedBox(width: 5),
                        Icon(Icons.photo_outlined,
                            size: 14, color: Palette.inkFaint(context)),
                      ],
                    ],
                  ),
                  if (subtitleText.isNotEmpty)
                    Padding(
                      padding:
                          EdgeInsets.only(top: 2, left: timeline ? 46 : 0),
                      child: Text(
                        subtitleText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: Palette.inkFaint(context)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            MoneyText(
              entry.amountCents,
              flow: isTransfer ? null : entry.flow,
              suffix: suffix,
              // 流水行不带币种符号：符号占位、显重，且整列都是同一币种时纯噪音。
              showSymbol: false,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  /// 副标题。标题已经是分类名时，别把分类名再重复一遍。
  String? _subtitle(Bucket? bucket, bool isTransfer, bool categoryAsTitle) {
    if (isTransfer) {
      // 转账的附注信息不展示就等于没记：手续费花了钱、到账金额和
      // 转出金额不一样（跨币种），用户都得能在这行看到。
      final parts = <String>[
        if (entry.memo.isNotEmpty) entry.memo else '账户间转账',
        if (entry.feeCents > 0) '手续费 ${centsToText(entry.feeCents)}',
        if (entry.discountCents > 0) '优惠 ${centsToText(entry.discountCents)}',
        if (entry.toAmountCents != null &&
            entry.toAmountCents != entry.amountCents)
          '到账 ${centsToText(entry.toAmountCents!)}',
      ];
      return parts.join(' · ');
    }
    // 优惠（支出/收入也能记）：不在列表里露出来就等于没记
    if (entry.discountCents > 0) {
      final base = entry.tags.isNotEmpty
          ? '#${entry.tags.replaceAll(',', ' #')}'
          : (entry.memo.isNotEmpty ? entry.memo : null);
      return [
        if (base != null) base,
        '省 ${centsToText(entry.discountCents)}',
      ].join(' · ');
    }
    if (entry.tags.isNotEmpty) return '#${entry.tags.replaceAll(',', ' #')}';
    if (categoryAsTitle) return entry.memo.isNotEmpty ? entry.memo : null;
    if (entry.memo.isNotEmpty && bucket != null) return bucket.title;
    return null;
  }

  Widget _badge(BuildContext context, String text,
      {bool done = false, bool muted = false}) {
    final base = muted
        ? Palette.inkFaint(context)
        : (done ? Palette.income : Palette.brand(context));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: base.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: base,
        ),
      ),
    );
  }
}

/// 首页汇总大卡：山水插画背景 + 本月结余大字 + 支出 / 收入。
class _HomeHeroCard extends ConsumerWidget {
  const _HomeHeroCard({
    required this.expenseCents,
    required this.incomeCents,
    required this.budgetCents,
  });

  final int expenseCents;
  final int incomeCents;
  final int budgetCents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final net = incomeCents - expenseCents;
    // 2026-10-28：汇总卡加一层薄荷渐变底。
    // 原来它和下面的流水卡一样是纯白，整页只有"深绿按钮 + 红色金额"两个重点，
    // 最该有分量的汇总反而最轻。渐变从薄荷到近卡色（深色模式同理），
    // 不抢文字，但一眼能分出"这是汇总、下面是流水"。
    // 2026-11-05：渐变与前景色改成跟着「配色方案」走。
    // 四套渐变里只有极光油膜是深底，其余三套是浅色治愈渐变——
    // 写死白字会让浅紫/薄荷/蜜桃上的金额直接消失，所以 onHero 必须取主题。
    final onHero = Palette.onGradient(context);
    final onHeroSoft = onHero.withValues(alpha: 0.72);
    return Panel(
      padding: EdgeInsets.zero,
      gradient: Palette.gradient(context),
      child: HillCardBackground(
        color: onHero.withValues(alpha: 0.12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('本月结余',
                      style: TextStyle(fontSize: 13, color: onHeroSoft)),
                  const Spacer(),
                  if (budgetCents > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: onHero.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '预算 ${settings.symbol}${centsToText(budgetCents)}',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: onHero),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              MoneyText(
                net,
                // 不传 flow：MoneyText 在 flow 非空时会强制用收支色（in=深绿 / out=红），
                // 而这张卡是品牌色深底，深绿字直接糊进背景。颜色交给 style，
                // 正负号仍由 moneyLabel 按数值处理（无 flow 时负数照样带负号）。
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: onHero,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _mini(context, '支出', expenseCents, onHero),
                  _mini(context, '收入', incomeCents, onHero),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mini(BuildContext context, String label, int cents, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              // 跟着前景色走：浅渐变（薄荷/薰衣草/蜜桃）上白字会糊掉
              style: TextStyle(
                  fontSize: 12, color: color.withValues(alpha: 0.7))),
          const SizedBox(height: 3),
          // 走 MoneyText：hidden 状态和「结余为负」都由它处理。
          // 原来这里手写 `centsToText(cents.abs())`，-12 会显示成「¥12」——
          // 和日历页结余丢负号是同一个坑，记账 App 里这算致命错误。
          MoneyText(
            cents,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// 通栏「添加一条新记账」按钮（替代原来的中间凸起记账键）。
class _AddEntryButton extends StatelessWidget {
  const _AddEntryButton();

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    return PressScale(
      scale: 0.98,
      onTap: () => Navigator.of(context)
          .push(AppPageRoute(page: const EntryEditorPage())),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          // 2026-10-28：从深绿实心降级成「薄荷底 + 品牌色字 + 细边」。
          // 原来它是全页最重的一块（比金额还抢眼），一进首页眼睛先被它拽走；
          // 而它只是个入口，不是内容。现在退到"可点但安静"，焦点回到金额和流水。
          color: brand.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(color: brand.withValues(alpha: 0.28)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, color: brand, size: 18),
            const SizedBox(width: 6),
            Text('添加一条新记账',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: brand)),
          ],
        ),
      ),
    );
  }
}

/// 首页空状态：线描插画 + 引导（替代原来的图标型 EmptyView）。
class _EmptyHome extends StatelessWidget {
  const _EmptyHome({
    required this.onAction,
    this.title = '这个月还没有记录',
    this.subtitle = '记一笔，看看钱花在哪了',
    this.icon,
  });

  final VoidCallback onAction;
  final String title;
  final String subtitle;

  /// 给了就用它替代默认插画（「只有转账」这种场景用插画说不清楚）。
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          if (icon == null)
            const EmptyIllustration(kind: EmptyKind.paper, size: 76)
          else
            Icon(icon, size: 48, color: Palette.inkFaint(context)),
          const SizedBox(height: 10),
          Text(title,
              style: TextStyle(fontSize: 14, color: Palette.inkSoft(context))),
          const SizedBox(height: 4),
          Text(subtitle,
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          const SizedBox(height: 12),
          PressScale(
            scale: 0.96,
            onTap: onAction,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
              decoration: BoxDecoration(
                color: Palette.brand(context).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Palette.brand(context)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 16, color: Palette.brand(context)),
                  const SizedBox(width: 4),
                  Text(icon == null ? '记第一笔' : '记一笔',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Palette.brand(context))),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 首页主封面：用户自己的照片 + 压暗遮罩。
///
/// 三个必须做对的点：
/// 1. **视差**：图片按 scroll 反方向位移 30%，比整块跟着滚更有层次。
///    位移再大会把图推出裁剪区，露出底色。
/// 2. **压暗**：白字压在照片上，没有遮罩在浅色照片上就是一片糊。
///    顶部 0.55 → 底部 0.28 的黑色渐变，既保对比度又不至于把图压死。
/// 3. **容错**：封面文件可能被用户手动删掉、或恢复备份后丢失，
///    errorBuilder 静默降级成空，顶栏自动退回纸色。
class _CoverBackdrop extends StatelessWidget {
  const _CoverBackdrop({
    required this.path,
    required this.shrinkOffset,
    required this.luminance,
  });

  final String path;
  final double shrinkOffset;

  /// 封面平均亮度（0~1）
  final double luminance;

  @override
  Widget build(BuildContext context) {
    // 遮罩强度按图片亮度自适应。
    //
    // 第一版写死 55%，真机上拿一张「黑底白字」的海报当封面，白字照样透出来、
    // 年月大字糊成一片 —— 因为深色底上的白字对比度极高，55% 根本压不住。
    // 现在：亮图（lum→1）压到 80%/60%，暗图（lum→0）只压 45%/30%，
    // 保证任何照片下白字的对比度都在可用范围。
    final lum = luminance.isNaN ? 0.5 : luminance.clamp(0.0, 1.0);
    // ⚠️ 别再用「平均亮度决定压多少」——这张海报是黑底白字，
    // 平均亮度只有 0.26（被判成暗图、压得轻），但局部白字对比度极高，
    // 恰恰是最坏情况。平均亮度描述不了局部对比度。
    // 所以改成给一个**保底下限**：任何图至少压 70%，亮图再加到 80%。
    // 宁可照片暗一点，也不能让「2026 年 10 月」看不清。
    final topAlpha = 0.70 + 0.10 * lum;
    final midAlpha = 0.55 + 0.10 * lum;

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Transform.translate(
            offset: Offset(0, shrinkOffset * 0.30),
            child: Image.file(
              File(path),
              fit: BoxFit.cover,
              alignment: Alignment.center,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.fromRGBO(0, 0, 0, topAlpha),
                  Color.fromRGBO(0, 0, 0, midAlpha),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------- 语音记账悬浮按钮

/// 底栏是悬浮胶囊：高 54、底部最小内边距 8（见 shell.dart 的 _BottomBar）。
/// 首页 `extendBody: true`，所以这颗按钮必须坐在底栏**上方**，并且要按系统
/// 手势条 / 三键导航的高度一起抬升，否则在部分机型上会被底栏压住。
const double _kBottomBarHeight = 54;
const double _kBottomBarInset = 8;
const double _kVoiceFabGap = 14;

/// 底栏上沿距屏幕底部的距离。
double _bottomBarTopInset(BuildContext context) {
  final sys = MediaQuery.of(context).padding.bottom;
  return _kBottomBarHeight +
      (sys > _kBottomBarInset ? sys : _kBottomBarInset);
}

/// 语音按钮下边缘距屏幕底部：底栏上沿再留一点呼吸空间。
double voiceFabBottom(BuildContext context) =>
    _bottomBarTopInset(context) + _kVoiceFabGap;

/// 列表尾部留白：滚到底时最后一笔流水要能完整露在按钮上方，
/// 不能出现「被悬浮层压住、又滚不出去」的内容。
double voiceFabClearance(BuildContext context) =>
    voiceFabBottom(context) + VoiceFab.size + 12;

/// 打开记账页并处理「删除 → 撤销」结果（软删除恢复）。
Future<void> openEntryEditor(
  BuildContext context,
  WidgetRef ref, {
  Entry? existing,
}) async {
  final result = await Navigator.of(context).push<Object?>(
    AppPageRoute(page: EntryEditorPage(existing: existing)),
  );
  if (!context.mounted) return;
  if (result is EditorSheetResult && result.deletedId != null) {
    _offerUndoDelete(context, ref, result.deletedId!);
  }
}

/// 显示「已移入回收站 [撤销]」，5 秒内可恢复。
void _offerUndoDelete(BuildContext context, WidgetRef ref, int entryId) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    content: const Text('已移入回收站'),
    duration: const Duration(seconds: 5),
    action: SnackBarAction(
      label: '撤销',
      onPressed: () async {
        final store = await ref.read(storeProvider.future);
        await store.restoreEntry(entryId);
        bumpRevision(ref);
      },
    ),
  ));
}
