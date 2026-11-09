import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/aggregate.dart';
import '../core/budget_rules.dart';
import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'amount_keypad.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 预算：这个月还能花多少。
class BudgetPage extends ConsumerWidget {
  const BudgetPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(monthProvider);
    // 基础预算（用户手填的那个）与「本期可用」是两回事：
    // 后者 = 基础 + 上期结转，进度条必须按后者算，否则结转等于白设。
    final budget = ref.watch(budgetProvider).valueOrNull ?? 0;
    final available = ref.watch(effectiveBudgetProvider).valueOrNull ?? budget;
    final carry = ref.watch(budgetCarryProvider).valueOrNull ?? 0;
    final totals = ref.watch(totalsProvider).valueOrNull ??
        (incomeCents: 0, expenseCents: 0);
    final settings = ref.watch(settingsProvider);

    final progress = buildBudgetProgress(
      budgetCents: available,
      // 预算口径（排除「不计入预算」），和下面的分类预算保持一致
      spentCents:
          ref.watch(budgetSpentProvider).valueOrNull ?? totals.expenseCents,
      month: month,
      today: DateTime.now(),
    );

    // 这个页面是 push 进来的独立页，必须自带 Scaffold，
    // 否则没有背景色（Navigator 默认底色），看起来就是「黑不溜秋」。
    return Scaffold(
      appBar: AppBar(
        title: const Text('预算管理'),
        actions: [
          IconButton(
            tooltip: '结转规则',
            onPressed: () => _budgetRules(context, ref),
            icon: const Icon(Icons.rule, size: 18),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: MonthBar(
              month: month,
              onChanged: (m) => ref.read(monthProvider.notifier).state = m,
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 96),
              children: [
                Panel(
                  child: progress.configured
                      ? _BudgetStatus(
                          progress: progress, symbol: settings.symbol)
                      : _BudgetEmpty(
                          onSet: () => _editBudget(context, ref, month, budget),
                        ),
                ),
                // 结转明细：只在真的启用了结转、且本月有基础预算时显示。
                // 平时不显示——多数人没开结转，多一行数字只会让页面变吵。
                if (settings.budgetCarryEnabled && budget > 0) ...[
                  const SizedBox(height: 10),
                  _CarryNote(
                    base: budget,
                    carry: carry,
                    effective: available,
                    symbol: settings.symbol,
                    hide: settings.hideAmounts,
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            _editBudget(context, ref, month, budget),
                        icon: const Icon(Icons.tune, size: 18),
                        label: Text(progress.configured ? '修改本月预算' : '设置本月预算'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _BudgetSuggestRow(
                  configured: progress.configured,
                  baseBudget: budget,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    const Expanded(child: SectionLabel('分类预算（可选）')),
                    _ProportionalSplitButton(baseBudget: budget),
                  ],
                ),
                _BucketBudgets(symbol: settings.symbol),
                const SizedBox(height: 16),
                Panel(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: const _BudgetHistoryHint(),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 结转规则设置。做成独立面板而不是塞进「外观与显示」：
  /// 用户是在"这个月预算怎么不对"的时候才想起来改它，入口必须在预算页上。
  Future<void> _budgetRules(BuildContext context, WidgetRef ref) {
    return showAppSheet<void>(
      context: context,
      title: '预算结转',
      builder: (ctx) => Consumer(
        builder: (ctx, r, _) {
          final s = r.watch(settingsProvider);
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ruleTile(
                context,
                title: '多余预算累加',
                subtitle: '上个月没用完的，加到本月一起用',
                value: s.budgetCarryUnused,
                onChanged: (v) =>
                    r.read(settingsProvider.notifier).setBudgetCarryUnused(v),
              ),
              const Divider(height: 1),
              _ruleTile(
                context,
                title: '超额支出扣除',
                subtitle: '上个月超支多少，就从本月扣多少',
                value: s.budgetDeductOver,
                onChanged: (v) =>
                    r.read(settingsProvider.notifier).setBudgetDeductOver(v),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: Palette.inkFaint(context)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '上个月没设预算时，一个月都不会结转，也不会倒扣。',
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.5,
                            color: Palette.inkFaint(context)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _ruleTile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return ListTile(
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: JellySwitch(value: value, onChanged: onChanged),
    );
  }

  Future<void> _editBudget(
      BuildContext context, WidgetRef ref, DateTime month, int current) async {
    // 预填必须原样还原（含小数），否则用户只是进来看看、点保存，
    // 预算就被悄悄改了（3000.50 → 3001）。AmountKeypadController 内部按分回显，
    // 走的正是同一套规则。
    final result = await showAmountKeypad(
      context,
      initialCents: current,
      title: '本月预算（0 = 不设预算）',
      allowZero: true,
    );
    if (result == null) return;
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    await store.setBudget(book.id, month, result);
    bumpRevision(ref);
  }
}

/// 预算智能建议行（2026-11-09）。
///
/// 两个入口，各只在有料时出现：
/// - 上月设过预算而本月没设 → 「沿用上月预算」；
/// - 近 3 个月有消费 → 「按近 3 月平均设置」。
/// 都是直接生效 + toast，预算随手可改，不值得再叠一层确认框。
class _BudgetSuggestRow extends ConsumerWidget {
  const _BudgetSuggestRow({
    required this.configured,
    required this.baseBudget,
  });

  final bool configured;
  final int baseBudget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sug = ref.watch(budgetSuggestionProvider).valueOrNull;
    if (sug == null) return const SizedBox.shrink();
    final hide = ref.watch(settingsProvider).hideAmounts;

    final showCarry = !configured && sug.prevBudgetCents > 0;
    final showSuggest = sug.suggestCents > 0 &&
        !(configured && sug.suggestCents == baseBudget);
    if (!showCarry && !showSuggest) return const SizedBox.shrink();

    return Panel(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showCarry)
            TextButton.icon(
              onPressed: () =>
                  _applySuggestedBudget(context, ref, sug.prevBudgetCents,
                      '已沿用上月预算'),
              icon: const Icon(Icons.history, size: 16),
              label: Text(hide
                  ? '沿用上月预算'
                  : '沿用上月预算 ¥${centsToText(sug.prevBudgetCents)}'),
            ),
          if (showSuggest)
            TextButton.icon(
              onPressed: () => _applySuggestedBudget(
                  context,
                  ref,
                  sug.suggestCents,
                  hide
                      ? '已按近 3 月平均设置'
                      : '已按近 3 月平均设置 ¥${centsToText(sug.suggestCents)}'),
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: Text(hide
                  ? '按近 3 月平均设置'
                  : '按近 3 月平均设置 ¥${centsToText(sug.suggestCents)}'),
            ),
        ],
      ),
    );
  }

  Future<void> _applySuggestedBudget(
      BuildContext context, WidgetRef ref, int cents, String toast) async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final month = ref.read(monthProvider);
    await store.setBudget(book.id, month, cents);
    bumpRevision(ref);
    if (context.mounted) ScaffoldMessenger.of(context).toast(toast);
  }
}

/// 分类预算「按消费分配」：把本月总预算按近 3 个月的分类消费占比
/// 一键摊到各分类（最大余数法，见 core/budget_rules.dart）。
///
/// 为什么以基础预算为准：结转后的「可用」包含上月滚动结果，
/// 拿它当分摊基数会让每个月的分类预算越来越看不懂。
class _ProportionalSplitButton extends ConsumerWidget {
  const _ProportionalSplitButton({required this.baseBudget});

  final int baseBudget;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton(
      onPressed: () => _run(context, ref),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        visualDensity: VisualDensity.compact,
      ),
      child: const Text('按消费分配', style: TextStyle(fontSize: 13)),
    );
  }

  Future<void> _run(BuildContext context, WidgetRef ref) async {
    if (baseBudget <= 0) {
      ScaffoldMessenger.of(context).toast('先设置本月总预算，再按消费分配');
      return;
    }
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final rates = await ref.read(ratesProvider.future);
    final month = ref.read(monthProvider);

    // 近 3 个月的分类消费（折主币）：占比来源。
    final spent = <int, int>{};
    for (var back = 1; back <= 3; back++) {
      final m = DateTime(month.year, month.month - back);
      for (final s in await store.bucketSlices(book.id, m)) {
        final id = s.bucketId;
        if (id == null) continue; // 未分类没有预算行，跳过
        spent[id] = (spent[id] ?? 0) +
            toBaseCents(s.cents, s.currency, book.baseCurrency, rates);
      }
    }
    final plan = proportionalSplitCents(baseBudget, spent);
    if (plan.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).toast('近 3 个月分类还没有消费，没法按比例分配');
      }
      return;
    }

    final buckets =
        ref.read(bucketsProvider('out')).valueOrNull ?? const <Bucket>[];
    final titleOf = {for (final b in buckets) b.id: b.title};
    final glyphOf = {for (final b in buckets) b.id: b.glyph};

    if (!context.mounted) return;
    final ok = await showAppSheet<bool>(
      context: context,
      title: '按消费分配分类预算',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '按近 3 个月的消费比例，把总预算 ¥${centsToText(baseBudget)} 分到各分类：',
                style: TextStyle(
                    fontSize: 13, color: Palette.inkFaint(ctx)),
              ),
            ),
          ),
          // 分类多时别把弹层撑出屏幕：给预览列表一个上限，超出就滚。
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: Column(
                children: [
                  for (final e in plan.entries)
                    ListTile(
                      leading: Text(glyphOf[e.key] ?? '🧾',
                          style: const TextStyle(fontSize: 18)),
                      title: Text(titleOf[e.key] ?? '已删除分类'),
                      trailing: Text('¥${centsToText(e.value)}'),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('就这样分配'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final bookNow = await ref.read(activeBookProvider.future);
    final storeNow = await ref.read(storeProvider.future);
    for (final e in plan.entries) {
      await storeNow.setBucketBudget(bookNow.id, month, e.key, e.value);
    }
    bumpRevision(ref);
    if (context.mounted) {
      ScaffoldMessenger.of(context).toast('已按消费比例设置 ${plan.length} 个分类预算');
    }
  }
}

class _BudgetStatus extends StatelessWidget {
  const _BudgetStatus({required this.progress, required this.symbol});

  final BudgetProgress progress;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final ratio = progress.ratio;
    final color = progress.overflow
        ? Palette.expense
        : ratio > 0.8
            ? Palette.warn
            : Palette.brand(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('本月预算',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
            const Spacer(),
            Text(
              '$symbol${centsToText(progress.budgetCents)}',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Palette.inkSoft(context)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                '$symbol${centsToText(progress.remainCents.abs())}',
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  color: progress.overflow
                      ? Palette.expense
                      : Palette.ink(context),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 5, left: 6),
              child: Text(progress.overflow ? '已超支' : '还可以花',
                  style:
                      TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: ratio,
            minHeight: 10,
            backgroundColor: Palette.hairline(context),
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text('已花 $symbol${centsToText(progress.spentCents)}',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
            const Spacer(),
            if (progress.daysLeft > 0)
              Text(
                '剩 ${progress.daysLeft} 天 · 每天约 $symbol${centsToText(progress.safeDailyCents)}',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context)),
              ),
          ],
        ),
      ],
    );
  }
}

class _BudgetEmpty extends StatelessWidget {
  const _BudgetEmpty({required this.onSet});

  final VoidCallback onSet;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(Icons.savings_outlined,
            size: 34, color: Palette.inkFaint(context)),
        const SizedBox(height: 10),
        Text('还没给这个月设预算',
            style: TextStyle(fontSize: 14, color: Palette.inkSoft(context))),
        const SizedBox(height: 4),
        Text('设一个数，页面会算出每天还能花多少',
            style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
        const SizedBox(height: 14),
        FilledButton(onPressed: onSet, child: const Text('设个预算')),
      ],
    );
  }
}

class _BudgetHistoryHint extends StatelessWidget {
  const _BudgetHistoryHint();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Text(
        '预算按月独立保存，切到上个月会显示那个月的预算；没设过的月份按「未设置」处理。',
        style: TextStyle(
            fontSize: 12, height: 1.5, color: Palette.inkFaint(context)),
      ),
    );
  }
}

/// 各支出分类的月度预算：设了的显示进度，没设的点一下就能设。
class _BucketBudgets extends ConsumerWidget {
  const _BucketBudgets({required this.symbol});

  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bucketsAsync = ref.watch(bucketsProvider('out'));
    final budgets = ref.watch(bucketBudgetsProvider).valueOrNull ?? const {};
    final spent = ref.watch(bucketSpentProvider).valueOrNull ?? const {};

    // 只有「真的一次数据都没有」时才铺骨架屏。
    // 否则从子页面 pop 回来、或改了分类预算触发重算时，会先闪一下骨架屏
    // 再换回内容——那一下闪烁就是"阻滞感"的一部分。
    final buckets = bucketsAsync.valueOrNull;
    if (buckets == null) {
      if (bucketsAsync.hasError) {
        return Panel(child: Text('读取失败：${bucketsAsync.error}'));
      }
      return const Panel(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Skeleton(height: 44, radius: 10),
              SizedBox(height: 8),
              Skeleton(height: 44, radius: 10),
              SizedBox(height: 8),
              Skeleton(height: 44, radius: 10),
            ],
          ),
        ),
      );
    }

    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < buckets.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 56),
            _BucketBudgetRow(
              bucket: buckets[i],
              budgetCents: budgets[buckets[i].id] ?? 0,
              spentCents: spent[buckets[i].id] ?? 0,
              symbol: symbol,
            ),
          ],
        ],
      ),
    );
  }
}

class _BucketBudgetRow extends ConsumerWidget {
  const _BucketBudgetRow({
    required this.bucket,
    required this.budgetCents,
    required this.spentCents,
    required this.symbol,
  });

  final Bucket bucket;
  final int budgetCents;
  final int spentCents;
  final String symbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configured = budgetCents > 0;
    final ratio = configured ? (spentCents / budgetCents).clamp(0.0, 1.0) : 0.0;
    final over = configured && spentCents > budgetCents;

    return PressScale(
      scale: 0.98,
      onTap: () => _edit(context, ref),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        child: Row(
          children: [
            AppGlyph(bucket.glyph, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(bucket.title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500)),
                      const Spacer(),
                      Text(
                        configured
                            ? '$symbol${(spentCents / 100).toStringAsFixed(0)} / $symbol${(budgetCents / 100).toStringAsFixed(0)}'
                            : '未设预算',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight:
                              configured ? FontWeight.w600 : FontWeight.w400,
                          color: over
                              ? Palette.expense
                              : (configured
                                  ? Palette.inkSoft(context)
                                  : Palette.inkFaint(context)),
                        ),
                      ),
                    ],
                  ),
                  if (configured) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: ratio,
                        minHeight: 6,
                        backgroundColor: Palette.hairline(context),
                        valueColor: AlwaysStoppedAnimation(
                            over ? Palette.expense : Palette.brand(context)),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // 「历史」单独一个按钮：整行点击是"改预算"（高频、用户预期），
            // 把它改成打开历史会让人每次改预算都多点一下。
            // 用紧凑 constraints 压住默认 48×48，否则每行会被撑高一截。
            IconButton(
              tooltip: '近 6 个月对比',
              onPressed: () => _showHistory(context, ref),
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              icon: Icon(Icons.insights_outlined,
                  color: Palette.inkFaint(context)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showHistory(BuildContext context, WidgetRef ref) {
    final month = ref.read(monthProvider);
    return showAppSheet<void>(
      context: context,
      title: '「${bucket.title}」近 6 个月',
      builder: (_) => _BucketHistorySheet(bucket: bucket, month: month),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref) async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final month = ref.read(monthProvider);
    if (!context.mounted) return;
    final result = await showAmountKeypad(
      context,
      initialCents: budgetCents,
      title: '${bucket.title} 的月预算（0 = 取消）',
      allowZero: true,
    );
    if (result == null) return;
    await store.setBucketBudget(book.id, month, bucket.id, result);
    bumpRevision(ref);
  }
}

/// 「基础预算 + 上期结转 = 本期可用」这一行。
///
/// 必须把三项都列出来：只把可用数字改掉、不解释来源，用户会以为预算被改了。
class _CarryNote extends StatelessWidget {
  const _CarryNote({
    required this.base,
    required this.carry,
    required this.effective,
    required this.symbol,
    required this.hide,
  });

  final int base;
  final int carry;
  final int effective;
  final String symbol;
  final bool hide;

  String _money(int cents) =>
      hide ? '****' : '$symbol${(cents.abs() / 100).toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final over = overFromPrevCents(base: base, carry: carry);
    final brand = Palette.brand(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Palette.card(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('基础预算',
                  style: TextStyle(
                      fontSize: 13, color: Palette.inkSoft(context))),
              const Spacer(),
              Text(_money(base), style: const TextStyle(fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(carry >= 0 ? '上月结转' : '上月超支',
                  style: TextStyle(
                      fontSize: 13, color: Palette.inkSoft(context))),
              const Spacer(),
              Text(
                // 负数用「−」而不是「-」，和正数宽度对齐，扫一眼就知道方向
                '${carry >= 0 ? '+' : '−'}${_money(carry)}',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: carry >= 0 ? Palette.income : Palette.expense,
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Divider(height: 1),
          ),
          Row(
            children: [
              Text('本期可用',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Palette.ink(context))),
              const Spacer(),
              Text(
                _money(effective),
                style: TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700, color: brand),
              ),
            ],
          ),
          if (over > 0) ...[
            const SizedBox(height: 6),
            Text(
              '上期超支已扣完本期预算，还差 ${_money(over)}',
              style: TextStyle(fontSize: 12, color: Palette.expense),
            ),
          ],
        ],
      ),
    );
  }
}

/// 某个分类近 6 个月的「已花 vs 预算」。
///
/// 为什么单独做一个：预算页只回答"这个月花了多少"，答不了"是不是比前几个月
/// 花得凶"。要判断"这个月超支是偶然还是趋势"，必须把 6 个月摆在一起看。
///
/// 口径：金额含子分类（给「食」设预算、钱记在「外卖」上也要算进来），
/// 与 `bucketSpentProvider` / `bucketBudgetStatusOf` 一致。
class _BucketHistorySheet extends ConsumerStatefulWidget {
  const _BucketHistorySheet({required this.bucket, required this.month});

  final Bucket bucket;
  final DateTime month;

  @override
  ConsumerState<_BucketHistorySheet> createState() =>
      _BucketHistorySheetState();
}

typedef _MonthSpend = ({DateTime month, int spentCents, int budgetCents});

class _BucketHistorySheetState extends ConsumerState<_BucketHistorySheet> {
  Future<List<_MonthSpend>>? _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<_MonthSpend>> _load() async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final rates = await store.rates(book.id);
    final tree = await store.buckets(book.id, 'out', includeArchived: true);
    final ids = bucketFamilyIds(tree, widget.bucket.id);
    // 一次拿到 6 个月已花（SQL 里已按父+子分类汇总），预算再逐月取。
    final raw = await store.bucketMonthly(book.id, ids,
        flow: 'out', months: 6, anchor: widget.month);
    final spentByMonth = <String, int>{};
    for (final r in raw) {
      spentByMonth[r.month] = (spentByMonth[r.month] ?? 0) +
          toBaseCents(r.cents, r.currency, book.baseCurrency, rates);
    }
    // 注意 bucketMonthly 只返回"有数据的月份"，没花钱的月份要自己补 0，
    // 否则图上会少几个月，看起来像数据丢了。
    final out = <_MonthSpend>[];
    for (var i = 5; i >= 0; i--) {
      final m = DateTime(widget.month.year, widget.month.month - i);
      final key = '${m.year}-${m.month.toString().padLeft(2, '0')}';
      final budgets = await store.bucketBudgets(book.id, m);
      out.add((
        month: m,
        spentCents: spentByMonth[key] ?? 0,
        budgetCents: budgets[widget.bucket.id] ?? 0,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final symbol = ref.watch(settingsProvider).symbol;
    return FutureBuilder<List<_MonthSpend>>(
      future: _future,
      builder: (context, snap) {
        final rows = snap.data;
        if (rows == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 28),
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in rows) _row(context, r, symbol),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 18),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline,
                      size: 14, color: Palette.inkFaint(context)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      // 这句刻意写短：原来那句 26 个字，在 320dp 宽的屏上会折成
                      // 「…按「未设预算」处 / 理。」—— 单个「理」字掉到下一行很难看。
                      '金额含子分类；未设预算的月份按未设处理。',
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: Palette.inkFaint(context)),
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

  Widget _row(BuildContext context, _MonthSpend r, String symbol) {
    final hasBudget = r.budgetCents > 0;
    final over = hasBudget && r.spentCents > r.budgetCents;
    final ratio =
        hasBudget ? (r.spentCents / r.budgetCents).clamp(0.0, 1.0) : 0.0;
    final color = !hasBudget
        ? Palette.inkFaint(context)
        : over
            ? Palette.expense
            : ratio >= 0.8
                ? const Color(0xFFB26A00)
                : Palette.brand(context);
    final tail = !hasBudget
        ? '未设预算'
        : over
            ? '超 $symbol${centsToText(r.spentCents - r.budgetCents)}'
            : '/ $symbol${centsToText(r.budgetCents)}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text('${r.month.month} 月',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '$symbol${centsToText(r.spentCents)}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Palette.ink(context),
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(tail,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: color)),
                    ),
                  ],
                ),
                if (hasBudget) ...[
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: ratio,
                      minHeight: 4,
                      backgroundColor: Palette.hairline(context),
                      valueColor: AlwaysStoppedAnimation(color),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
