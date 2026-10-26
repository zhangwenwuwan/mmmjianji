import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/aggregate.dart';
import '../data/store.dart';
import '../core/rules.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'budget_page.dart';
import 'assets_page.dart';
import 'category_detail_page.dart';
import 'charts.dart';
import 'common.dart';
import 'motion.dart';
import 'sankey.dart';
import 'theme.dart';
import 'wheel_date_picker.dart';

/// 洞察：这个月的钱去哪了、预算还剩多少、趋势怎么走。
///
/// 顶部两组胶囊切换（对齐参考版）：口径「支出 / 收入 / 结余」，
/// 范围「本月 / 本年 / 全部」。切到「本年 / 全部」时月份切换器让位给区间标题。
class InsightsPage extends ConsumerWidget {
  const InsightsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    return Column(
      children: [
        // 周期粒度：周 / 月 / 年 / 全部 / 范围
        // 2026-10-26 用户要求照参考版改：原来是「月份条 + 本月/上月/选月份 +
        // 支出/收入/结余 + 范围按钮」四行，重点在哪个月上；现在周期本身就是
        // 一级分类，压成一段分段控件，日期只在下面一行。
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: _ScopeSegments(
            scope: scope,
            onChanged: (s) => _setScope(ref, s),
          ),
        ),
        // 区间：2026/10/20  ~  2026/10/26
        // 周/月/年：右端只读（是算出来的区间末），左端点开改锚点；
        // 范围：两端都能点；全部：没有端点可选。
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 0),
          child: _RangeLine(
            scope: scope,
            range: range,
            onFrom: () => _pickStart(context, ref),
            onTo: scope == InsightScope.custom
                ? () => _pickEnd(context, ref)
                : null,
          ),
        ),
        // 口径：支出 / 收入 / 结余（天天点的一级切换，保留三个胶囊）
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
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
                selected: isBalance,
                onTap: () => ref.read(insightTypeProvider.notifier).state =
                    InsightType.balance,
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 88),
            children: [
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

              // 与上月同期比：只在「本月」口径下有对照意义（上月整月对本月半个月是假的）
              if (!isBalance && scope == InsightScope.month) ...[
                Panel(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  child: _PrevComparePanel(
                    symbol: settings.symbol,
                    hide: settings.hideAmounts,
                    type: type,
                  ),
                ),
                const SizedBox(height: 14),
              ],

              // 净资产走势：复用资产页同一个组件，别在统计页再画一版（口径会走样）
              const NetWorthTrend(),
              const SizedBox(height: 14),

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

              // 预算
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
                        TextButton(
                          onPressed: () => Navigator.of(context)
                              .push(AppPageRoute(page: const BudgetPage())),
                          style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 0),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                          child:
                              const Text('管理', style: TextStyle(fontSize: 12)),
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
                                fontSize: 21,
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
                                    fontSize: 11,
                                    color: Palette.inkSoft(context))),
                          ),
                          const Spacer(),
                          if (progress.daysLeft > 0)
                            Text(
                                '每天约 ${settings.symbol}${centsToText(progress.safeDailyCents)}',
                                style: TextStyle(
                                    fontSize: 11,
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
                        fontSize: 11, color: Palette.inkFaint(context))),
              ),
            ],
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
              fontSize: 24,
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
                    fontSize: 11.5,
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
                    fontSize: 11.5,
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
              style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: MoneyText(
              cents,
              flow: flow,
              style: TextStyle(
                fontSize: 16,
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: kSliceColors[i % kSliceColors.length],
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
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: Palette.inkSoft(context),
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
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
          Navigator.of(context)
              .push(AppPageRoute(page: CategoryDetailPage(bucket: target)));
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
                    size: 12, color: Palette.inkFaint(context)),
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
                                fontSize: depth == 0 ? 12.5 : 11.5,
                                color: depth == 0
                                    ? Palette.ink(context)
                                    : Palette.inkSoft(context))),
                      ),
                      Text(
                        widget.hide
                            ? '****'
                            : '${widget.symbol}${centsToText(n.cents)}',
                        style: TextStyle(
                            fontSize: 11.5,
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
    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Palette.inkFaint(context).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        children: [
          for (final e in _labels.entries)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(e.key),
                child: AnimatedContainer(
                  duration: Motion.d(context, Motion.small),
                  curve: XCurve.easeOut,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: e.key == scope
                        ? Palette.card(context)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: e.key == scope
                        ? [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.07),
                              blurRadius: 6,
                              offset: const Offset(0, 1),
                            ),
                          ]
                        : null,
                  ),
                  child: Text(
                    e.value,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight:
                          e.key == scope ? FontWeight.w700 : FontWeight.w500,
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
    );
  }
}

/// 区间行：`2026/10/01 ⌄   ~   2026/10/31 ⌄`
///
/// 箭头只出现在**能点**的一端 —— 周/月/年右端是算出来的区间末，
/// 给它画个下拉箭头等于骗用户去点。
class _RangeLine extends StatelessWidget {
  const _RangeLine({
    required this.scope,
    required this.range,
    this.onFrom,
    this.onTo,
  });

  final InsightScope scope;
  final ({DateTime from, DateTime to}) range;
  final VoidCallback? onFrom;
  final VoidCallback? onTo;

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
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Palette.ink(context))),
          const SizedBox(width: 8),
          Text('所有历史流水',
              style:
                  TextStyle(fontSize: 11.5, color: Palette.inkFaint(context))),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _end(context, range.from, onFrom),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('~',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Palette.inkFaint(context))),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _end(context, range.to, onTo),
          ),
        ),
      ],
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
          Text(
            _fmt(d),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              // 不能点的一端压暗，一眼能看出哪个是"算出来的"
              color: enabled ? Palette.ink(context) : Palette.inkSoft(context),
              fontFeatures: const [FontFeature.tabularFigures()],
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
              fontSize: 12.5,
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
    final async = ref.watch(monthSeriesProvider(6));
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
        onRetry: () async => ref.invalidate(monthSeriesProvider(6)),
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
                                  fontSize: 9,
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
                    TextStyle(fontSize: 11, color: Palette.inkSoft(context))),
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
            fontSize: 11,
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
    if (items.isEmpty) return const SizedBox.shrink();
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
                        TextStyle(fontSize: 12.5, color: Palette.ink(context)),
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
          if (footnote != null)
            Text(footnote!,
                style:
                    TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
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
    final list = ref.watch(tagTotalsProvider).valueOrNull ?? const [];
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
    final list = ref.watch(pocketTotalsProvider).valueOrNull ?? const [];
    return _MiniRankPanel(
      title: '账户收支',
      items: [
        for (final p in list)
          (label: '${glyphLabel(p.pocket.glyph)} ${p.pocket.title}',
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
  });

  final String symbol;
  final bool hide;
  final InsightType type;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            style: TextStyle(fontSize: 12.5, color: Palette.inkSoft(context))),
        const SizedBox(width: 8),
        Text(hide ? '****' : '$symbol${centsToText(cur)}',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Palette.ink(context))),
        const SizedBox(width: 6),
        Text(hide ? '****' : '上月 $symbol${centsToText(prev)}',
            style: TextStyle(
                fontSize: 11, color: Palette.inkFaint(context))),
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
                        fontSize: 12.5, color: Palette.ink(context))),
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
                  fontSize: 12.5,
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
            fontSize: 10, fontWeight: FontWeight.w700, color: color),
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
                        fontSize: 11.5,
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
    if (saved == null) return;
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    await store.setMonthNote(book.id, month, saved);
    bumpRevision(ref);
    ref.invalidate(monthNoteProvider);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(saved.trim().isEmpty ? '已清除本月总结' : '已保存本月总结'),
    ));
  }
}
