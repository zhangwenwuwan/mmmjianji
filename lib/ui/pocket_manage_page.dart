import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import 'account_edit_page.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 账户图标可选集（账户管理页和资产页的「添加账户」共用）
const pocketGlyphs = [
  '👛',
  '💳',
  '🏦',
  '💵',
  '🪙',
  '📱',
  '🎫',
  '🏠',
  '🚗',
  '💎'
];

/// 新增 / 编辑账户对话框。
///
/// 提取成公开函数，好让「资产」页的 AppBar 也能直接调起添加账户，
/// 不用先跳去账户管理页（参考版资产页右上角就是添加账户）。
/// 新增 / 编辑账户：跳到独立编辑页。
///
/// 之前是 AlertDialog，字段一多就被键盘顶穿、类型只是个下拉框、也没有预览。
/// 现在统一走 [AccountEditPage]，这里只做「跳转 + 刷新」这一件事。
/// 保留这个函数名，是为了让「资产」页、账户列表页、账户详情页的调用点不变。
/// 新增 / 编辑账户：跳到独立编辑页。
///
/// 之前是 AlertDialog，字段一多就被键盘顶穿、类型只是个下拉框、也没有预览。
/// 现在统一走 [AccountEditPage]，这里只做「跳转 + 刷新」这一件事。
/// 保留这个函数名，是为了让「资产」页、账户列表页、账户详情页的调用点不变。
Future<void> showPocketEditor(
    BuildContext context, WidgetRef ref, Pocket? pocket) async {
  await Navigator.of(context).push(
    AppPageRoute(page: AccountEditPage(pocket: pocket)),
  );
}

/// 账户管理：增 / 改 / 归档 /（无流水时）删除。
class PocketManagePage extends ConsumerWidget {
  const PocketManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allAsync = ref.watch(allPocketsProvider);
    final balances = ref.watch(balancesProvider).valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('账户管理')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showPocketEditor(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: allAsync.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(),
        error: (e, _) => Center(child: LoadError(error: e)),
        data: (pockets) {
          final active = pockets.where((p) => !p.archived).toList();
          final archived = pockets.where((p) => p.archived).toList();
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
            children: [
              SectionLabel('使用中的账户'),
              Panel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < active.length; i++) ...[
                      if (i > 0) const Divider(height: 1, indent: 56),
                      _row(context, ref, active[i], balances, archived: false),
                    ],
                    if (active.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('还没有账户，点右下角添加'),
                      ),
                  ],
                ),
              ),
              if (archived.isNotEmpty) ...[
                const SizedBox(height: 18),
                SectionLabel('已归档'),
                Panel(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      for (var i = 0; i < archived.length; i++) ...[
                        if (i > 0) const Divider(height: 1, indent: 56),
                        _row(context, ref, archived[i], balances,
                            archived: true),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Text(
                '有流水的账户不能删除，只能归档（历史记录还要指着它显示名字）。',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context)),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(BuildContext context, WidgetRef ref, Pocket p,
      List<({Pocket pocket, int balanceCents})> balances,
      {required bool archived}) {
    int? balance;
    for (final b in balances) {
      if (b.pocket.id == p.id) balance = b.balanceCents;
    }
    // 按账户类型给不同图标与底色，和资产页的卡面呼应
    final (icon, tint) = switch (p.kind) {
      PocketKind.credit => (Icons.credit_card, const Color(0xFF3B3F58)),
      PocketKind.bank => (Icons.account_balance, const Color(0xFF3E7BB6)),
      PocketKind.debt => (Icons.trending_down, Palette.expense),
      PocketKind.cash => (Icons.payments_outlined, Palette.inkSoft(context)),
    };
    // 信用卡补一行额度信息，不然光看欠款不知道离额度还有多远
    // 可用额度按「当前欠款」算。用期初算会一直显示开卡那天的数字。
    final available = p.availableFrom(balance ?? p.openingCents);
    final limitText = p.kind == PocketKind.credit && p.creditLimitCents > 0
        ? ' · 额度 ${centsToText(p.creditLimitCents)}'
            ' · 可用 ${centsToText(available ?? 0)}'
        : '';
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 18, color: tint),
      ),
      title: Text(p.title),
      subtitle: Text(
        '${p.kind.label} · ${nameOf(p.currency)}$limitText'
        '${archived ? ' · 已归档' : ''}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (balance != null)
            MoneyText(
              balance,
              suffix: amountSuffix(
                  p.currency,
                  ref.watch(activeBookProvider).valueOrNull?.baseCurrency ??
                      'CNY'),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          const SizedBox(width: 4),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz, size: 18),
            onSelected: (v) async {
              switch (v) {
                case 'edit':
                  await showPocketEditor(context, ref, p);
                case 'archive':
                  await _toggleArchive(ref, p, !p.archived);
                case 'delete':
                  await _delete(context, ref, p);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(
                  value: 'archive', child: Text(p.archived ? '取消归档' : '归档')),
              const PopupMenuItem(value: 'delete', child: Text('删除')),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _toggleArchive(WidgetRef ref, Pocket p, bool archived) async {
    final store = await ref.read(storeProvider.future);
    await store.archivePocket(p.id, archived);
    bumpRevision(ref);
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Pocket p) async {
    final store = await ref.read(storeProvider.future);
    final hasEntries = await store.pocketHasEntries(p.id);
    if (!context.mounted) return;
    if (hasEntries) {
      ScaffoldMessenger.of(context).toast('该账户还有流水，不能删除。可以改成归档。');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${p.title}」？'),
        content: const Text('这个账户没有流水，删除后不可恢复。'),
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
    await store.deletePocketIfEmpty(p.id);
    bumpRevision(ref);
  }
}
