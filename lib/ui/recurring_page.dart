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
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(n == 0 ? '没有需要补记的账单' : '已补记 $n 笔')),
              );
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
            ? const EmptyView(
                icon: Icons.repeat, title: '还没有周期账单', hint: '房租、会员订阅、工资都可以加成周期')
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
                              '${list[i].lastRunMonth.isEmpty ? '' : ' · 上次生成 ${list[i].lastRunMonth}'}',
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
                                    await store.updateRecurring(Recurring(
                                      id: list[i].id,
                                      bookId: list[i].bookId,
                                      title: list[i].title,
                                      bucketId: list[i].bucketId,
                                      pocketId: list[i].pocketId,
                                      flow: list[i].flow,
                                      amountCents: list[i].amountCents,
                                      dayOfMonth: list[i].dayOfMonth,
                                      lastRunMonth: list[i].lastRunMonth,
                                      enabled: v,
                                    ));
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
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('先建一个账户，才能设周期账单')));
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
                Row(
                  children: [
                    Text('每月几号',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Palette.inkSoft(context))),
                    const Spacer(),
                    Text('$dayOfMonth 日',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Palette.brand(context))),
                  ],
                ),
                Slider(
                  value: dayOfMonth.toDouble(),
                  min: 1,
                  max: 28,
                  divisions: 27,
                  label: '$dayOfMonth 日',
                  onChanged: (v) => setState(() => dayOfMonth = v.round()),
                ),
                const SizedBox(height: 6),
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
      await store.addRecurring(Recurring(
        id: 0,
        bookId: book.id,
        title: title.trim(),
        bucketId: bucketId,
        pocketId: pocketId,
        flow: flow,
        amountCents: amount,
        dayOfMonth: dayOfMonth,
        lastRunMonth: monthKey(DateTime.now()), // 本月不重复生成
        enabled: true,
      ));
    } else {
      await store.updateRecurring(Recurring(
        id: r.id,
        bookId: r.bookId,
        title: title.trim(),
        bucketId: bucketId,
        pocketId: pocketId,
        flow: flow,
        amountCents: amount,
        dayOfMonth: dayOfMonth,
        lastRunMonth: r.lastRunMonth,
        enabled: r.enabled,
      ));
    }
    bumpRevision(ref);
  }
}
