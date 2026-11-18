import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'app_glyph.dart';
import 'editor_page.dart';
import 'motion.dart';
import 'theme.dart';

/// 看一眼某笔流水（会员订阅卡片上「对应的那笔账」）。
///
/// 为什么是弹层而不是详情页：用户从订阅卡点进来，只想确认「这 238 块花在哪
/// 一笔」，看完就回去继续看倒计时。压一页进去会多一次返回，还把订阅列表
/// 的滚动位置藏起来了。
///
/// 需要改这笔账时返回 true，由这里 push 编辑页 —— 弹层自己 push 会在
/// sheet 关闭动画期间叠两层路由，返回时容易漏一层。
Future<void> showEntryPeek(BuildContext context, Entry entry) async {
  final wantEdit = await showAppSheet<bool>(
    context: context,
    title: '这笔账',
    builder: (_) => _EntryPeek(entry: entry),
  );
  if (wantEdit != true || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => EntryEditorPage(existing: entry)),
  );
}

class _EntryPeek extends ConsumerWidget {
  const _EntryPeek({required this.entry});

  final Entry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final pockets = ref.watch(allPocketsProvider).valueOrNull ?? const <Pocket>[];
    final buckets =
        ref.watch(allBucketsProvider).valueOrNull ?? const <Bucket>[];

    Pocket? pocket;
    for (final p in pockets) {
      if (p.id == entry.pocketId) {
        pocket = p;
        break;
      }
    }
    Bucket? bucket;
    for (final b in buckets) {
      if (b.id == entry.bucketId) {
        bucket = b;
        break;
      }
    }

    final isTransfer = entry.flow == 'transfer';
    final isIn = entry.flow == 'in';
    final deleted = entry.deletedAt != null;
    final color = isTransfer
        ? Palette.inkSoft(context)
        : (isIn ? Palette.income : Palette.expense);
    final sign = isTransfer ? '' : (isIn ? '+' : '-');
    final title = isTransfer ? '转账' : (bucket?.title ?? '未分类');
    final glyph = isTransfer ? '🔁' : (bucket?.glyph ?? '🏷️');
    final time = _timeText(entry.timeMinutes);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AppGlyph(glyph, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '$sign${settings.symbol}${centsToText(entry.amountCents)}',
                style: TextStyle(
                    fontSize: 19, fontWeight: FontWeight.w700, color: color),
              ),
            ],
          ),
          if (deleted) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Palette.expense.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(AppRadius.control),
              ),
              child: Text(
                '这笔账已经删了，在回收站里 —— 它还挂在这张会员卡上，'
                '恢复流水后会自动接上。',
                style: TextStyle(
                    fontSize: 12, color: Palette.expense, height: 1.4),
              ),
            ),
          ],
          const SizedBox(height: 14),
          _row(context, '日期', '${_dayText(entry.day)}$time'),
          _row(context, '账户', isTransfer
              ? '${pocket?.title ?? '已删除账户'} → ${_pocketName(pockets, entry.toPocketId)}'
              : (pocket?.title ?? '已删除账户')),
          if (isTransfer) ...[
            if (entry.feeCents > 0)
              _row(context, '手续费',
                  '${settings.symbol}${centsToText(entry.feeCents)}'),
            if (entry.discountCents > 0)
              _row(context, '优惠',
                  '-${settings.symbol}${centsToText(entry.discountCents)}'),
          ],
          if (entry.memo.isNotEmpty) _row(context, '备注', entry.memo),
          if (entry.tags.isNotEmpty) _row(context, '标签', entry.tags),
          if (entry.excludeFromStats) _row(context, '统计', '不计入收支'),
          if (entry.splitCents > 0)
            _row(context, 'AA 分摊',
                '他人承担 ${settings.symbol}${centsToText(entry.splitCents)}'
                '${(entry.aaCounterparty ?? '').isEmpty ? '' : ' · ${entry.aaCounterparty}'}'),
          const SizedBox(height: 16),
          Row(
            children: [
              if (!deleted) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('编辑这笔账'),
                  ),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('知道了'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 56,
            child: Text(label,
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 13, color: Palette.ink(context), height: 1.35)),
          ),
        ],
      ),
    );
  }

  String _pocketName(List<Pocket> pockets, int? id) {
    if (id == null) return '—';
    for (final p in pockets) {
      if (p.id == id) return p.title;
    }
    return '已删除账户';
  }

  /// 'yyyy-MM-dd HH:mm'；没记时分的老账只显示日期（不编时间）。
  String _dayText(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _timeText(int? minutes) {
    if (minutes == null) return '';
    return ' ${(minutes ~/ 60).toString().padLeft(2, '0')}:'
        '${(minutes % 60).toString().padLeft(2, '0')}';
  }
}
