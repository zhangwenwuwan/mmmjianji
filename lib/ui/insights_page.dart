import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/aggregate.dart';
import '../data/store.dart';
import '../core/rules.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'budget_page.dart';
import 'category_detail_page.dart';
import 'charts.dart';
import 'common.dart';
import 'glass.dart';
import 'liquid_surface.dart';
import 'motion.dart';
import 'sankey.dart';
import 'tab_header.dart';
import 'theme.dart';
import 'wheel_date_picker.dart';

/// 洞察：这个月的钱去哪了、预算还剩多少、趋势怎么走。
///
/// 顶部两组胶囊切换（对齐参考版）：口径「支出 / 收入 / 结余」，
/// 范围「本月 / 本年 / 全部」。切到「本年 / 全部」时月份切换器让位给区间标题。
class InsightsPage extends ConsumerStatefulWidget {
  const InsightsPage({super.key});

  @override
  ConsumerState<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends ConsumerState<InsightsPage> {
  /// 顶部筛选块滚过去之后，在顶栏下面浮一条精简版。
  /// 用 ValueNotifier 而不是 setState：只在跨过阈值时翻一次，
  /// 不必每帧重建整页（统计页一屏里有图表，重建代价不低）。
  final _compact = ValueNotifier<bool>(false);

  /// 筛选块的高度（分段 + 区间 + 胶囊三行，约 108）。滚过它就把精简条亮出来。
  static const _filterBlockHeight = 108.0;

  @override
  void dispose() {
    _compact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 「本月」= 首页/预算页那个月（预算卡要它，不能跟着统计页翻）。
    final month = ref.watch(monthProvider);
    // 统计页自己的锚点：带日，因为「周」要知道是哪个星期。
    final anchor = ref.watch(insightAnchorProvider);
    final settings = ref.watch(settingsProvider);
    final scope = ref.watch(insightScopeProvider);
    final customRange = ref.watch(insightCustomRangeProvider);
    final range = insightRange(scope, anchor, custom: customRange);
    final type = ref.watch(insightTypeProvider);
    final totals = ref.watch(insightTotalsProvider).valueOrNull ??
        (incomeCents: 0, expenseCents: 0);
    final slicesAsync = ref.watch(insightSlicesProvider);
    final budget = ref.watch(effectiveBudgetProvider).valueOrNull ?? 0;
    // 预算卡是「本月预算」，必须用当月合计。
    // 切到「本年 / 全部」时 totals 是全年数，塞进本月预算会显示
    // 「已超支 ¥33000、进度 100%」。
    final monthTotals = ref.watch(totalsProvider).valueOrNull ??
        (incomeCents: 0, expenseCents: 0);

    final progress = buildBudgetProgress(
      budgetCents: budget,
      spentCents: monthTotals.expenseCents,
      month: month,
      today: DateTime.now(),
    );

    final isBalance = type == InsightType.balance;

    // 整页一起滚（2026-10-28），但多了一条「精简筛选条」：
    // 顶部三行（周/月/年、区间、支出/收入/结余）滚出去之后，顶栏下面会浮出
    // 一条 46 高的精简版 —— 只剩当前粒度和三个口径胶囊。这样既能整页滚，
    // 又不用为了切「年」先滚回顶部。
    //
    // 为什么用 Stack 叠一条而不是 SliverPersistentHeader：
    // 顶栏（TabHeader）本身浮在内容上，pinned sliver 会停在 y=0 被它盖住；
    // 叠一层才能精确落在「顶栏下沿」。
    final headerH = TabHeader.heightOf(context);
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            final v = n.metrics.pixels > _filterBlockHeight - 24;
            if (_compact.value != v) _compact.value = v;
            return false;
          },
          child: CustomScrollView(
            slivers: [
              // 筛选块：跟着滚，滚出去就不回来（精简条接手）
              SliverPadding(
                padding: EdgeInsets.fromLTRB(12, headerH + 8, 12, 0),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    children: [
                      // 周期粒度：周 / 月 / 年 / 全部 / 范围
                      _ScopeSegments(
                        scope: scope,
                        onChanged: (s) => _setScope(ref, s),
                      ),
                      // 区间：2026/10/20  ~  2026/10/26
                      // 周/月/年：右端只读（是算出来的区间末），左端点开改锚点；
                      // 范围：两端都能点；全部：没有端点可选。
                      Padding(
                        padding: const EdgeInsets.fromLTRB(6, 12, 6, 0),
                        child: _RangeLine(
                          scope: scope,
                          range: range,
                          onFrom: () => _pickStart(context, ref),
                          onTo: scope == InsightScope.custom
                              ? () => _pickEnd(context, ref)
                              : null,
                          // 上一段 / 下一段：以前翻月要「点日期 → 滚轮滚到目标月
                          // → 确定」三步，日历页一个 ‹ › 就够。自定义范围不平移。
                          onPrev: scope == InsightScope.custom
                              ? null
                              : () => _shift(context, ref, -1),
                          onNext: scope == InsightScope.custom
                              ? null
                              : () => _shift(context, ref, 1),
                        ),
                      ),
                      // 口径：支出 / 收入 / 结余
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _CapsuleRow(
                          children: [
                            // 切口径时把底部的「近 6 个月」趋势图也带上：
                            // 以前切到收入，环形图/排行都变了，往下滑撞见一张
                            // 支出柱状图，还得在那边再点一次。
                            _Capsule(
                              label: '支出',
                              selected: type == InsightType.expense,
                              onTap: () {
                                ref.read(insightTypeProvider.notifier).state =
                                    InsightType.expense;
                                ref.read(trendModeProvider.notifier).state =
                                    TrendMode.expense;
                              },
                            ),
                            _Capsule(
                              label: '收入',
                              selected: type == InsightType.income,
                              onTap: () {
                                ref.read(insightTypeProvider.notifier).state =
                                    InsightType.income;
                                ref.read(trendModeProvider.notifier).state =
                                    TrendMode.income;
                              },
                            ),
                            _Capsule(
                              label: '结余',
                              selected: isBalance,
                              onTap: () {
                                ref.read(insightTypeProvider.notifier).state =
                                    InsightType.balance;
                                ref.read(trendModeProvider.notifier).state =
                                    TrendMode.net;
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 88),
                sliver: SliverList(
                  delegate: SliverChildListDelegate([
                  // 收支总览（和明细页汇总卡同一套品牌色淡渐变，视觉统一）
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Palette.brand(context).withValues(alpha: 0.11),
                          Palette.brand(context).withValues(alpha: 0.03),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(
                          color: Palette.brand(context).withValues(alpha: 0.20)),
                    ),
                    child: Row(
                      children: [
                        _cell(context, '收入', totals.incomeCents, Palette.income,
                            'in'),
                        _div(context),
                        _cell(context, '支出', totals.expenseCents, Palette.expense,
                            'out'),
                        _div(context),
                        _cell(
                            context,
                            '结余',
                            totals.incomeCents - totals.expenseCents,
                            Palette.brand(context),
                            null),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),

                  // 分类占比 / 净额
                  Panel(
                    child: isBalance
                        ? _netView(context, settings, totals)
                        : slicesAsync.when(
                            skipLoadingOnReload: true,
                            loading: () => const Padding(
                              padding: EdgeInsets.symmetric(vertical: 10),
                              child: Row(
                                children: [
                                  Skeleton(width: 148, height: 148, radius: 74),
                                  SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      children: [
                                        Skeleton(height: 16, radius: 6),
                                        SizedBox(height: 12),
                                        Skeleton(height: 16, radius: 6),
                                        SizedBox(height: 12),
                                        Skeleton(height: 16, radius: 6),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            error: (e, _) => ErrorRetryView(
                              message: '统计失败',
                              detail: '$e',
                              onRetry: () async =>
                                  ref.invalidate(insightSlicesProvider),
                            ),
                            data: (slices) {
                              if (slices.isEmpty) {
                                return SizedBox(
                                  height: 96,
                                  child: Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.donut_large,
                                            size: 26,
                                            color: Palette.inkFaint(context)),
                                        const SizedBox(height: 6),
                                        Text('这个区间还没有${_flowName(type)}',
                                            style: TextStyle(
                                                fontSize: 12,
                                                color: Palette.inkFaint(context))),
                                      ],
                                    ),
                                  ),
                                );
                              }
                              final totalCents = type == InsightType.income
                                  ? totals.incomeCents
                                  : totals.expenseCents;
                              final showAmount = ref.watch(donutShowAmountProvider);
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      DonutChart(
                                        slices: slices,
                                        totalCents: totalCents,
                                        symbol: settings.symbol,
                                        hideAmounts: settings.hideAmounts,
                                        centerTitle: _flowName(type),
                                      ),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            for (var i = 0; i < slices.length; i++)
                                              _legendRow(
                                                  context, slices[i], totalCents, i,
                                                  symbol: settings.symbol,
                                                  hide: settings.hideAmounts,
                                                  showAmount: showAmount),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  // 「只显示金额」：一木把这个开关放在环形图右下角
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: _AmountOnlyToggle(
                                      value: showAmount,
                                      onChanged: (v) => ref
                                          .read(donutShowAmountProvider.notifier)
                                          .state = v,
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 14),

                  // 钱从哪来、到哪去（桑基图）：
                  // 环形图回答「支出由什么构成」，这张图回答「进来多少、出去多少、
                  // 剩多少」—— 两个问题不一样，缺一张就总觉得账看不透。
                  const SankeyPanel(),
                  const SizedBox(height: 14),

                  // 分类排行（对齐原版 category_rank_row：一行一个分类，可展开子分类）
                  if (!isBalance)
                    Panel(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                      child: _RankList(
                        symbol: settings.symbol,
                        hide: settings.hideAmounts,
                        type: type,
                      ),
                    ),
                  if (!isBalance) const SizedBox(height: 14),

                  // 与上一段对比。
                  // 月粒度走「上月 1 日 ~ 同一天」的同期比（上月整月对本月半个月是假的）；
                  // 周 / 年 / 自定义改成和「上一个等长区间」比 ——
                  // 以前这些粒度整张卡都不显示，页面上没有任何参照。
                  // 「全部」没有上一段，不显示。
                  if (!isBalance && scope != InsightScope.all) ...[
                    Panel(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                      child: _PrevComparePanel(
                        symbol: settings.symbol,
                        hide: settings.hideAmounts,
                        type: type,
                        scope: scope,
                        range: range,
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],

                  // 净资产走势：只在**资产页**保留（资产页那张是主视角）。
                  // 2026-10-28 用户反馈统计页与资产页两张图重复，统计页这里删掉。

                  // 标签占比 / 账户收支：对齐一木统计页的另外两个维度。
                  // 放在分类排行之后——分类是主视角，这两个是补充视角。
                  if (!isBalance) ...[
                    _TagRankPanel(
                        symbol: settings.symbol, hide: settings.hideAmounts),
                    const SizedBox(height: 14),
                    _PocketSplitPanel(
                        symbol: settings.symbol, hide: settings.hideAmounts),
                    const SizedBox(height: 14),
                  ],

                  // 预算：预算是按月设的，只有「月」粒度说得通。
                  // 以前在「本年 / 全部 / 自定义」下也插一张「本月预算」卡，
                  // 和上下文不是一条时间轴，看着像忘了更新。
                  if (scope == InsightScope.month) ...[
                    Panel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text('本月预算',
                                style: TextStyle(
                                    fontSize: 12, color: Palette.inkSoft(context))),
                            const Spacer(),
                            HeaderAction(
                              label: '管理',
                              onPressed: () => Navigator.of(context)
                                  .push(AppPageRoute(page: const BudgetPage())),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (!progress.configured)
                          Text('还没设预算，点右上「管理」设一个',
                              style: TextStyle(
                                  fontSize: 12, color: Palette.inkFaint(context)))
                        else ...[
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Flexible(
                                child: Text(
                                  '${settings.symbol}${centsToText(progress.remainCents.abs())}',
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: progress.overflow
                                        ? Palette.expense
                                        : Palette.ink(context),
                                    fontFeatures: const [
                                      FontFeature.tabularFigures()
                                    ],
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4, left: 6),
                                child: Text(progress.overflow ? '已超支' : '还能花',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Palette.inkSoft(context))),
                              ),
                              const Spacer(),
                              if (progress.daysLeft > 0)
                                Text(
                                    '每天约 ${settings.symbol}${centsToText(progress.safeDailyCents)}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Palette.inkFaint(context))),
                            ],
                          ),
                          const SizedBox(height: 10),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: LinearProgressIndicator(
                              value: progress.ratio,
                              minHeight: 8,
                              backgroundColor: Palette.hairline(context),
                              valueColor: AlwaysStoppedAnimation(progress.overflow
                                  ? Palette.expense
                                  : Palette.brand(context)),
                            ),
                          ),
                        ],
                      ],
                    ),
                    ),
                    const SizedBox(height: 10),
                  ],

                  // 本月总结（手写）：全是一堆数字太冷，给用户一个回看/留话的地方
                  if (scope == InsightScope.month)
                    _MonthNoteCard(month: anchor),
                  const SizedBox(height: 10),

                  // 外币折算脚注（对齐原版 _buildConvertedFootnote）：
                  // 账本里有非主币种账户时，说明统计口径，避免用户以为算错
                  if (_hasForeign(context, ref))
                    Padding(
                      padding: const EdgeInsets.only(top: 2, bottom: 10),
                      child: Text(
                        '含外币账户，金额已按当前汇率折算为主币种统计',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 10.5, color: Palette.inkFaint(context)),
                      ),
                    ),

                  // 趋势
                  Panel(
                    child:
                        _Trend(symbol: settings.symbol, hide: settings.hideAmounts),
                  ),
                  const SizedBox(height: 14),
                  Center(
                    child: Text('更多分析工具在「我的 → 财务洞察」',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                  ),
                  ]),
                ),
              ),
            ],
          ),
        ),
        // 精简筛选条：只在筛选块滚出去后出现，浮在顶栏下沿
        Positioned(
          top: headerH,
          left: 0,
          right: 0,
          child: ValueListenableBuilder<bool>(
            valueListenable: _compact,
            builder: (c, on, _) => IgnorePointer(
              ignoring: !on,
              child: AnimatedOpacity(
                opacity: on ? 1 : 0,
                duration: const Duration(milliseconds: 160),
                child: _CompactFilterBar(
                  onOpenScope: () => _pickScopeSheet(context, ref),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 账本里是否存在非主币种账户（决定要不要显示折算脚注）
  static bool _hasForeign(BuildContext context, WidgetRef ref) {
    final base =
        ref.watch(activeBookProvider).valueOrNull?.baseCurrency ?? 'CNY';
    final pockets =
        ref.watch(allPocketsProvider).valueOrNull ?? const <Pocket>[];
    return pockets.any((p) => p.currency != base);
  }

  /// 周期的中文名。精简筛选条和选择面板都要用。
  static String _scopeName(InsightScope s) => switch (s) {
        InsightScope.week => '周',
        InsightScope.month => '月',
        InsightScope.year => '年',
        InsightScope.all => '全部',
        InsightScope.custom => '自定义范围',
      };

  /// 精简条上点「月 ⌄」：弹一个五选一的面板。
  ///
  /// 为什么不做成点一下切下一个：五个粒度循环切是"瞎猜"，用户不知道
  /// 还要点几下才到「年」；列出来一眼就能挑。
  static Future<void> _pickScopeSheet(
      BuildContext context, WidgetRef ref) async {
    final current = ref.read(insightScopeProvider);
    final picked = await showAppSheet<InsightScope>(
      context: context,
      title: '统计周期',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in InsightScope.values)
            ListTile(
              title: Text(_scopeName(s)),
              trailing: s == current
                  ? Icon(Icons.check, size: 18, color: Palette.brand(ctx))
                  : null,
              onTap: () => Navigator.of(ctx).pop(s),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
    if (picked != null) _setScope(ref, picked);
  }

  // ------------------------------------------------------------ 周期与区间

  /// 切周期粒度。
  ///
  /// 「周」要单独摆锚点：从月/年切过来时锚点是某月 1 号，直接拿去算周会变成
  /// 「当月第一周」——用户点「周」看到的是上个月的尾巴，会以为坏了。
  /// 周的心智默认就是本周，所以切过来直接落到今天。
  static void _setScope(WidgetRef ref, InsightScope s) {
    if (ref.read(insightScopeProvider) == s) return;
    ref.read(insightScopeProvider.notifier).state = s;
    switch (s) {
      case InsightScope.week:
        ref.read(insightAnchorProvider.notifier).state = DateTime.now();
      case InsightScope.custom:
        // 没选过范围时先给「当月」，别让区间行空着（空着看着像坏了）
        if (ref.read(insightCustomRangeProvider) == null) {
          final a = ref.read(insightAnchorProvider);
          ref.read(insightCustomRangeProvider.notifier).state = (
            from: DateTime(a.year, a.month, 1),
            to: DateTime(a.year, a.month + 1, 0),
          );
        }
      case InsightScope.month:
      case InsightScope.year:
      case InsightScope.all:
        break;
    }
  }

  /// 点左端日期：按当前粒度挑一个新锚点。
  /// 按当前粒度整段平移（周 -7 天 / 月 ±1 月 / 年 ±1 年）。
  ///
  /// 为什么月要用 `DateTime(y, m+dir, 1)`：anchor 可能停在 31 号，
  /// 直接 `DateTime(y, m+1, 31)` 会滚到下下个月（Dart 会把溢出日归一化）。
  static void _shift(BuildContext context, WidgetRef ref, int dir) {
    final scope = ref.read(insightScopeProvider);
    final a = ref.read(insightAnchorProvider);
    final next = switch (scope) {
      InsightScope.week => a.add(Duration(days: 7 * dir)),
      InsightScope.month => DateTime(a.year, a.month + dir, 1),
      InsightScope.year => DateTime(a.year + dir, a.month, 1),
      // 「全部」没有可平移的边界；自定义由用户自己定
      _ => a,
    };
    if (next == a) return;
    ref.read(insightAnchorProvider.notifier).state = next;
  }

  static Future<void> _pickStart(BuildContext context, WidgetRef ref) async {
    final scope = ref.read(insightScopeProvider);
    final anchor = ref.read(insightAnchorProvider);
    switch (scope) {
      case InsightScope.week:
        // 没有「选周」这种滚轮，让用户点一天，自动对齐到那周的周一
        final d = await pickDateWheel(context, anchor,
            includeDay: true, title: '选择一周（点其中任意一天）');
        if (d == null) return;
        ref.read(insightAnchorProvider.notifier).state = d;
      case InsightScope.month:
        final m = await pickWheelYearMonth(context, anchor);
        if (m == null) return;
        ref.read(insightAnchorProvider.notifier).state = m;
      case InsightScope.year:
        final y = await pickWheelYear(context, anchor.year, title: '选择年份');
        if (y == null) return;
        ref
            .read(insightAnchorProvider.notifier)
            .state = DateTime(y, anchor.month, 1);
      case InsightScope.custom:
        final cur = ref.read(insightCustomRangeProvider);
        final from = await pickDateWheel(context, cur?.from ?? anchor,
            includeDay: true, title: '开始日期');
        if (from == null) return;
        _applyRange(ref, from, cur?.to);
      case InsightScope.all:
        return; // 「全部」没有端点可选
    }
  }

  /// 点右端日期：只有「范围」能改，其余粒度的右端是算出来的区间末。
  static Future<void> _pickEnd(BuildContext context, WidgetRef ref) async {
    final cur = ref.read(insightCustomRangeProvider);
    final to = await pickDateWheel(context, cur?.to ?? DateTime.now(),
        includeDay: true, title: '结束日期');
    if (to == null) return;
    _applyRange(ref, cur?.from, to);
  }

  /// 写入范围，顺手把「开始晚于结束」摆正 —— 否则区间为空、页面静默显示 0，
  /// 用户会以为数据丢了。
  static void _applyRange(WidgetRef ref, DateTime? from, DateTime? to) {
    final DateTime a0 = from ?? ref.read(insightAnchorProvider);
    final DateTime b0 = to ?? DateTime(a0.year, a0.month + 1, 0);
    final DateTime a = a0.isAfter(b0) ? b0 : a0;
    final DateTime b = a0.isAfter(b0) ? a0 : b0;
    ref.read(insightCustomRangeProvider.notifier).state = (from: a, to: b);
    ref.read(insightScopeProvider.notifier).state = InsightScope.custom;
  }

  static String _flowName(InsightType type) => switch (type) {
        InsightType.expense => '支出',
        InsightType.income => '收入',
        InsightType.balance => '结余',
      };

  Widget _netView(BuildContext context, AppSettings settings,
      ({int incomeCents, int expenseCents}) totals) {
    final net = totals.incomeCents - totals.expenseCents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('净收支',
            style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            settings.hideAmounts
                ? '****'
                : '${settings.symbol}${centsToText(net)}',
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: net >= 0 ? Palette.income : Palette.expense,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Flexible(
              child: Text(
                '收入 ${settings.symbol}${centsToText(totals.incomeCents)}',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: Palette.inkFaint(context),
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '支出 ${settings.symbol}${centsToText(totals.expenseCents)}',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: Palette.inkFaint(context),
                    fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _div(BuildContext context) =>
      Container(width: 1, height: 32, color: Palette.hairline(context));

  Widget _cell(BuildContext context, String label, int cents, Color color,
      String? flow) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: MoneyText(
              cents,
              flow: flow,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _legendRow(
    BuildContext context,
    Slice slice,
    int total,
    int i, {
    required String symbol,
    required bool hide,
    required bool showAmount,
  }) {
    final pct = (shareOf(slice.cents, total) * 100).round();
    final trailing = showAmount
        ? (hide ? '****' : '$symbol${centsToText(slice.cents)}')
        : '$pct%';
    return PressScale(
      scale: 0.98,
      // 图例可点：以前整条是死的，而分类排行右边明写着「点分类看明细」，
      // 环形图这一块却没有任何入口。
      onTap: () {
        final buckets = <Bucket>[
          ...?ref.read(bucketsProvider('out')).valueOrNull,
          ...?ref.read(bucketsProvider('in')).valueOrNull,
        ];
        Bucket? target;
        for (final b in buckets) {
          if (b.title == slice.label) target = b;
        }
        if (target == null) {
          ScaffoldMessenger.of(context)
              .toast('「${slice.label}」找不到对应分类（可能已合并）');
          return;
        }
        Navigator.of(context).push(AppPageRoute(
          page: CategoryDetailPage(
            bucket: target,
            range: ref.read(insightRangeProvider),
          ),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                  // 跟环形图/流水行图标同一个分类色，图例才对得上
                  color: Palette.categoryColor(context, slice.label),
                  shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(slice.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Palette.ink(context))),
            ),
            Text(trailing,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Palette.inkSoft(context),
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 2),
            Icon(Icons.chevron_right, size: 14, color: Palette.inkFaint(context)),
          ],
        ),
      ),
    );
  }
}

/// 分类排行：一行一个分类（图标 + 名称 + 占比条 + 金额 + 占比），
/// 有子分类时右侧给展开箭头，展开后子分类缩进显示。
class _RankList extends ConsumerStatefulWidget {
  const _RankList({
    required this.symbol,
    required this.hide,
    required this.type,
  });

  final String symbol;
  final bool hide;
  final InsightType type;

  @override
  ConsumerState<_RankList> createState() => _RankListState();
}

class _RankListState extends ConsumerState<_RankList> {
  final _expanded = <int>{};

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(insightRankProvider);
    return async.when(
      skipLoadingOnReload: true,
      loading: () => Column(
        children: const [
          Skeleton(height: 18, expand: true, radius: 6),
          SizedBox(height: 10),
          Skeleton(height: 18, expand: true, radius: 6),
          SizedBox(height: 10),
          Skeleton(height: 18, expand: true, radius: 6),
        ],
      ),
      error: (e, _) => ErrorRetryView(
        message: '排行读取失败',
        detail: '$e',
        onRetry: () async => ref.invalidate(insightRankProvider),
      ),
      data: (nodes) {
        if (nodes.isEmpty) {
          return Text('这个区间还没有数据，换个范围或口径试试',
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context)));
        }
        final total = nodes.fold<int>(0, (s, n) => s + n.cents);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('分类排行',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context))),
                const Spacer(),
                Text('点分类看明细',
                    style: TextStyle(
                        fontSize: 10.5, color: Palette.inkFaint(context))),
              ],
            ),
            const SizedBox(height: 8),
            for (final n in nodes.take(20)) ...[
              _row(context, n, total, 0),
              if (n.hasChildren && _expanded.contains(n.bucketId))
                for (final c in n.children) _row(context, c, total, 1),
            ],
            // 截断要说出来：以前超过 20 个分类直接消失，用户会以为
            // 统计漏了分类（金额小的那几个确实看不见）。
            if (nodes.length > 20)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('另有 ${nodes.length - 20} 个分类没列出来（金额较小）',
                    style: TextStyle(
                        fontSize: 10.5, color: Palette.inkFaint(context))),
              ),
            const SizedBox(height: 6),
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, RankNode n, int total, int depth) {
    final pct = total <= 0 ? 0.0 : (n.cents / total).clamp(0.0, 1.0);
    final canExpand = depth == 0 && n.hasChildren;
    final isOpen = canExpand && _expanded.contains(n.bucketId);
    return PressScale(
      scale: 0.98,
      onTap: () {
        if (canExpand) {
          setState(() {
            if (isOpen) {
              _expanded.remove(n.bucketId);
            } else {
              _expanded.add(n.bucketId!);
            }
          });
          return;
        }
        // 子分类或没有子分类 → 直接进分类明细
        final buckets = <Bucket>[
          ...?ref.watch(bucketsProvider('out')).valueOrNull,
          ...?ref.watch(bucketsProvider('in')).valueOrNull,
        ];
        Bucket? target;
        for (final b in buckets) {
          if (b.id == n.bucketId) target = b;
        }
        if (target != null) {
          // 带着当前筛选区间进去：以前详情页只看「近 6 个月」的全部流水，
          // 在「本周」点「餐饮 ¥320」进去看到「近 6 个月 ¥5800」，像算错了。
          Navigator.of(context).push(AppPageRoute(
            page: CategoryDetailPage(
              bucket: target,
              range: ref.read(insightRangeProvider),
            ),
          ));
        } else {
          // 分类被删了但历史数据还在排行里，别点了没反应
          ScaffoldMessenger.of(context).toast('这个分类已经删掉了');
        }
      },
      child: Padding(
        padding: EdgeInsets.fromLTRB(depth == 0 ? 0 : 18, 6, 0, 6),
        child: Row(
          children: [
            if (depth > 0)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Icon(Icons.subdirectory_arrow_right,
                    size: 14, color: Palette.inkFaint(context)),
              ),
            AppGlyph(n.glyph, size: depth == 0 ? 14 : 12),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(n.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: depth == 0 ? 13 : 12,
                                color: depth == 0
                                    ? Palette.ink(context)
                                    : Palette.inkSoft(context))),
                      ),
                      Text(
                        widget.hide
                            ? '****'
                            : '${widget.symbol}${centsToText(n.cents)}',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Palette.inkSoft(context),
                            fontFeatures: const [FontFeature.tabularFigures()]),
                      ),
                      const SizedBox(width: 6),
                      SizedBox(
                        width: 30,
                        child: Text('${(pct * 100).round()}%',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                                fontSize: 10.5,
                                color: Palette.inkFaint(context))),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: pct,
                      minHeight: 4,
                      backgroundColor: Palette.hairline(context),
                      valueColor: AlwaysStoppedAnimation(
                        widget.type == InsightType.income
                            ? Palette.income
                            : Palette.expense,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (canExpand)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(isOpen ? Icons.expand_less : Icons.expand_more,
                    size: 16, color: Palette.inkFaint(context)),
              ),
          ],
        ),
      ),
    );
  }
}

/// 胶囊切换行：等分排列，选中项填充主色。
/// 周期粒度分段控件：周 / 月 / 年 / 全部 / 范围。
///
/// 照参考版做的「轨道 + 白色滑块」：未选中透明，选中白底圆角 + 一点投影。
/// 滚过顶部筛选块之后浮在顶栏下面的精简条：
/// 左边是当前周期（点开可改），右边是三个口径胶囊。
///
/// 46 高，玻璃底 —— 它在滚动内容之上，所以必须带模糊 + 一条细底边，
/// 否则快速滚动时上面的数字会透过它和胶囊打架。
class _CompactFilterBar extends ConsumerWidget {
  const _CompactFilterBar({required this.onOpenScope});

  final VoidCallback onOpenScope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(insightScopeProvider);
    final type = ref.watch(insightTypeProvider);
    final brand = Palette.brand(context);
    return Glass(
      // 0.88 而不是默认的 0.66：精简条是「钉住的控制条」，不是装饰性玻璃。
      // 0.66 那版在真机上一滚就能看见下面的区间行「~」透出来，像屏幕脏了一个点。
      tint: (Palette.isDark(context) ? const Color(0xFF151C18) : Colors.white)
          .withValues(alpha: LiquidTokens.tintSheet),
      blur: LiquidTokens.blurBar,
      border: Border(
        bottom: BorderSide(color: Palette.hairline(context), width: 0.5),
      ),
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            const SizedBox(width: 12),
            InkWell(
              onTap: onOpenScope,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _InsightsPageState._scopeName(scope),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: brand,
                      ),
                    ),
                    Icon(Icons.keyboard_arrow_down, size: 18, color: brand),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: _CapsuleRow(
                children: [
                  _Capsule(
                    label: '支出',
                    selected: type == InsightType.expense,
                    onTap: () => ref.read(insightTypeProvider.notifier).state =
                        InsightType.expense,
                  ),
                  _Capsule(
                    label: '收入',
                    selected: type == InsightType.income,
                    onTap: () => ref.read(insightTypeProvider.notifier).state =
                        InsightType.income,
                  ),
                  _Capsule(
                    label: '结余',
                    selected: type == InsightType.balance,
                    onTap: () => ref.read(insightTypeProvider.notifier).state =
                        InsightType.balance,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 9),
          ],
        ),
      ),
    );
  }
}

/// 用 AnimatedContainer 而不是自己算位置：5 段平分，宽度由 Expanded 决定，
/// 动画只动底色，不会出现滑块和文字错位。
class _ScopeSegments extends StatelessWidget {
  const _ScopeSegments({required this.scope, required this.onChanged});

  final InsightScope scope;
  final ValueChanged<InsightScope> onChanged;

  /// 顺序 == 分段顺序（Dart 的 Map 保持插入顺序）
  static const _labels = <InsightScope, String>{
    InsightScope.week: '周',
    InsightScope.month: '月',
    InsightScope.year: '年',
    InsightScope.all: '全部',
    InsightScope.custom: '范围',
  };

  @override
  Widget build(BuildContext context) {
    // 2026-11-08：选中态从「每格各自淡入」改成**一整块水滴滑过去**
    // （和底栏同一条弹簧曲线），并接上公共液态材质（跟手高光/彩边/按压）。
    // LayoutBuilder 只用于量格子宽度；拖拽切分段不做，避免和统计页的
    // 月份横滑手势打架（底栏已经有拖拽了）。
    return LayoutBuilder(builder: (_, constraints) {
      final w = constraints.maxWidth / _labels.length;
      final idx = _labels.keys.toList().indexOf(scope);
      return LiquidSurface(
        radius: 19,
        child: SizedBox(
          height: 38,
          child: Stack(
            children: [
              // 轨道底：原来是外层 Container 的底色，改成 Stack 后要自己画。
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Palette.inkFaint(context).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              AnimatedPositioned(
                // left + width 而不是 left + right：弹簧曲线会超调，
                // 用 right 会算出负宽度（底栏踩过这个断言）。
                duration: Motion.d(context, const Duration(milliseconds: 340)),
                curve: XCurve.spring,
                left: w * idx + 3,
                width: w - 6,
                top: 3,
                height: 32,
                child: Container(
                  decoration: BoxDecoration(
                    color: Palette.card(context),
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.07),
                        blurRadius: 6,
                        offset: const Offset(0, 1),
                      ),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  for (final e in _labels.entries)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onChanged(e.key),
                        child: Center(
                          child: Text(
                            e.value,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: e.key == scope
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: e.key == scope
                                  ? Palette.ink(context)
                                  : Palette.inkSoft(context),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// 区间行：`‹ 2026/10/01 ⌄   ~   2026/10/31 ⌄ ›`
///
/// 箭头只出现在**能点**的一端 —— 周/月/年右端是算出来的区间末，
/// 给它画个下拉箭头等于骗用户去点。
/// 两端的 ‹ › 是按粒度整段平移（-1 周 / -1 月 / -1 年）。
class _RangeLine extends StatelessWidget {
  const _RangeLine({
    required this.scope,
    required this.range,
    this.onFrom,
    this.onTo,
    this.onPrev,
    this.onNext,
  });

  final InsightScope scope;
  final ({DateTime from, DateTime to}) range;
  final VoidCallback? onFrom;
  final VoidCallback? onTo;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  static String _fmt(DateTime d) => '${d.year}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    if (scope == InsightScope.all) {
      return Row(
        children: [
          Text('全部时间',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Palette.ink(context))),
          const SizedBox(width: 8),
          Text('所有历史流水',
              style:
                  TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
        ],
      );
    }
    return Row(
      children: [
        if (onPrev != null) _arrow(context, Icons.chevron_left, onPrev!),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _end(context, range.from, onFrom),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text('~',
              style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Palette.inkFaint(context))),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _end(context, range.to, onTo),
          ),
        ),
        if (onNext != null) _arrow(context, Icons.chevron_right, onNext!),
      ],
    );
  }

  /// 平移一档。32×32 的点击区 + 8 的呼吸位，避免和日期那端的点击互相抢。
  Widget _arrow(BuildContext context, IconData icon, VoidCallback onTap) {
    return PressScale(
      scale: 0.9,
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 32,
        child: Icon(icon, size: 20, color: Palette.inkSoft(context)),
      ),
    );
  }

  Widget _end(BuildContext context, DateTime d, VoidCallback? onTap) {
    final enabled = onTap != null;
    return PressScale(
      scale: 0.96,
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 区间两端各占一半宽度，日期固定 10 个字符。窄屏 + 系统字号放大到
          // 1.3× 时这一行会挤爆（RenderFlex overflowed by 24px），所以让日期
          // 在必要时按比例缩一点，而不是撑破行。
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                _fmt(d),
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  // 不能点的一端压暗，一眼能看出哪个是"算出来的"
                  color:
                      enabled ? Palette.ink(context) : Palette.inkSoft(context),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          if (enabled) ...[
            const SizedBox(width: 1),
            Icon(Icons.keyboard_arrow_down,
                size: 18, color: Palette.inkFaint(context)),
          ],
        ],
      ),
    );
  }
}

class _CapsuleRow extends StatelessWidget {
  const _CapsuleRow({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final c in children) Expanded(child: c),
      ],
    );
  }
}

/// 范围按钮：显示当前范围 + 下拉箭头，点开是底部弹层。
///
/// 存在的理由：范围切换是低频操作，占一排 4 个 chip 不值——
/// 真机反馈"头部标签太多、看着烦"。
class _Capsule extends StatelessWidget {
  const _Capsule({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: PressScale(
        scale: 0.94,
        onTap: onTap,
        child: AnimatedContainer(
          duration: Motion.d(context, Motion.small),
          curve: XCurve.easeOut,
          padding: const EdgeInsets.symmetric(vertical: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected
                ? brand.withValues(alpha: 0.14)
                : Palette.card(context),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? brand : Palette.hairline(context),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? brand : Palette.inkSoft(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// 近 6 个月收支双柱
/// 趋势图看什么：支出 / 收入 / 结余。
///
/// 一木的统计页能切这三种，年度复盘时「只看支出走势」比收支双色柱有用得多。
enum TrendMode { expense, income, net }

/// 趋势图模式（页面级状态，翻页/切区间后仍保留用户的选择）
final trendModeProvider = StateProvider<TrendMode>((ref) => TrendMode.expense);

/// 分类占比图例：true = 显示金额，false = 显示百分比。
///
/// 一木在环形图右下角放了这个开关；看占比时想知道"到底花了多少"很自然，
/// 反过来也成立，所以做成可切而不是二选一。
final donutShowAmountProvider = StateProvider<bool>((ref) => false);

class _Trend extends ConsumerWidget {
  const _Trend({required this.symbol, required this.hide});

  final String symbol;
  final bool hide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(trendModeProvider);
    // 锚点跟着统计页自己的筛选走（以前锁在首页当月，翻到 3 月时这张卡不动）
    final anchor = ref.watch(insightAnchorProvider);
    final async =
        ref.watch(monthSeriesProvider((count: 6, anchor: anchor)));
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Skeleton(height: 78, radius: 6)),
            SizedBox(width: 4),
            Expanded(child: Skeleton(height: 78, radius: 6)),
            SizedBox(width: 4),
            Expanded(child: Skeleton(height: 78, radius: 6)),
            SizedBox(width: 4),
            Expanded(child: Skeleton(height: 78, radius: 6)),
            SizedBox(width: 4),
            Expanded(child: Skeleton(height: 78, radius: 6)),
            SizedBox(width: 4),
            Expanded(child: Skeleton(height: 78, radius: 6)),
          ],
        ),
      ),
      error: (e, _) => ErrorRetryView(
        message: '读取失败',
        detail: '$e',
        onRetry: () async =>
            ref.invalidate(monthSeriesProvider((count: 6, anchor: anchor))),
      ),
      data: (points) {
        int valueOf(p) => switch (mode) {
              TrendMode.expense => p.expenseCents,
              TrendMode.income => p.incomeCents,
              TrendMode.net => p.incomeCents - p.expenseCents,
            };
        // 结余可能是负数，纵轴按绝对值最大者缩放（零轴在中间）
        final maxV = points.fold<int>(0, (m, p) {
          final v = valueOf(p).abs();
          return v > m ? v : m;
        });
        // 空态：以前 maxV==0 会画 6 根 2dp 的平柱 + 月份数字，
        // 看着像渲染失败（资产页的净资产图早就有兜底文案，这里没有）。
        if (maxV == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('近 6 个月',
                  style:
                      TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
              const SizedBox(height: 10),
              Container(
                height: 72,
                alignment: Alignment.center,
                child: Text(
                  mode == TrendMode.net
                      ? '这 6 个月还没有收支'
                      : '这 6 个月还没有${mode == TrendMode.expense ? '支出' : '收入'}',
                  style: TextStyle(fontSize: 12, color: Palette.inkFaint(context)),
                ),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('近 6 个月',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context))),
                const Spacer(),
                for (final m in TrendMode.values)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: _ModeChip(
                      label: switch (m) {
                        TrendMode.expense => '支出',
                        TrendMode.income => '收入',
                        TrendMode.net => '结余',
                      },
                      selected: mode == m,
                      color: switch (m) {
                        TrendMode.expense => Palette.expense,
                        TrendMode.income => Palette.income,
                        TrendMode.net => Palette.brand(context),
                      },
                      onTap: () =>
                          ref.read(trendModeProvider.notifier).state = m,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 96,
              child: Row(
                crossAxisAlignment: mode == TrendMode.net
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.end,
                children: [
                  for (final p in points)
                    Expanded(
                      child: Column(
                        mainAxisAlignment: mode == TrendMode.net
                            ? MainAxisAlignment.center
                            : MainAxisAlignment.end,
                        children: [
                          if (mode == TrendMode.net)
                            _netBars(context, valueOf(p), maxV)
                          else
                            _bar(valueOf(p), maxV, _colorOf(context, mode)),
                          const SizedBox(height: 4),
                          Text('${p.month.month}',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: Palette.inkFaint(context))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static Color _colorOf(BuildContext context, TrendMode mode) => switch (mode) {
        TrendMode.expense => Palette.expense,
        TrendMode.income => Palette.income,
        TrendMode.net => Palette.brand(context),
      };

  /// 结余：零轴在中间，正向上（品牌色偏绿）、负向下（支出红）。
  Widget _netBars(BuildContext context, int cents, int maxAbs) {
    const half = 34.0;
    final h = maxAbs == 0
        ? 2.0
        : (cents.abs() / maxAbs * half).clamp(2.0, half).toDouble();
    final positive = cents >= 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: half,
          child: Align(
            alignment: Alignment.bottomCenter,
            child: positive
                ? _box(h, Palette.income.withValues(alpha: 0.85))
                : null,
          ),
        ),
        Container(height: 1, width: 14, color: Palette.hairline(context)),
        SizedBox(
          height: half,
          child: Align(
            alignment: Alignment.topCenter,
            child: positive
                ? null
                : _box(h, Palette.expense.withValues(alpha: 0.85)),
          ),
        ),
      ],
    );
  }

  Widget _box(double h, Color color) => Container(
        width: 12,
        height: h,
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
      );

  Widget _bar(int cents, int maxV, Color color) {
    final h = maxV == 0 ? 2.0 : (cents / maxV * 62).clamp(2.0, 62).toDouble();
    return Container(
      width: 12,
      height: h,
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(2)),
    );
  }
}

/// 「只显示金额」小开关（对齐一木环形图右下角的 checkbox）
class _AmountOnlyToggle extends StatelessWidget {
  const _AmountOnlyToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 4),
            Text('只显示金额',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
          ],
        ),
      ),
    );
  }
}

/// 趋势图上的小模式胶囊
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.94,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border:
              Border.all(color: selected ? color : Palette.hairline(context)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? color : Palette.inkSoft(context),
          ),
        ),
      ),
    );
  }
}

/// 通用小排行：标题 + 若干行（标签 / 金额 + 细比例条）。
///
/// 比例条的基准取**最大项**而不是总和：标签会重复计入（一笔多标签），
/// 拿总和当分母会算出"占比 130%"这种没意义的数字。
class _MiniRankPanel extends StatelessWidget {
  const _MiniRankPanel({
    required this.title,
    required this.items,
    required this.symbol,
    required this.hide,
    this.footnote,
  });

  final String title;
  final List<({String label, int cents})> items;
  final String symbol;
  final bool hide;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    // 空数据时给一句短空态，而不是整块消失：
    // shrink 会让页面高度突然跳一截（上面那张卡跟着上移），像点坏了。
    if (items.isEmpty) {
      return Panel(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Palette.inkSoft(context))),
            const SizedBox(height: 8),
            Text('这个区间还没有数据',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          ],
        ),
      );
    }
    final top = items.take(6).toList();
    final maxCents = top.first.cents <= 0 ? 1 : top.first.cents;
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Palette.inkSoft(context),
              )),
          const SizedBox(height: 10),
          for (final it in top) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    it.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(fontSize: 13, color: Palette.ink(context)),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  hide ? '****' : '$symbol${centsToText(it.cents)}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Palette.ink(context),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (it.cents / maxCents).clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: Palette.hairline(context),
                valueColor: AlwaysStoppedAnimation(Palette.brand(context)),
              ),
            ),
            const SizedBox(height: 9),
          ],
          // 只显示前 6 项，剩下的要说明，不然用户以为统计漏了
          if (items.length > 6)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('另有 ${items.length - 6} 项没列出来',
                  style: TextStyle(
                      fontSize: 10.5, color: Palette.inkFaint(context))),
            ),
          if (footnote != null)
            Text(footnote!,
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
        ],
      ),
    );
  }
}

/// 本月标签占比
class _TagRankPanel extends ConsumerWidget {
  const _TagRankPanel({required this.symbol, required this.hide});

  final String symbol;
  final bool hide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(insightRangeProvider);
    final list = ref.watch(tagTotalsProvider(range)).valueOrNull ?? const [];
    return _MiniRankPanel(
      title: '标签占比',
      items: [for (final t in list) (label: t.tag, cents: t.cents)],
      symbol: symbol,
      hide: hide,
      // 必须写清楚，否则用户把几项加起来发现超过总支出，会以为统计有 bug
      footnote: list.isEmpty ? null : '一笔账单可以有多个标签，各项相加可能大于总支出',
    );
  }
}

/// 本月账户支出分布
class _PocketSplitPanel extends ConsumerWidget {
  const _PocketSplitPanel({required this.symbol, required this.hide});

  final String symbol;
  final bool hide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(insightRangeProvider);
    final list = ref.watch(pocketTotalsProvider(range)).valueOrNull ?? const [];
    return _MiniRankPanel(
      title: '账户收支',
      items: [
        // displayName：简称优先，和资产页/流水行看到的是同一个名字
        for (final p in list)
          (label: '${glyphLabel(p.pocket.glyph)} ${p.pocket.displayName}',
              cents: p.cents),
      ],
      symbol: symbol,
      hide: hide,
    );
  }
}

/// 与上月同期比：分类 → 本月 / 上月 / 变化。
///
/// 为什么单独一张卡而不是塞进排行行里：排行行已经很挤（图标+名称+占比条+金额+百分比），
/// 再挂一行小字会把 393dp 屏压成一条缝。单独成卡信息更清楚，也不动已有布局。
class _PrevComparePanel extends ConsumerWidget {
  const _PrevComparePanel({
    required this.symbol,
    required this.hide,
    required this.type,
    required this.scope,
    required this.range,
  });

  final String symbol;
  final bool hide;
  final InsightType type;
  final InsightScope scope;
  final ({DateTime from, DateTime to}) range;

  /// 非「月」粒度：只做**合计**对照（上一个等长区间）。
  /// 不做分类逐项对比 —— 周报里列 6 个分类的上周对比信息量太低，卡片会很高。
  Widget _rangeCompare(BuildContext context, WidgetRef ref) {
    final days = range.to.difference(range.from).inDays + 1;
    final prevTo = range.from.subtract(const Duration(days: 1));
    final prevFrom = prevTo.subtract(Duration(days: days - 1));
    final curAsync = ref.watch(insightTotalsForProvider(range));
    final prevAsync =
        ref.watch(insightTotalsForProvider((from: prevFrom, to: prevTo)));
    final cur = curAsync.valueOrNull;
    final prev = prevAsync.valueOrNull;
    final label = switch (scope) {
      InsightScope.week => '与上周比',
      InsightScope.year => '与去年比',
      _ => '与上一个 $days 天比',
    };
    final curCents = cur == null
        ? 0
        : (type == InsightType.income ? cur.incomeCents : cur.expenseCents);
    final prevCents = prev == null
        ? 0
        : (type == InsightType.income ? prev.incomeCents : prev.expenseCents);
    final delta = _deltaText(curCents, prevCents);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label,
                style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
            const Spacer(),
            Text('$days 天 vs 前 $days 天',
                style:
                    TextStyle(fontSize: 10.5, color: Palette.inkFaint(context))),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(hide ? '****' : '$symbol${centsToText(curCents)}',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Palette.ink(context),
                    fontFeatures: const [FontFeature.tabularFigures()])),
            const SizedBox(width: 8),
            Text(hide ? '****' : '上一段 $symbol${centsToText(prevCents)}',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
            const Spacer(),
            if (delta != null) _deltaChip(context, delta),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (scope != InsightScope.month) return _rangeCompare(context, ref);

    final cur = ref.watch(insightRankProvider).valueOrNull ?? const <RankNode>[];
    final prev =
        ref.watch(insightPrevRankProvider).valueOrNull ?? const <int?, int>{};

    final rows = cur.take(6).toList();
    final totalCur = cur.fold<int>(0, (s, n) => s + n.cents);
    final totalPrev = prev.values.fold<int>(0, (s, v) => s + v);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('与上月同期比',
                style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
            const Spacer(),
            Text('按上月 1 日至同一天',
                style: TextStyle(
                    fontSize: 10.5, color: Palette.inkFaint(context))),
          ],
        ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: Text('本月还没有记录，记一笔后这里就会出现同期对比',
                  style: TextStyle(
                      fontSize: 12, color: Palette.inkFaint(context))),
            ),
          )
        else ...[
          const SizedBox(height: 8),
          _totalLine(context, totalCur, totalPrev),
          const Divider(height: 18),
          for (final n in rows) _row(context, n, prev[n.bucketId] ?? 0),
        ],
      ],
    );
  }

  Widget _totalLine(BuildContext context, int cur, int prev) {
    final delta = _deltaText(cur, prev);
    return Row(
      children: [
        Text('合计',
            style: TextStyle(fontSize: 13, color: Palette.inkSoft(context))),
        const SizedBox(width: 8),
        Text(hide ? '****' : '$symbol${centsToText(cur)}',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Palette.ink(context))),
        const SizedBox(width: 6),
        Text(hide ? '****' : '上月 $symbol${centsToText(prev)}',
            style: TextStyle(
                fontSize: 12, color: Palette.inkFaint(context))),
        const Spacer(),
        if (delta != null) _deltaChip(context, delta),
      ],
    );
  }

  Widget _row(BuildContext context, RankNode n, int prevCents) {
    final delta = _deltaText(n.cents, prevCents);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          AppGlyph(n.glyph, size: 13),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(n.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13, color: Palette.ink(context))),
                Text(hide ? '****' : '上月 $symbol${centsToText(prevCents)}',
                    style: TextStyle(
                        fontSize: 10.5, color: Palette.inkFaint(context))),
              ],
            ),
          ),
          if (delta != null) _deltaChip(context, delta),
          const SizedBox(width: 8),
          Text(hide ? '****' : '$symbol${centsToText(n.cents)}',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Palette.ink(context))),
        ],
      ),
    );
  }

  /// 变化描述：上月为 0 时不编百分比（除以 0 没意义）。
  ({int pct, bool up})? _deltaText(int cur, int prev) {
    if (prev <= 0) return null;
    final diff = cur - prev;
    if (diff == 0) return (pct: 0, up: false);
    return (pct: (diff.abs() * 100 / prev).round(), up: diff > 0);
  }

  Widget _deltaChip(BuildContext context, ({int pct, bool up}) d) {
    if (d.pct == 0) {
      return Text('持平',
          style: TextStyle(fontSize: 10.5, color: Palette.inkFaint(context)));
    }
    // 支出变多是坏事（红），变少是好事（绿）；收入反过来。
    final bad = type == InsightType.income ? !d.up : d.up;
    final color = bad ? Palette.expense : Palette.income;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${d.up ? '↑' : '↓'}${d.pct}%',
        style: TextStyle(
            fontSize: 10.5, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

/// 本月总结：一张可手写的卡片（对齐一木统计页底部）。
///
/// 全 App 都是数字，缺一个"人话"的位置。这里只做一件事：让用户给这个月留一句话。
/// 存 `month_notes(book_id, month, note)`，随备份一起走。
class _MonthNoteCard extends ConsumerWidget {
  const _MonthNoteCard({required this.month});

  final DateTime month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = ref.watch(monthNoteProvider).valueOrNull ?? '';
    return Panel(
      child: PressScale(
        scale: 0.99,
        onTap: () => _edit(context, ref, note),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('本月总结',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context))),
                const Spacer(),
                Text(note.isEmpty ? '写一句' : '修改',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Palette.brand(context))),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              note.isEmpty ? '给这个月留一句话，只有自己看得到' : note,
              maxLines: 6,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: note.isEmpty ? 12 : 13,
                height: 1.55,
                color: note.isEmpty
                    ? Palette.inkFaint(context)
                    : Palette.ink(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, String current) async {
    final ctrl = TextEditingController(text: current);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${month.month} 月总结'),
        content: AppTextField(
          label: '写点什么',
          controller: ctrl,
          hint: '这个月花得值不值？有什么想记住的？',
          maxLines: 5,
          maxLength: 200,
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text),
              child: const Text('保存')),
        ],
      ),
    );
    // 先放掉临时控制器再走后面的 await（审计 P3-10）
    ctrl.dispose();
    if (saved == null) return;
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    await store.setMonthNote(book.id, month, saved);
    bumpRevision(ref);
    ref.invalidate(monthNoteProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).toast(saved.trim().isEmpty ? '已清除本月总结' : '已保存本月总结');
  }
}
