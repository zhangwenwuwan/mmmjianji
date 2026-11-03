import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'amount_keypad.dart';
import 'app_glyph.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// AA 待收：分摊出去、别人还没还我的钱。
///
/// 与「报销」同一套心智：那笔支出的钱已经从账户扣走，AA 那部分是应收。
/// 收回时生成一笔**不计收支**的收入（只加账户余额），待收按 Σ 回款现算。
class AaReceivablePage extends ConsumerWidget {
  const AaReceivablePage({super.key});

  Future<void> _settle(
      BuildContext context, WidgetRef ref, Entry e, int leftCents) async {
    final book = await ref.read(activeBookProvider.future);
    final pockets =
        (ref.read(allPocketsProvider).valueOrNull ?? const <Pocket>[])
            .where((p) => !p.archived)
            .toList();
    if (!context.mounted) return;
    // 先问本次收回多少（默认全额，可改小做「部分收回」）。
    final take = await showAmountKeypad(context,
        initialCents: leftCents, title: '本次收回', allowZero: false);
    if (take == null || !context.mounted) return;
    final amountCents = take.clamp(1, leftCents);
    // 只列同币种账户：这笔钱原样回来，记进别的币种要折算，AA 单上没有汇率。
    final currencyOfPocket = {for (final p in pockets) p.id: p.currency};
    final subject = e.currency ?? currencyOfPocket[e.pocketId] ?? book.baseCurrency;
    final candidates = pockets.where((p) => p.currency == subject).toList();
    final symbol = ref.read(settingsProvider).symbol;
    final amount = '$symbol${centsToText(amountCents)}';
    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context)
          .toast('还没有 $subject 账户，先到资产页建一个再收回');
      return;
    }
    final picked = await showAppSheet<int>(
      context: context,
      title: 'AA 回款记到哪个账户',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              '确认后把 $amount 作为一笔收入记入所选账户（不计收支，只加余额）。',
              style: TextStyle(fontSize: 12, color: Palette.inkSoft(ctx)),
            ),
          ),
          for (final p in candidates)
            ListTile(
              leading: SizedBox(
                width: 34,
                height: 34,
                child: AppGlyph(p.glyph, size: 20, fill: true, radius: 9),
              ),
              title: Text(p.displayName),
              subtitle: Text(p.currency,
                  style: const TextStyle(fontSize: 12)),
              trailing: Icon(Icons.chevron_right,
                  size: 18, color: Palette.inkFaint(ctx)),
              onTap: () => Navigator.of(ctx).pop(p.id),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
    if (picked == null) return;
    final store = await ref.read(storeProvider.future);
    await store.settleAa(e.id, picked, amountCents: amountCents);
    bumpRevision(ref);
    if (!context.mounted) return;
    final name = candidates.firstWhere((p) => p.id == picked).displayName;
    ScaffoldMessenger.of(context).toast('$amount 已记入「$name」，可随时撤销');
  }

  Future<void> _unsettle(
      BuildContext context, WidgetRef ref, Entry e) async {
    final store = await ref.read(storeProvider.future);
    await store.unsettleAa(e.id);
    bumpRevision(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).toast('已撤销，待收恢复');
  }

  /// 记 / 改「谁该还这笔」。空 = 不记。
  Future<void> _editName(
      BuildContext context, WidgetRef ref, Entry e) async {
    final ctrl = TextEditingController(text: e.aaCounterparty ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('谁该还这笔'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '姓名，留空 = 不记'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null) return;
    final store = await ref.read(storeProvider.future);
    await store.setAaCounterparty(e.id, name);
    bumpRevision(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = ref.watch(activeBookProvider).valueOrNull;
    final base = book?.baseCurrency ?? 'CNY';
    final rates = ref.watch(ratesProvider).valueOrNull ?? const {};
    final settings = ref.watch(settingsProvider);
    final pockets =
        ref.watch(allPocketsProvider).valueOrNull ?? const <Pocket>[];
    final currencyOf = {for (final p in pockets) p.id: p.currency};
    final async = ref.watch(aaReceivableProvider);

    String money(int c) =>
        settings.hideAmounts ? '****' : '${settings.symbol}${centsToText(c)}';
    int toBase(int cents, Entry e) => toBaseCents(
        cents, e.currency ?? currencyOf[e.pocketId] ?? base, base, rates);

    return Scaffold(
      appBar: AppBar(title: const Text('AA 待收')),
      body: async.when(
        loading: () => const SkeletonList(),
        error: (e, _) => EmptyView(
            icon: Icons.error_outline, title: '加载失败', hint: '$e'),
        data: (d) {
          final pending = [
            for (final it in d.items)
              if (it.entry.splitCents - it.settledCents > 0) it
          ];
          final done = [
            for (final it in d.items)
              if (it.entry.splitCents - it.settledCents <= 0) it
          ];
          final pendingTotal = pending.fold<int>(
              0, (s, it) => s + toBase(it.entry.splitCents - it.settledCents, it.entry));
          final doneTotal = done.fold<int>(
              0, (s, it) => s + toBase(it.settledCents, it.entry));

          if (d.items.isEmpty) {
            return const EmptyView(
              icon: Icons.groups_outlined,
              title: '还没有 AA 分摊',
              hint: '记支出时点「AA 分摊」，填上别人承担的部分，这里就能跟踪谁还没还你',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
            children: [
              _Summary(
                pendingCount: pending.length,
                pendingText: money(pendingTotal),
                doneCount: done.length,
                doneText: money(doneTotal),
              ),
              const SizedBox(height: 12),
              if (pending.isNotEmpty) ...[
                _SectionTitle('待收回 · ${pending.length} 笔'),
                const SizedBox(height: 6),
                _list(context, ref, pending, currencyOf, money,
                    pendingMode: true),
              ],
              if (pending.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Panel(
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline,
                            size: 18, color: Palette.income),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text('AA 垫付都收回来了 🎉',
                              style: TextStyle(
                                  fontSize: 13, color: Palette.inkSoft(context))),
                        ),
                      ],
                    ),
                  ),
                ),
              if (done.isNotEmpty) ...[
                const SizedBox(height: 10),
                _SectionTitle('已收清 · ${done.length} 笔'),
                const SizedBox(height: 6),
                _list(context, ref, done, currencyOf, money,
                    pendingMode: false),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _list(
    BuildContext context,
    WidgetRef ref,
    List<({Entry entry, int settledCents})> items,
    Map<int, String> currencyOf,
    String Function(int) money, {
    required bool pendingMode,
  }) {
    return Panel(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 14),
            _AaRow(
              entry: items[i].entry,
              settledCents: items[i].settledCents,
              money: money,
              pendingMode: pendingMode,
              onEditName: () => _editName(context, ref, items[i].entry),
              onAction: () => pendingMode
                  ? _settle(context, ref, items[i].entry,
                      items[i].entry.splitCents - items[i].settledCents)
                  : _unsettle(context, ref, items[i].entry),
            ),
          ],
        ],
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({
    required this.pendingCount,
    required this.pendingText,
    required this.doneCount,
    required this.doneText,
  });

  final int pendingCount;
  final String pendingText;
  final int doneCount;
  final String doneText;

  @override
  Widget build(BuildContext context) {
    return Panel(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('待收回',
                    style:
                        TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(pendingText,
                        style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            color: Palette.brand(context),
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                    const SizedBox(width: 6),
                    Text('$pendingCount 笔',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                  ],
                ),
              ],
            ),
          ),
          Container(width: 1, height: 34, color: Palette.hairline(context)),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('已收清',
                  style:
                      TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
              const SizedBox(height: 4),
              Text('$doneText · $doneCount 笔',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Palette.inkSoft(context))),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 2),
      child: Text(text,
          style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Palette.inkSoft(context))),
    );
  }
}

class _AaRow extends StatelessWidget {
  const _AaRow({
    required this.entry,
    required this.settledCents,
    required this.money,
    required this.pendingMode,
    required this.onEditName,
    required this.onAction,
  });

  final Entry entry;
  final int settledCents;
  final String Function(int) money;
  final bool pendingMode;
  final VoidCallback onEditName;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final left = (entry.splitCents - settledCents).clamp(0, entry.splitCents);
    final person = (entry.aaCounterparty ?? '').trim();
    final memo = entry.memo.trim();
    // 标题优先欠款人，其次备注；副标题带日期与代付/已收。
    final title = person.isNotEmpty ? person : (memo.isEmpty ? 'AA 垫付' : memo);
    final sub = [
      dayLabel(entry.day),
      pendingMode ? '代付 ${money(entry.splitCents)}' : '已收 ${money(settledCents)}',
      if (person.isNotEmpty && memo.isNotEmpty) memo,
      if (person.isEmpty) '点按记欠款人',
    ].join(' · ');
    return ListTile(
      onTap: onEditName,
      leading: SizedBox(
        width: 34,
        height: 34,
        child: AppGlyph(entry.isAaSettle ? '💸' : '🤝',
            size: 20, fill: true, radius: 9),
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(sub, style: const TextStyle(fontSize: 12)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (pendingMode)
            Text(money(left),
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Palette.brand(context),
                    fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(width: 6),
          TextButton(
            onPressed: onAction,
            child: Text(pendingMode ? '收回' : '撤销',
                style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
