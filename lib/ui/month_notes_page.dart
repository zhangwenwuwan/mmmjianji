import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/ledger_state.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 月度总结归档。
///
/// 为什么要有这一页：总结只能在统计页的**当前月份**卡片里写，
/// 写过的一翻月就再也找不到了 —— 等于白记。这里把它按月份列出来，
/// 既能回看，也能一次复制走（导出/发给自己都靠它）。
class MonthNotesPage extends ConsumerStatefulWidget {
  const MonthNotesPage({super.key});

  @override
  ConsumerState<MonthNotesPage> createState() => _MonthNotesPageState();
}

class _MonthNotesPageState extends ConsumerState<MonthNotesPage> {
  List<({String month, String note})>? _notes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final list = await store.monthNotes(book.id);
    if (!mounted) return;
    setState(() => _notes = list);
  }

  Future<void> _copyAll() async {
    final list = _notes ?? const [];
    if (list.isEmpty) return;
    final text = list
        .map((e) => '${_titleOf(e.month)}\n${e.note}')
        .join('\n\n');
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${list.length} 条总结')),
    );
  }

  Future<void> _copyOne(String note) async {
    await Clipboard.setData(ClipboardData(text: note));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制')));
  }

  static String _titleOf(String month) {
    final parts = month.split('-');
    if (parts.length < 2) return month;
    return '${parts[0]} 年 ${int.parse(parts[1])} 月';
  }

  @override
  Widget build(BuildContext context) {
    final notes = _notes;
    return Scaffold(
      appBar: AppBar(
        title: const Text('月度总结'),
        actions: [
          if (notes != null && notes.isNotEmpty)
            IconButton(
              tooltip: '复制全部',
              onPressed: _copyAll,
              icon: const Icon(Icons.copy_all_outlined),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          if (notes == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Skeleton(height: 52, radius: 14),
            )
          else if (notes.isEmpty)
            const EmptyView(
              icon: Icons.notes_outlined,
              title: '还没有写过月度总结',
              hint: '统计页最下面的「本月总结」卡片可以写；'
                  '写完换个槽位就会归档到这里，方便回看。',
            )
          else
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < notes.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 16),
                    ListTile(
                      title: Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          _titleOf(notes[i].month),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Palette.inkSoft(context),
                          ),
                        ),
                      ),
                      subtitle: Text(
                        notes[i].note,
                        style: TextStyle(
                            fontSize: 13, color: Palette.ink(context)),
                      ),
                      trailing: Icon(Icons.copy_outlined,
                          size: 16, color: Palette.inkFaint(context)),
                      onTap: () => _copyOne(notes[i].note),
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
