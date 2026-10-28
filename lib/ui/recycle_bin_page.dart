import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/store.dart';
import '../state/ledger_state.dart';
import 'common.dart';
import 'ledger_page.dart';
import 'motion.dart';
import 'theme.dart';

/// 回收站：软删除的流水。
///
/// 删除流水只进这里，不入统计/余额/预算/搜索/导出；可单条或批量恢复，
/// 也可永久删除（才真正清掉流水 + 附件记录与文件）。永久删除不可撤销，
/// 一律二次确认。
class RecycleBinPage extends ConsumerStatefulWidget {
  const RecycleBinPage({super.key});

  @override
  ConsumerState<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends ConsumerState<RecycleBinPage> {
  bool _batch = false;
  final Set<int> _selected = {};

  Future<void> _restoreOne(int id) async {
    final store = await ref.read(storeProvider.future);
    await store.restoreEntry(id);
    bumpRevision(ref);
  }

  Future<void> _purgeOne(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('永久删除这笔？'),
        content: const Text('删除后无法恢复，附件也会一并清除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('永久删除', style: TextStyle(color: Palette.expense)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(storeProvider.future);
    await store.purgeEntry(id);
    bumpRevision(ref);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已永久删除')),
    );
  }

  Future<void> _restoreSelected() async {
    if (_selected.isEmpty) return;
    final store = await ref.read(storeProvider.future);
    final n = await store.restoreEntries(_selected.toList());
    bumpRevision(ref);
    if (!mounted) return;
    setState(() {
      _batch = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已恢复 $n 条')));
  }

  Future<void> _purgeSelected() async {
    if (_selected.isEmpty) return;
    // 已报销的那笔原始支出，它的「报销入账」是一条派生流水（有 reimburse_entry_id）。
    // 永久删除时会一起删掉，不提前说一声，用户只会看到「删了 1 条、少了 2 行」。
    final list = ref.read(recycleBinProvider).valueOrNull ?? const <Entry>[];
    final hasLinked = list.any((e) =>
        _selected.contains(e.id) &&
        e.reimburseEntryId != null &&
        !_selected.contains(e.reimburseEntryId));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('永久删除选中的 ${_selected.length} 条？'),
        content: Text(hasLinked
            ? '删除后无法恢复，附件也会一并清除。\n'
                '其中包含已报销的记录：当初自动记入的那笔收入会一起删除。'
            : '删除后无法恢复，附件也会一并清除。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('永久删除', style: TextStyle(color: Palette.expense)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(storeProvider.future);
    // 用返回的**实际删除条数**（含级联），不要用 _selected.length
    final n = await store.purgeEntries(_selected.toList());
    bumpRevision(ref);
    if (!mounted) return;
    setState(() {
      _batch = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已永久删除 $n 条')),
    );
  }

  Future<void> _purgeAll() async {
    final entries = ref.read(recycleBinProvider).valueOrNull ?? const [];
    if (entries.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空回收站？'),
        content: Text('回收站里 ${entries.length} 条流水会全部永久删除，无法恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('清空', style: TextStyle(color: Palette.expense)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final n = await store.purgeAllRecycleBin(book.id);
    bumpRevision(ref);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已清空 $n 条')));
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(recycleBinProvider);
    final entries = entriesAsync.valueOrNull ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: const Text('回收站'),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              tooltip: _batch ? '退出多选' : '多选',
              icon: Icon(_batch ? Icons.close : Icons.checklist),
              onPressed: () => setState(() {
                _batch = !_batch;
                _selected.clear();
              }),
            ),
          if (_batch && _selected.isNotEmpty)
            IconButton(
              tooltip: '清空回收站',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _purgeAll,
            ),
        ],
      ),
      bottomNavigationBar: _batch && _selected.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _restoreSelected,
                        icon: const Icon(Icons.restore, size: 18),
                        label: Text('恢复选中 (${_selected.length})'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Palette.expense,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: _purgeSelected,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: Text('永久删除 (${_selected.length})'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
      body: entriesAsync.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(),
        error: (e, _) => Center(child: LoadError(error: e)),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.delete_outline,
                      size: 46, color: Palette.inkFaint(context)),
                  const SizedBox(height: 12),
                  Text('回收站是空的',
                      style: TextStyle(color: Palette.inkFaint(context))),
                ],
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 14, color: Palette.inkSoft(context)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '共 ${list.length} 条 · 恢复后回到原账户与分类，附件一并恢复',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkSoft(context)),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 24),
                  itemCount: list.length,
                  itemBuilder: (context, i) {
                    final e = list[i];
                    final isSelected = _selected.contains(e.id);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Panel(
                        padding: EdgeInsets.zero,
                        child: EntryRow(
                          entry: e,
                          selected: _batch ? isSelected : null,
                          onTap: _batch
                              ? () => setState(() {
                                    if (!_selected.add(e.id)) {
                                      _selected.remove(e.id);
                                    }
                                  })
                              : () => showAppSheet<void>(
                                    context: context,
                                    title: '这笔流水',
                                    builder: (ctx) => Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        ListTile(
                                          leading: const Icon(Icons.restore),
                                          title: const Text('恢复这笔'),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            _restoreOne(e.id);
                                          },
                                        ),
                                        ListTile(
                                          leading: Icon(Icons.delete_outline,
                                              color: Palette.expense),
                                          title: Text('永久删除',
                                              style: TextStyle(
                                                  color: Palette.expense)),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            _purgeOne(e.id);
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
