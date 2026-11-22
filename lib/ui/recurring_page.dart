import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import 'amount_keypad.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 周期记账：每月固定日期自动生成一笔（房租、订阅、工资…）。
///
/// 不依赖系统通知：打开 App 时会把「已经到期的月份」补齐，并在页面顶部
/// 提示补了几笔。定时推送属于原生通知能力，下一轮再做。
class RecurringPage extends ConsumerWidget {
  const RecurringPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(recurringsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('周期记账'),
        actions: [
          IconButton(
            tooltip: '立即补记到期账单',
            onPressed: () async {
              final store = await ref.read(storeProvider.future);
              final book = await ref.read(activeBookProvider.future);
              final n = await store.applyDueRecurring(book.id, DateTime.now());
              bumpRevision(ref);
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).toast(n == 0 ? '没有需要补记的账单' : '已补记 $n 笔');
            },
            icon: const Icon(Icons.play_circle_outline),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => ListView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
          children: const [
            Skeleton(height: 64, radius: 14),
            SizedBox(height: 8),
            Skeleton(height: 64, radius: 14),
            SizedBox(height: 8),
            Skeleton(height: 64, radius: 14),
          ],
        ),
        error: (e, _) => Center(child: LoadError(error: e)),
        data: (list) => list.isEmpty
            // 居中：原来直接丢在 body 里，空状态会贴在左上角，
            // 加上长提示被切边，整页像没排完。
            ? const Center(
                child: EmptyView(
                    icon: Icons.repeat,
                    title: '还没有周期账单',
                    hint: '房租、会员订阅、工资都可以加成周期'))
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
                children: [
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (var i = 0; i < list.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            title: Text(list[i].title),
                            subtitle: Text(
                              '每月 ${list[i].dayOfMonth} 日 · '
                              '${list[i].flow == 'in' ? '收入' : '支出'} '
                              '${(list[i].amountCents / 100).toStringAsFixed(2)}'
                              '${_term(list[i])}',
                              style: const TextStyle(fontSize: 12),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                JellySwitch(
                                  value: list[i].enabled,
                                  onChanged: (v) async {
                                    final store =
                                        await ref.read(storeProvider.future);
                                    await store.updateRecurring(
                                        list[i].copyWith(enabled: v));
                                    bumpRevision(ref);
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.more_horiz, size: 18),
                                  onPressed: () => _menu(context, ref, list[i]),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '打开 App 时会自动补齐到期账单；同一个月不会重复生成。'
                    '关掉开关即暂停，已生成的记录不受影响。',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: Palette.inkFaint(context)),
                  ),
                ],
              ),
      ),
    );
  }

  /// 副标题里那段「什么时候结束」。
  ///
  /// 三种模式都要一眼看懂：永不结束 / 还剩几次 / 到哪天为止。
  static String _term(Recurring r) {
    switch (r.endMode) {
      case 'count':
        final left = r.endCount - r.runCount;
        if (left <= 0) return ' · 已结束（共 ${r.endCount} 次）';
        return ' · 共 ${r.endCount} 次，还剩 $left 次';
      case 'until':
        if (r.endOn == null) return '';
        return ' · 到 ${dayKey(r.endOn!)} 为止';
      default:
        return r.lastRunMonth.isEmpty ? '' : ' · 上次生成 ${r.lastRunMonth}';
    }
  }

  Future<void> _menu(BuildContext context, WidgetRef ref, Recurring r) async {
    final v = await showAppSheet<String>(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('编辑'),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: Palette.expense),
            title: Text('删除', style: TextStyle(color: Palette.expense)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ],
      ),
    );
    if (v == 'edit') {
      if (!context.mounted) return;
      await _edit(context, ref, r);
    } else if (v == 'delete') {
      final store = await ref.read(storeProvider.future);
      await store.deleteRecurring(r.id);
      bumpRevision(ref);
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Recurring? r) async {
    final book = await ref.read(activeBookProvider.future);
    final pockets = await ref.read(pocketsProvider.future);
    // 周期账单必须落到某个账户上。一个账户都没有时不弹表单，
    // 直接告诉用户先去建账户（静默 return 用户会以为按钮坏了）。
    if (pockets.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).toast('先建一个账户，才能设周期账单');
      }
      return;
    }
    if (!context.mounted) return;
    String title = r?.title ?? '';
    // 常驻 controller：放在 build 里每帧新建会让光标跳到开头、
    // 敲一半点图标/下拉就丢位置（这个坑在记账备注框踩过，这里不能再犯）。
    final titleCtrl = TextEditingController(text: title);
    String flow = r?.flow ?? 'out';
    int dayOfMonth = r?.dayOfMonth ?? 1;
    int pocketId = r?.pocketId ?? pockets.first.id;
    int? bucketId = r?.bucketId;
    int amountCents = r?.amountCents ?? 0;
    DateTime? startOn = r?.startOn;
    String endMode = r?.endMode ?? 'never';
    int endCount = (r?.endCount ?? 0) > 0 ? r!.endCount : 12;
    DateTime? endOn = r?.endOn;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(r == null ? '新增周期账单' : '编辑周期账单'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTextField(
                  label: '名称',
                  controller: titleCtrl,
                  hint: '例如 房租、网飞会员',
                  helper: '会自动记成流水的备注',
                  onChanged: (v) => title = v,
                ),
                const SizedBox(height: 14),
                AmountField(
                  label: '金额',
                  cents: amountCents,
                  onChanged: (v) => setState(() => amountCents = v),
                ),
                const SizedBox(height: 14),
                // 每月几号：步进器。
                //
                // 原来是个 1~28 的 Slider（27 个刻度）：白拇指压在白底上，
                // 只剩一排点状刻度和半个圆 —— 看着像控件没画出来。
                // 而且拖 27 格在手机上根本对不准具体某一天。
                Row(
                  children: [
                    Text('每月几号',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Palette.inkSoft(ctx))),
                    const Spacer(),
                    _StepButton(
                      icon: Icons.remove,
                      onTap: () => setState(
                          () => dayOfMonth = (dayOfMonth - 1).clamp(1, 28)),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text('$dayOfMonth 日',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: Palette.brand(ctx))),
                    ),
                    _StepButton(
                      icon: Icons.add,
                      onTap: () => setState(
                          () => dayOfMonth = (dayOfMonth + 1).clamp(1, 28)),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 开始时间：默认今天。选了未来的月份，那之前不会补记。
                _FormRow(
                  label: '开始时间',
                  value: startOn == null ? '立即开始' : '${dayKey(startOn!)} 起',
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: startOn ?? DateTime.now(),
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) setState(() => startOn = picked);
                  },
                ),
                const SizedBox(height: 10),
                // 结束方式：三选一，和截图里那种底部选项一致。
                Text('结束方式',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: Palette.inkSoft(ctx))),
                const SizedBox(height: 6),
                Wrap(
                  // 三个胶囊在 361dp 的屏幕上刚好差一点点，收一点内边距排成一行
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final e in const [
                      ('never', '永不结束'),
                      ('count', '执行 N 次'),
                      ('until', '到某天结束'),
                    ])
                      _ModeChip(
                        label: e.$2,
                        selected: endMode == e.$1,
                        onTap: () => setState(() => endMode = e.$1),
                      ),
                  ],
                ),
                if (endMode == 'count') ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text('共执行',
                          style: TextStyle(
                              fontSize: 12, color: Palette.inkSoft(ctx))),
                      const Spacer(),
                      _StepButton(
                        icon: Icons.remove,
                        onTap: () => setState(
                            () => endCount = (endCount - 1).clamp(1, 600)),
                      ),
                      SizedBox(
                        width: 64,
                        child: Text('$endCount 次',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: Palette.brand(ctx))),
                      ),
                      _StepButton(
                        icon: Icons.add,
                        onTap: () => setState(
                            () => endCount = (endCount + 1).clamp(1, 600)),
                      ),
                    ],
                  ),
                ],
                if (endMode == 'until') ...[
                  const SizedBox(height: 8),
                  _FormRow(
                    label: '结束日期',
                    value: endOn == null ? '选一个日期' : dayKey(endOn!),
                    warn: endOn == null,
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: ctx,
                        initialDate: endOn ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) setState(() => endOn = picked);
                    },
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: AppDropdown<String>(
                        label: '类型',
                        value: flow,
                        items: const [
                          DropdownMenuItem(value: 'out', child: Text('支出')),
                          DropdownMenuItem(value: 'in', child: Text('收入')),
                        ],
                        onChanged: (v) => setState(() => flow = v ?? flow),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: AppDropdown<int>(
                        label: '账户',
                        value: pocketId,
                        items: [
                          for (final p in pockets)
                            DropdownMenuItem(value: p.id, child: Text(p.title)),
                          // 账户被归档后不在 pockets 里，而 DropdownButton 要求
                          // value 必须命中恰好一个 item，否则直接断言崩。
                          // 这里补一条占位项，既保住 value 有效，也让用户看得懂。
                          if (!pockets.any((p) => p.id == pocketId))
                            DropdownMenuItem(
                                value: pocketId, child: const Text('（已归档账户）')),
                        ],
                        onChanged: (v) =>
                            setState(() => pocketId = v ?? pocketId),
                      ),
                    ),
                  ],
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
    if (ok != true) return;
    final amount = amountCents;
    if (amount <= 0 || title.trim().isEmpty) return;
    final store = await ref.read(storeProvider.future);
    if (r == null) {
      // lastRunMonth 对齐 startOn 的上一个月：
      // 生成器从这个月之后开始扫，再靠 startOn 把「起始日之前的那一期」滤掉。
      // 直接写当月会让「从下个月开始」变成"这个月也不生成"，
      // 而写上月又会在起始日已过时把当月补出来 —— 两个都要 startOn 兜底。
      final now = DateTime.now();
      final startMonth = DateTime(
          (startOn ?? now).year, (startOn ?? now).month);
      final lastRun = monthKey(DateTime(startMonth.year, startMonth.month - 1));
      await store.addRecurring(Recurring(
        id: 0,
        bookId: book.id,
        title: title.trim(),
        bucketId: bucketId,
        pocketId: pocketId,
        flow: flow,
        amountCents: amount,
        dayOfMonth: dayOfMonth,
        lastRunMonth: lastRun,
        enabled: true,
        startOn: startOn,
        endMode: endMode,
        endCount: endMode == 'count' ? endCount : 0,
        endOn: endMode == 'until' ? endOn : null,
      ));
    } else {
      await store.updateRecurring(r.copyWith(
        title: title.trim(),
        bucketId: bucketId,
        pocketId: pocketId,
        flow: flow,
        amountCents: amount,
        dayOfMonth: dayOfMonth,
        startOn: startOn,
        clearStartOn: startOn == null,
        endMode: endMode,
        endCount: endMode == 'count' ? endCount : 0,
        endOn: endMode == 'until' ? endOn : null,
        clearEndOn: endMode != 'until',
        // 改回「永不结束」时把开关打开：之前可能是跑完次数自动关的。
        enabled: endMode == 'never' || r.enabled ? true : r.enabled,
      ));
    }
    bumpRevision(ref);
  }
}

/// 步进器上的 ± 圆按钮。
class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.9,
      onTap: onTap,
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Palette.brand(context).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Icon(icon, size: 16, color: Palette.brand(context)),
      ),
    );
  }
}

/// 「标签 —— 值 ›」的一行，点开选日期。
class _FormRow extends StatelessWidget {
  const _FormRow({
    required this.label,
    required this.value,
    required this.onTap,
    this.warn = false,
  });

  final String label;
  final String value;
  final VoidCallback onTap;

  /// 还没选（比如结束日期为空）时用警示色提醒。
  final bool warn;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.99,
      onTap: onTap,
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Palette.paper(context),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: Row(
          children: [
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Palette.inkSoft(context))),
            const Spacer(),
            Text(value,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: warn ? Palette.expense : Palette.ink(context))),
            Icon(Icons.chevron_right,
                size: 16, color: Palette.inkFaint(context)),
          ],
        ),
      ),
    );
  }
}

/// 结束方式的单选胶囊。
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.95,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? Palette.brand(context).withValues(alpha: 0.14)
              : Palette.paper(context),
          borderRadius: BorderRadius.circular(AppRadius.control),
          border: Border.all(
            color: selected
                ? Palette.brand(context)
                : Palette.inkFaint(context).withValues(alpha: 0.25),
          ),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Palette.brand(context) : Palette.inkSoft(context))),
      ),
    );
  }
}
