import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'amount_keypad.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 借贷：我借出去的（待收）和我借进来的（待还）。
class LoansPage extends ConsumerStatefulWidget {
  const LoansPage({super.key});

  @override
  ConsumerState<LoansPage> createState() => _LoansPageState();
}

class _LoansPageState extends ConsumerState<LoansPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final openAsync = ref.watch(debtsProvider);
    final closedAsync = ref.watch(closedDebtsProvider);
    final paid = ref.watch(debtPaidProvider).valueOrNull ?? const {};
    final settings = ref.watch(settingsProvider);
    final book = ref.watch(activeBookProvider).valueOrNull;
    final base = book?.baseCurrency ?? 'CNY';
    final rates = ref.watch(ratesProvider).valueOrNull ?? const {};

    int outstanding(Debt d) =>
        (d.principalCents - (paid[d.id] ?? 0)).clamp(0, 1 << 62);

    int inBase(Debt d) => toBaseCents(outstanding(d), d.currency, base, rates);

    return Scaffold(
      appBar: AppBar(
        title: const Text('借贷'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [Tab(text: '进行中'), Tab(text: '已结清')],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          openAsync.when(
            skipLoadingOnReload: true,
            loading: () => const SkeletonList(),
            error: (e, _) => Center(child: LoadError(error: e)),
            data: (list) {
              final lend = list.where((d) => d.isLend).toList();
              final borrow = list.where((d) => !d.isLend).toList();
              final lendTotal = lend.fold<int>(0, (s, d) => s + inBase(d));
              final borrowTotal = borrow.fold<int>(0, (s, d) => s + inBase(d));
              return ListView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _sumCard(
                          context,
                          '待收（别人欠我）',
                          lendTotal,
                          Palette.income,
                          settings,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _sumCard(
                          context,
                          '待还（我欠别人）',
                          borrowTotal,
                          Palette.expense,
                          settings,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (list.isEmpty)
                    const EmptyView(
                      icon: Icons.handshake_outlined,
                      title: '没有未结清的借贷',
                      hint: '借给朋友、刷信用卡分期，都可以在这里记一笔',
                    )
                  else ...[
                    if (lend.isNotEmpty) ...[
                      SectionLabel('我借出去的'),
                      Panel(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (var i = 0; i < lend.length; i++) ...[
                              if (i > 0) const Divider(height: 1, indent: 56),
                              _debtRow(context, ref, lend[i], paid, base),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (borrow.isNotEmpty) ...[
                      SectionLabel('我借进来的'),
                      Panel(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (var i = 0; i < borrow.length; i++) ...[
                              if (i > 0) const Divider(height: 1, indent: 56),
                              _debtRow(context, ref, borrow[i], paid, base),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ],
              );
            },
          ),
          closedAsync.when(
            skipLoadingOnReload: true,
            loading: () => const SkeletonList(),
            error: (e, _) => Center(child: LoadError(error: e)),
            data: (list) => list.isEmpty
                ? const EmptyView(
                    icon: Icons.done_all,
                    title: '还没有结清的记录',
                    hint: '在一笔借贷里点「还款 / 收回」，还清后会归档到这里')
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
                    children: [
                      Panel(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            for (var i = 0; i < list.length; i++) ...[
                              if (i > 0) const Divider(height: 1, indent: 56),
                              _debtRow(context, ref, list[i], paid, base),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _sumCard(BuildContext context, String label, int cents, Color color,
      AppSettings settings) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              settings.hideAmounts
                  ? '****'
                  : '${settings.symbol}${centsToText(cents)}',
              style: TextStyle(
                fontSize: 20,
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

  Widget _debtRow(BuildContext context, WidgetRef ref, Debt d,
      Map<int, int> paid, String base) {
    final paidCents = paid[d.id] ?? 0;
    final left = (d.principalCents - paidCents).clamp(0, 1 << 62);
    // 逾期只比「日期」，不比时刻：10 号到期的账，10 号当天不算逾期。
    // 原来用 dueOn.isBefore(now)，到期日凌晨 00:00 一过就变红，实际还没到期。
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = d.dueOn == null
        ? null
        : DateTime(d.dueOn!.year, d.dueOn!.month, d.dueOn!.day);
    final overdue =
        dueDay != null && !d.closed && dueDay.isBefore(today) && left > 0;
    return PressScale(
      scale: 0.98,
      onTap: () => _detail(context, ref, d),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: (d.isLend ? Palette.income : Palette.expense)
                    .withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(d.isLend ? Icons.call_made : Icons.call_received,
                  size: 16, color: d.isLend ? Palette.income : Palette.expense),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(d.counterparty,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500)),
                  Text(
                    [
                      _channelLabel(d.channel),
                      if (d.dueOn != null)
                        '${dayKey(d.dueOn!)}${overdue ? ' · 已逾期' : ' 到期'}',
                      if (paidCents > 0)
                        '已还 ${(paidCents / 100).toStringAsFixed(0)}',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color:
                          overdue ? Palette.expense : Palette.inkFaint(context),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                MoneyText(
                  left,
                  suffix: amountSuffix(d.currency, base),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: d.isLend ? Palette.ink(context) : Palette.expense,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (paidCents > 0)
                  Text('共 ${(d.principalCents / 100).toStringAsFixed(0)}',
                      style: TextStyle(
                          fontSize: 10.5, color: Palette.inkFaint(context))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static String _channelLabel(String c) => switch (c) {
        'bank' => '银行',
        'online' => '网贷',
        _ => '个人',
      };

  Future<void> _detail(BuildContext context, WidgetRef ref, Debt d) async {
    final store = await ref.read(storeProvider.future);
    final payments = await store.debtPayments(d.id);
    if (!context.mounted) return;
    final paid = payments.fold<int>(0, (s, p) => s + p.amountCents);
    final left = (d.principalCents - paid).clamp(0, 1 << 62);
    final paidText = d.isLend ? '收回' : '还款';
    final remainingLabel = d.isLend ? '待收 ' : '还欠 ';
    await showAppSheet<void>(
      context: context,
      title: '借贷详情',
      scrollable: false,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${d.isLend ? '借给' : '借自'} ${d.counterparty}',
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const Spacer(),
                Text(
                    '${(d.principalCents / 100).toStringAsFixed(2)} ${d.currency}',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context))),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${dayKey(d.borrowedOn)} ${d.isLend ? '借出' : '借入'}'
              '${d.dueOn == null ? '' : ' · ${dayKey(d.dueOn!)} 到期'}'
              '${d.note.isEmpty ? '' : ' · ${d.note}'}',
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context)),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Text(remainingLabel,
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkFaint(context))),
                MoneyText(left,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _addPayment(context, ref, d, left);
                  },
                  icon: const Icon(Icons.add, size: 16),
                  label: Text('记一笔$paidText'),
                ),
              ],
            ),
            const Divider(),
            Text('$paidText记录（${payments.length}）',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
            const SizedBox(height: 6),
            if (payments.isEmpty)
              Text('还没有$paidText记录',
                  style:
                      TextStyle(fontSize: 12, color: Palette.inkFaint(context)))
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      for (final p in payments)
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text((p.amountCents / 100).toStringAsFixed(2),
                              style: const TextStyle(fontSize: 14)),
                          subtitle: Text(
                              '${dayKey(p.paidOn)}${p.note.isEmpty ? '' : ' · ${p.note}'}',
                              style: const TextStyle(fontSize: 12)),
                          trailing: IconButton(
                            icon: const Icon(Icons.close, size: 16),
                            onPressed: () async {
                              await store.deleteDebtPayment(p.id);
                              if (!context.mounted) return;
                              bumpRevision(ref);
                              Navigator.pop(ctx);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await _edit(context, ref, d);
                  },
                  child: const Text('编辑'),
                ),
                TextButton(
                  onPressed: () async {
                    await store.setDebtClosed(d.id, !d.closed);
                    if (!context.mounted) return;
                    bumpRevision(ref);
                    Navigator.pop(ctx);
                  },
                  child: Text(d.closed ? '恢复进行中' : '标记结清'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    await store.deleteDebt(d.id);
                    if (!context.mounted) return;
                    bumpRevision(ref);
                    Navigator.pop(ctx);
                  },
                  child: Text('删除', style: TextStyle(color: Palette.expense)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addPayment(
      BuildContext context, WidgetRef ref, Debt d, int leftCents) async {
    // 统一走 App 自己的计算器键盘（和系统键盘混用会让手感割裂）
    final cents = await showAmountKeypad(
      context,
      initialCents: leftCents > 0 ? leftCents : 0,
      title: d.isLend ? '收回金额' : '还款金额',
    );
    if (cents == null || cents <= 0) return;
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    await store.addDebtPayment(
      bookId: book.id,
      debtId: d.id,
      amountCents: cents,
      paidOn: DateTime.now(),
    );
    // 还清了就自动结清，省一步操作
    final paidMap = await store.debtPaidMap(book.id);
    if ((paidMap[d.id] ?? 0) >= d.principalCents) {
      await store.setDebtClosed(d.id, true);
    }
    if (!context.mounted) return;
    bumpRevision(ref);
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Debt? debt) =>
      showDebtEditor(context, ref, debt);
}

/// 记一笔借贷 / 编辑借贷的表单。
///
/// **做成顶层函数**而不是页面里的私有方法，是因为两个地方都要用它：
/// 借贷页的悬浮按钮，和记账页的「债务」tab。抄两份的话，加一个字段就会漏一处。
/// 返回是否真的保存了。
Future<bool> showDebtEditor(
    BuildContext context, WidgetRef ref, Debt? debt) async {
  final book = await ref.read(activeBookProvider.future);
  String direction = debt?.direction ?? 'lend';
  String counterparty = debt?.counterparty ?? '';
  // 常驻 controller：放在 build 里每帧新建会让光标跳到开头、
  // 敲一半点图标/下拉就丢位置（这个坑在记账备注框踩过，这里不能再犯）。
  final counterpartyCtrl = TextEditingController(text: counterparty);
  String channel = debt?.channel ?? 'personal';
  String currency = debt?.currency ?? book.baseCurrency;
  DateTime borrowedOn = debt?.borrowedOn ?? DateTime.now();
  DateTime? dueOn = debt?.dueOn;
  int amountCents = debt?.principalCents ?? 0;
  final noteCtrl = TextEditingController(text: debt?.note ?? '');

  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(debt == null ? '记一笔借贷' : '编辑借贷'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ChoiceChip(
                    label: const Text('我借出'),
                    selected: direction == 'lend',
                    onSelected: (_) => setState(() => direction = 'lend'),
                  ),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('我借入'),
                    selected: direction == 'borrow',
                    onSelected: (_) => setState(() => direction = 'borrow'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                direction == 'lend' ? '我借出，等待对方还款' : '我借入，等待我向对方还款',
                style: TextStyle(
                  fontSize: 12,
                  color: Palette.inkFaint(ctx),
                ),
              ),
              const SizedBox(height: 8),
              AppTextField(
                label: '对方',
                controller: counterpartyCtrl,
                hint: '姓名 / 机构',
                onChanged: (v) => counterparty = v,
              ),
              const SizedBox(height: 14),
              AmountField(
                label: '金额',
                cents: amountCents,
                onChanged: (v) => setState(() => amountCents = v),
              ),
              const SizedBox(height: 14),
              AppDropdown<String>(
                label: '渠道',
                value: channel,
                items: const [
                  DropdownMenuItem(value: 'personal', child: Text('个人')),
                  DropdownMenuItem(value: 'bank', child: Text('银行')),
                  DropdownMenuItem(value: 'online', child: Text('网贷')),
                ],
                onChanged: (v) => setState(() => channel = v ?? channel),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: borrowedOn,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) {
                          setState(() => borrowedOn = picked);
                        }
                      },
                       child: Text('${direction == 'lend' ? '借出日' : '借入日'} ${dayKey(borrowedOn)}',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                  Expanded(
                    child: TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: dueOn ?? borrowedOn,
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (picked != null) setState(() => dueOn = picked);
                      },
                      child: Text(
                          dueOn == null ? '到期日（可选）' : '到期 ${dayKey(dueOn!)}',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ),
              AppTextField(
                label: '备注',
                controller: noteCtrl,
                hint: '用途 / 约定',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    ),
  );
  if (ok != true) return false;
  final cents = amountCents;
  if (cents <= 0 || counterparty.trim().isEmpty) return false;
  final store = await ref.read(storeProvider.future);
  if (debt == null) {
    await store.addDebt(Debt(
      id: 0,
      bookId: book.id,
      direction: direction,
      counterparty: counterparty.trim(),
      channel: channel,
      principalCents: cents,
      currency: currency,
      borrowedOn: borrowedOn,
      dueOn: dueOn,
      note: noteCtrl.text.trim(),
      interestRate: null,
      closed: false,
    ));
  } else {
    await store.updateDebt(debt.copyWith(
      direction: direction,
      counterparty: counterparty.trim(),
      channel: channel,
      principalCents: cents,
      borrowedOn: borrowedOn,
      dueOn: dueOn,
      // 清空到期日要能真正写进库（null 的语义是「清除」）
      clearDueOn: dueOn == null,
      note: noteCtrl.text.trim(),
    ));
  }
  if (!context.mounted) return false;
  bumpRevision(ref);
  return true;
}
