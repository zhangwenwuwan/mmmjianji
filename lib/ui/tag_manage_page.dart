import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/ledger_state.dart';
import 'common.dart';
import 'ledger_page.dart';
import 'motion.dart';
import 'theme.dart';

/// 标签管理：改名（批量改写流水）、删除、点进去看这个标签下的账。
class TagManagePage extends ConsumerWidget {
  const TagManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tagStatsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('标签')),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(height: 64),
        error: (e, _) => Center(child: LoadError(error: e)),
        data: (list) => list.isEmpty
            ? const EmptyView(
                icon: Icons.sell_outlined,
                title: '还没有标签',
                hint: '记账时在「备注与标签」里填，逗号分隔')
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                children: [
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (var i = 0; i < list.length; i++) ...[
                          if (i > 0) const Divider(height: 1, indent: 16),
                          ListTile(
                            leading: Icon(Icons.sell_outlined,
                                size: 18, color: Palette.brand(context)),
                            title: Text('#${list[i].tag}'),
                            subtitle: Text('${list[i].count} 笔',
                                style: const TextStyle(fontSize: 12)),
                            trailing: PopupMenuButton<String>(
                              icon: const Icon(Icons.more_horiz, size: 18),
                              onSelected: (v) async {
                                if (v == 'rename') {
                                  await _rename(context, ref, list[i].tag);
                                } else if (v == 'delete') {
                                  await _delete(context, ref, list[i].tag);
                                }
                              },
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'rename', child: Text('重命名')),
                                PopupMenuItem(
                                    value: 'delete', child: Text('删除标签')),
                              ],
                            ),
                            onTap: () => Navigator.of(context).push(
                              AppPageRoute(
                                  page: TagEntriesPage(tag: list[i].tag)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('改名会批量改写已有流水的标签；删除只是把标签摘掉，流水不动。',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkFaint(context))),
                ],
              ),
      ),
    );
  }

  Future<void> _rename(BuildContext context, WidgetRef ref, String tag) async {
    final ctrl = TextEditingController(text: tag);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('重命名 #$tag'),
        content: AppTextField(
          label: '新名称',
          controller: ctrl,
          hint: '不要加 #',
          autofocus: true,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (next == null || next.isEmpty || next == tag) return;
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final n = await store.renameTag(book.id, tag, next);
    bumpRevision(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已改名，更新了 $n 笔')));
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, String tag) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 #$tag？'),
        content: const Text('只是把标签从流水上摘掉，流水本身不会删。'),
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
    final book = await ref.read(activeBookProvider.future);
    final n = await store.deleteTag(book.id, tag);
    bumpRevision(ref);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已从 $n 笔流水上移除')));
  }
}

class TagEntriesPage extends ConsumerWidget {
  const TagEntriesPage({super.key, required this.tag});

  final String tag;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(tagEntriesProvider(tag));
    return Scaffold(
      appBar: AppBar(title: Text('#$tag')),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(height: 64),
        error: (e, _) => Center(child: LoadError(error: e)),
        data: (entries) => entries.isEmpty
            ? const EmptyView(icon: Icons.sell_outlined, title: '这个标签下没有流水')
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                children: [
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (var i = 0; i < entries.length; i++) ...[
                          if (i > 0) const Divider(height: 1, indent: 56),
                          EntryRow(entry: entries[i]),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
