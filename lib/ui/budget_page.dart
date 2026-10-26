import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/aggregate.dart';
import '../core/budget_rules.dart';
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
            icon: const Icon(Icons.rule, size: 20),
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
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 96),
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
                const SizedBox(height: 20),
                SectionLabel('分类预算（可选）'),
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
                            fontSize: 11.5,
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
                  fontSize: 30,
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                              fontSize: 13.5, fontWeight: FontWeight.w500)),
                      const Spacer(),
                      Text(
                        configured
                            ? '$symbol${(spentCents / 100).toStringAsFixed(0)} / $symbol${(budgetCents / 100).toStringAsFixed(0)}'
                            : '未设预算',
                        style: TextStyle(
                          fontSize: 11.5,
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
          ],
        ),
      ),
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
                      fontSize: 12.5, color: Palette.inkSoft(context))),
              const Spacer(),
              Text(_money(base), style: const TextStyle(fontSize: 12.5)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(carry >= 0 ? '上月结转' : '上月超支',
                  style: TextStyle(
                      fontSize: 12.5, color: Palette.inkSoft(context))),
              const Spacer(),
              Text(
                // 负数用「−」而不是「-」，和正数宽度对齐，扫一眼就知道方向
                '${carry >= 0 ? '+' : '−'}${_money(carry)}',
                style: TextStyle(
                  fontSize: 12.5,
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
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: Palette.ink(context))),
              const Spacer(),
              Text(
                _money(effective),
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w700, color: brand),
              ),
            ],
          ),
          if (over > 0) ...[
            const SizedBox(height: 6),
            Text(
              '上期超支已扣完本期预算，还差 ${_money(over)}',
              style: TextStyle(fontSize: 11, color: Palette.expense),
            ),
          ],
        ],
      ),
    );
  }
}
