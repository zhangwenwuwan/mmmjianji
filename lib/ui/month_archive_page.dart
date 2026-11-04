import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'month_summary_page.dart';
import 'motion.dart';
import 'theme.dart';

/// 月度归档：把「每个月的账单」和「每个月的总结」放在同一页。
///
/// 这一页原来只读 `month_notes`（用户手写的总结），没写过总结的月份一片空白。
/// 用户反馈「上月账单归档后在这找不到」—— 不是没归档，是这页根本没读账单。
/// 现在数据源是「有流水的月份 ∪ 写过总结的月份」，点进去就是当月月报。
class MonthArchivePage extends ConsumerStatefulWidget {
  const MonthArchivePage({super.key});

  @override
  ConsumerState<MonthArchivePage> createState() => _MonthArchivePageState();
}

/// 一行归档：月份 + 当月收支 + 手写总结（可空）。
class _MonthRow {
  const _MonthRow({
    required this.month,
    required this.incomeCents,
    required this.expenseCents,
    required this.count,
    required this.note,
  });

  final String month;
  final int incomeCents;
  final int expenseCents;
  final int count;
  final String note;

  int get balanceCents => incomeCents - expenseCents;

  DateTime get date => DateTime(
        int.parse(month.substring(0, 4)),
        int.parse(month.substring(5, 7)),
      );
}

class _MonthArchivePageState extends ConsumerState<MonthArchivePage> {
  List<_MonthRow>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final months = await store.monthsWithData(book.id);
    final notes = await store.monthNotes(book.id);
    final noteOf = {for (final n in notes) n.month: n.note};

    final rows = <_MonthRow>[
      for (final m in months)
        _MonthRow(
          month: m.month,
          incomeCents: m.incomeCents,
          expenseCents: m.expenseCents,
          count: m.count,
          note: noteOf.remove(m.month) ?? '',
        ),
    ];
    // 只写过总结、但当月流水被清空/全删了的月份也要留着，否则总结等于丢了。
    for (final n in notes) {
      final note = noteOf.remove(n.month);
      if (note == null || note.isEmpty) continue;
      rows.add(_MonthRow(
        month: n.month,
        incomeCents: 0,
        expenseCents: 0,
        count: 0,
        note: note,
      ));
    }
    rows.sort((a, b) => b.month.compareTo(a.month));

    if (!mounted) return;
    setState(() => _rows = rows);
  }

  List<_MonthRow> get _withNotes =>
      (_rows ?? const []).where((r) => r.note.isNotEmpty).toList();

  Future<void> _copyAll() async {
    final list = _withNotes;
    if (list.isEmpty) return;
    final text =
        list.map((e) => '${_titleOf(e.month)}\n${e.note}').join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).toast('已复制 ${list.length} 条总结');
  }

  Future<void> _copyOne(_MonthRow row) async {
    await Clipboard.setData(ClipboardData(text: row.note));
    if (!mounted) return;
    ScaffoldMessenger.of(context).toast('已复制 ${_titleOf(row.month)} 的总结');
  }

  static String _titleOf(String month) {
    if (month.length < 7) return month;
    return '${month.substring(0, 4)} 年 ${int.parse(month.substring(5, 7))} 月';
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final now = DateTime.now();
    final currentMonth = monthKey(now);
    return Scaffold(
      appBar: AppBar(
        title: const Text('月度归档'),
        actions: [
          if (_withNotes.isNotEmpty)
            IconButton(
              tooltip: '复制全部总结',
              onPressed: _copyAll,
              icon: const Icon(Icons.copy_all_outlined),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: [
          if (rows == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Skeleton(height: 52, radius: 14),
            )
          else if (rows.isEmpty)
            const EmptyView(
              icon: Icons.calendar_month_outlined,
              title: '还没有可以回看的月份',
              hint: '记过账的月份会自动归档到这里，点进去能看当月月报；'
                  '在统计页写过「本月总结」的月份也会在这里出现。',
            )
          else ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
              child: Text(
                '共 ${rows.length} 个月 · 点月份看当月月报',
                style: TextStyle(
                    fontSize: 11.5, color: Palette.inkFaint(context)),
              ),
            ),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 14),
                    _MonthTile(
                      row: rows[i],
                      title: _titleOf(rows[i].month),
                      isCurrent: rows[i].month == currentMonth,
                      onTap: () => Navigator.of(context).push(
                        AppPageRoute(page: MonthSummaryPage(month: rows[i].date)),
                      ),
                      onCopyNote:
                          rows[i].note.isEmpty ? null : () => _copyOne(rows[i]),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MonthTile extends ConsumerWidget {
  const _MonthTile({
    required this.row,
    required this.title,
    required this.isCurrent,
    required this.onTap,
    this.onCopyNote,
  });

  final _MonthRow row;
  final String title;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback? onCopyNote;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final sym = settings.symbol;
    final hide = settings.hideAmounts;
    String money(int c) => hide ? '****' : '$sym${centsToText(c.abs())}';

    return PressScale(
      scale: 0.995,
      onTap: onTap,
      onLongPress: onCopyNote,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Palette.ink(context),
                  ),
                ),
                if (isCurrent) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Palette.brand(context).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text('本月',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Palette.brand(context))),
                  ),
                ],
                const Spacer(),
                Text(
                  row.count == 0
                      ? (hide ? '****' : '无流水')
                      : '${row.balanceCents < 0 ? '-' : '+'}${money(row.balanceCents)}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: row.count == 0
                        ? Palette.inkFaint(context)
                        : (row.balanceCents < 0
                            ? Palette.expense
                            : Palette.brand(context)),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.chevron_right,
                    size: 18, color: Palette.inkFaint(context)),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              row.count == 0
                  ? '这个月没有计入收支的流水'
                  : '收 ${money(row.incomeCents)} · 支 ${money(row.expenseCents)} · ${row.count} 笔',
              style: TextStyle(
                  fontSize: 11.5, color: Palette.inkFaint(context)),
            ),
            if (row.note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                decoration: BoxDecoration(
                  color: Palette.brand(context).withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(6),
                  border: Border(
                    left: BorderSide(
                      width: 2,
                      color: Palette.brand(context).withValues(alpha: 0.35),
                    ),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        row.note,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: Palette.inkSoft(context)),
                      ),
                    ),
                    if (onCopyNote != null)
                      GestureDetector(
                        onTap: onCopyNote,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6, top: 1),
                          child: Icon(Icons.copy_outlined,
                              size: 14, color: Palette.inkFaint(context)),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
