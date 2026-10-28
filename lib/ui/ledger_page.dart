import 'app_glyph.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/aggregate.dart';
import '../core/home_modules.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../services/icon_service.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'book_manage_page.dart';
import 'report_page.dart';
import 'boot_reveal.dart';
import 'budget_page.dart';
import 'common.dart';
import 'editor_page.dart';
import 'wheel_date_picker.dart';
import 'export_page.dart';
import 'glass.dart';
import 'illustrations.dart';
import 'motion.dart';
import 'pull_to_add.dart';
import 'search_page.dart';
import 'theme.dart';

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

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(monthProvider);
    final entriesAsync = ref.watch(entriesProvider);
    final totalsAsync = ref.watch(totalsProvider);
    final bookAsync = ref.watch(activeBookProvider);
    // 用「本期可用」（含上月结转），否则顶部"还能花多少"会和预算页对不上
    final budget = ref.watch(effectiveBudgetProvider).valueOrNull ?? 0;
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
    int toBaseOf(Entry e) => toBaseCents(
          e.amountCents,
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
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
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
                      ),
                      2,
                    ),
                    if (visibleNow.isEmpty)
                      BootRevealItem(
                        index: 6,
                        child: _EmptyHome(
                          onAction: () => openEntryEditor(context, ref),
                        ),
                      )
                    else
                      // 流水从模块后面接着排（序号封顶见
                      // BootRevealTimeline.maxIndex，20 组的月份也不会排到天边）。
                      ..._stagger(
                        _buildGroups(context, visibleNow, toBaseOf),
                        2 + settings.modulesVisible.length,
                      ),
                  ]),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (!_batch) return body;
    // 批量操作条压在底部：首页是 tab body，拿不到 Scaffold 的 bottomNavigationBar，
    // 用 Stack 叠一层最省事，也不会让列表被挤压重排。
    return Stack(
      children: [
        Positioned.fill(child: body),
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
    _toast('已移入回收站 $count 条');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
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
          out.add(_BudgetHintCard(budgetCents: budget));
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
      final day = list.first.day;
      // 转账不算收支，「不计入收支」的笔也不算
      final net = list.fold<int>(0, (sum, e) {
        if (e.isTransfer || e.excludeFromStats) return sum;
        final cents = toBase(e);
        return sum + (e.flow == 'in' ? cents : -cents);
      });
      final delay = Duration(milliseconds: (40 * gi).clamp(0, 240));
      widgets.add(Reveal(
        delay: delay,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 6, left: 2),
              child: Row(
                children: [
                  Text('${day.month} 月 ${day.day} 日',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Palette.inkSoft(context))),
                  Text(' · ${_weekday(day)}',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkFaint(context))),
                  const Spacer(),
                  MoneyText(net,
                      flow: net >= 0 ? 'in' : 'out',
                      // 与下面流水行一致：列表里的数字不带币种符号。
                      // 顶部「本月支出」大卡保留 ¥（那是主角汇总）。
                      showSymbol: false,
                      style: TextStyle(
                          fontSize: 12,
                          color: Palette.inkFaint(context),
                          fontFeatures: const [FontFeature.tabularFigures()])),
                ],
              ),
            ),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < list.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 56),
                    EntryRow(
                      entry: list[i],
                      // 非 null = 显示勾选框
                      selected:
                          _batch ? _selected.contains(list[i].id) : null,
                      onLongPress: () => _toggleEntry(list[i]),
                      // 批量模式下点行 = 勾选/取消；否则进编辑页（EntryRow 内部默认）
                      onTap: _batch ? () => _toggleEntry(list[i]) : null,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ));
    }
    return widgets;
  }

  static String _weekday(DateTime d) =>
      const ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][d.weekday - 1];
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
        child: Panel(
          child: Row(
            children: [
              Icon(Icons.auto_graph_rounded,
                  size: 18, color: Palette.brand(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 13, color: Palette.ink(context)),
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
              TextButton(
                onPressed: () => Navigator.of(context)
                    .push(AppPageRoute(page: const ReportPage())),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('查看', style: TextStyle(fontSize: 12)),
              ),
            ],
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

  /// 2026-10-26：顶栏瘦成**一行不折叠**的「账本 + 三个图标」。
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


/// 上月报告卡：看本月时提示上月收支，点「查看」直接切到上个月。
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
    final series = ref.watch(monthSeriesProvider(2)).valueOrNull;
    if (series == null || series.length < 2) return const SizedBox.shrink();
    final prev = series[0];
    if (prev.incomeCents == 0 && prev.expenseCents == 0) {
      return const SizedBox.shrink();
    }
    final prevMonth = DateTime(month.year, month.month - 1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Reveal(
        child: Panel(
          child: Row(
            children: [
              Icon(Icons.auto_awesome, size: 18, color: Palette.brand(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 13, color: Palette.ink(context)),
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
              TextButton(
                onPressed: () => ref.read(monthProvider.notifier).state =
                    shiftMonth(month, -1),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('查看', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 预算引导卡：没设预算时给一个直达入口，可关掉。
class _BudgetHintCard extends StatefulWidget {
  const _BudgetHintCard({required this.budgetCents});

  final int budgetCents;

  @override
  State<_BudgetHintCard> createState() => _BudgetHintCardState();
}

class _BudgetHintCardState extends State<_BudgetHintCard> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (widget.budgetCents > 0 || _dismissed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Reveal(
        delay: const Duration(milliseconds: 40),
        child: Panel(
          child: Row(
            children: [
              Icon(Icons.pie_chart_outline,
                  size: 18, color: Palette.brand(context)),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('设个月度预算，超支前会提醒你', style: TextStyle(fontSize: 13)),
              ),
              TextButton(
                onPressed: () => Navigator.of(context)
                    .push(AppPageRoute(page: const BudgetPage())),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('去设置', style: TextStyle(fontSize: 12)),
              ),
              IconButton(
                tooltip: '不再提示',
                onPressed: () => setState(() => _dismissed = true),
                icon: Icon(Icons.close,
                    size: 18, color: Palette.inkFaint(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 备份提醒：从没导出过 / 太久没导出，就在首页给一条提示条。
///
/// 阈值取 7 天是按「丢数据的容忍窗口」拍的：超过一周没备份，
/// 手机一坏丢的就是一周的账。刚备份过就完全不出现 —— 天天弹等于没有，
/// 用户会把它当成装饰而不是提醒。本次会话可以关掉（不落盘：
/// 下个冷启动该提醒还是提醒，因为它本来就不是一次性的事）。
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
    final days = ref.watch(settingsProvider.select((s) => s.daysSinceBackup));
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
    if (_dismissed) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Reveal(
        delay: const Duration(milliseconds: 40),
        child: Panel(
          child: Row(
            children: [
              Icon(Icons.backup_outlined,
                  size: 18, color: Palette.brand(context)),
              const SizedBox(width: 10),
              Expanded(
                  child: Text(text, style: const TextStyle(fontSize: 13))),
              TextButton(
                onPressed: () => Navigator.of(context)
                    .push(AppPageRoute(page: const ExportPage())),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  minimumSize: const Size(0, 0),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('去备份', style: TextStyle(fontSize: 12)),
              ),
              IconButton(
                tooltip: '本次不再提示',
                onPressed: () => setState(() => _dismissed = true),
                icon: Icon(Icons.close,
                    size: 18, color: Palette.inkFaint(context)),
              ),
            ],
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
  });

  final Entry entry;

  /// 自定义点击行为（搜索页批量模式用）；为空则进编辑页
  final VoidCallback? onTap;

  /// 长按（首页流水进入批量选择用）；为空则不接管
  final VoidCallback? onLongPress;

  /// 非空 = 选择模式，行前显示勾选框
  final bool? selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 必须含归档分类：归档 ≠ 删除，否则一归档全部旧账都显示「未分类」
    final allBuckets =
        ref.watch(allBucketsProvider).valueOrNull ?? const <Bucket>[];
    Bucket? bucket;
    for (final b in allBuckets) {
      if (b.id == entry.bucketId) {
        bucket = b;
        break;
      }
    }
    final allPockets =
        ref.watch(allPocketsProvider).valueOrNull ?? const <Pocket>[];
    Pocket? fromPocket;
    Pocket? toPocket;
    for (final p in allPockets) {
      if (p.id == entry.pocketId) fromPocket = p;
      if (p.id == entry.toPocketId) toPocket = p;
    }
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
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
            // 自定义图片图标：铺满正方形、不要灰底（对齐参考图）。
            // emoji / 默认图标仍放浅灰圆角盒里 —— 单个 emoji 悬空更难看。
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
                  color: Palette.hairline(context).withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: AppGlyph(glyph, size: 18),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: Palette.ink(context))),
                      ),
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
                      padding: const EdgeInsets.only(top: 2),
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

/// 首页汇总大卡：山水插画背景 + 本月支出大字 + 收入 / 结余。
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
    return Panel(
      padding: EdgeInsets.zero,
      child: HillCardBackground(
        opacity: 0.07,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('本月支出',
                      style: TextStyle(
                          fontSize: 13, color: Palette.inkSoft(context))),
                  const Spacer(),
                  if (budgetCents > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Palette.brand(context).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '预算 ${settings.symbol}${centsToText(budgetCents)}',
                        style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: Palette.brand(context)),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpace.xs),
              MoneyText(
                expenseCents,
                flow: 'out',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: Palette.expense,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _mini(context, '收入', incomeCents, Palette.income),
                  _mini(
                      context,
                      '结余',
                      net,
                      net >= 0 ? Palette.brand(context) : Palette.expense),
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
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
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
          color: brand,
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.add, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text('添加一条新记账',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Colors.white)),
          ],
        ),
      ),
    );
  }
}

/// 首页空状态：线描插画 + 引导（替代原来的图标型 EmptyView）。
class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.onAction});

  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          const EmptyIllustration(kind: EmptyKind.paper, size: 76),
          const SizedBox(height: 10),
          Text('这个月还没有记录',
              style: TextStyle(fontSize: 14, color: Palette.inkSoft(context))),
          const SizedBox(height: 4),
          Text('记一笔，看看钱花在哪了',
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
                  Text('记第一笔',
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
