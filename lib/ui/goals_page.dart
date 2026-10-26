import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import 'amount_keypad.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 储蓄目标：目标金额 + 已攒金额 + 期限。
///
/// 这一版是「手动记账式」目标：自己往里加减已攒金额，不做自动扣款——
/// 记账 App 没有银行接口，凭空"自动攒钱"是假功能。
class GoalsPage extends ConsumerWidget {
  const GoalsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goalsAsync = ref.watch(goalsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('储蓄目标')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: goalsAsync.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(height: 72),
        error: (e, _) => Center(child: LoadError(error: e)),
        data: (goals) => goals.isEmpty
            ? const EmptyView(
                icon: Icons.flag_outlined,
                title: '还没有目标',
                hint: '比如「旅行基金 5000」')
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 96),
                children: [
                  for (final g in goals) ...[
                    _GoalCard(goal: g, onEdit: () => _edit(context, ref, g)),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Goal? goal) async {
    final book = await ref.read(activeBookProvider.future);
    if (!context.mounted) return;
    String title = goal?.title ?? '';
    // 常驻 controller：放在 build 里每帧新建会让光标跳到开头、
    // 敲一半点图标/下拉就丢位置（这个坑在记账备注框踩过，这里不能再犯）。
    final titleCtrl = TextEditingController(text: title);
    String glyph = goal?.glyph ?? '🎯';
    int targetCents = goal?.targetCents ?? 0;
    int savedCents = goal?.savedCents ?? 0;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(goal == null ? '新增目标' : '编辑目标'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTextField(
                label: '目标名称',
                controller: titleCtrl,
                hint: '例如 旅行基金、换台电脑',
                onChanged: (v) => title = v,
              ),
              const SizedBox(height: 14),
              AmountField(
                label: '目标金额',
                cents: targetCents,
                hint: '想攒到多少',
                onChanged: (v) => setState(() => targetCents = v),
              ),
              const SizedBox(height: 14),
              AmountField(
                label: '已攒金额',
                cents: savedCents,
                helper: '已经存进去的部分，没有就留空',
                onChanged: (v) => setState(() => savedCents = v),
              ),
            ],
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
    final store = await ref.read(storeProvider.future);
    final target = targetCents;
    final saved = savedCents;
    if (target <= 0) return;
    if (goal == null) {
      await store.addGoal(
        bookId: book.id,
        title: title.trim().isEmpty ? '新目标' : title.trim(),
        glyph: glyph,
        targetCents: target,
        savedCents: saved,
      );
    } else {
      await store.updateGoal(Goal(
        id: goal.id,
        bookId: goal.bookId,
        title: title.trim().isEmpty ? goal.title : title.trim(),
        glyph: glyph,
        targetCents: target,
        savedCents: saved,
        dueDay: goal.dueDay,
      ));
    }
    bumpRevision(ref);
  }
}

class _GoalCard extends ConsumerWidget {
  const _GoalCard({required this.goal, required this.onEdit});

  final Goal goal;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ratio = goal.targetCents <= 0
        ? 0.0
        : (goal.savedCents / goal.targetCents).clamp(0.0, 1.0);
    final done = goal.savedCents >= goal.targetCents;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppGlyph(goal.glyph, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(goal.title,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz, size: 20),
                onSelected: (v) async {
                  if (v == 'edit') {
                    if (context.mounted) onEdit();
                  } else if (v == 'add') {
                    await _adjust(context, ref, 1);
                  } else if (v == 'delete') {
                    if (!context.mounted) return;
                    await _delete(context, ref);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'add', child: Text('记一笔存入')),
                  PopupMenuItem(value: 'edit', child: Text('编辑')),
                  PopupMenuItem(value: 'delete', child: Text('删除')),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              MoneyText(goal.savedCents,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w700)),
              Padding(
                padding: const EdgeInsets.only(bottom: 3, left: 4),
                child: Text(' / ${_yuan(goal.targetCents)}',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkFaint(context))),
              ),
              const Spacer(),
              Text('${(ratio * 100).round()}%',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: done ? Palette.income : Palette.brand(context))),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: Palette.hairline(context),
              valueColor: AlwaysStoppedAnimation(
                  done ? Palette.income : Palette.brand(context)),
            ),
          ),
          if (goal.dueDay != null) ...[
            const SizedBox(height: 8),
            Text('目标日期 ${dayLabel(goal.dueDay!)}',
                style:
                    TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
          ],
        ],
      ),
    );
  }

  static String _yuan(int cents) => centsToText(cents);

  Future<void> _adjust(BuildContext context, WidgetRef ref, int sign) async {
    final v = await showAmountKeypad(
      context,
      title: sign > 0 ? '存入金额' : '取出金额',
    );
    if (v == null || v <= 0) return;
    final store = await ref.read(storeProvider.future);
    await store.updateGoal(Goal(
      id: goal.id,
      bookId: goal.bookId,
      title: goal.title,
      glyph: goal.glyph,
      targetCents: goal.targetCents,
      savedCents: (goal.savedCents + v * sign).clamp(0, 1 << 62),
      dueDay: goal.dueDay,
    ));
    bumpRevision(ref);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${goal.title}」？'),
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
    await store.deleteGoal(goal.id);
    bumpRevision(ref);
  }
}
