import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import 'category_detail_page.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 新增分类时的默认图标。
///
/// 2026-10-26 用户要求「适当保留四个五个就行」—— 原来 18 个铺了三行，
/// 找图标比想名字还慢。留下覆盖最常用的五类：食 / 购物 / 住 / 收入 / 其它。
/// 想用别的图标走图标栏第一个格子的「相册」，自定义图片不受这个清单限制。
const kBucketGlyphs = ['🍜', '🛍️', '🏠', '💰', '✨'];

/// 分类管理：支出 / 收入两组，各自增改归档。
class BucketManagePage extends ConsumerStatefulWidget {
  const BucketManagePage({super.key});

  @override
  ConsumerState<BucketManagePage> createState() => _BucketManagePageState();
}

class _BucketManagePageState extends ConsumerState<BucketManagePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('分类管理'),
        bottom: TabBar(
          controller: _tab,
          tabs: const [Tab(text: '支出分类'), Tab(text: '收入分类')],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(_tab.index == 0 ? 'out' : 'in', null),
        child: const Icon(Icons.add),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _BucketList(flow: 'out', onEdit: (b) => _edit('out', b)),
          _BucketList(flow: 'in', onEdit: (b) => _edit('in', b)),
        ],
      ),
    );
  }

  Future<void> _edit(String flow, Bucket? bucket) async {
    final book = await ref.read(activeBookProvider.future);
    if (!mounted) return;
    String title = bucket?.title ?? '';
    // 常驻 controller：放在 build 里每帧新建会让光标跳到开头、
    // 敲一半点图标/下拉就丢位置（这个坑在记账备注框踩过，这里不能再犯）。
    final titleCtrl = TextEditingController(text: title);
    String glyph = bucket?.glyph ?? kBucketGlyphs.first;
    int? parentId = bucket?.parentId;
    // 只有一级分类能当父分类；自己不能当自己的父分类
    final allBuckets =
        ref.read(bucketsProvider(flow)).valueOrNull ?? const <Bucket>[];
    final parentOptions =
        allBuckets.where((b) => b.isTop && b.id != bucket?.id).toList();
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(bucket == null ? '新增分类' : '编辑分类'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppTextField(
                label: '名称',
                controller: titleCtrl,
                hint: '例如 餐饮、交通、工资',
                onChanged: (v) => title = v,
              ),
              const SizedBox(height: 14),
              // 二级分类：选一个上级分类（不选 = 一级分类）
              AppDropdown<int?>(
                label: '上级分类',
                // 父分类可能已归档 → value 不在 items 里会断言崩，回落 null
                value: (parentId == null ||
                        parentOptions.any((p) => p.id == parentId))
                    ? parentId
                    : null,
                hint: '无（作为一级分类）',
                items: [
                  const DropdownMenuItem<int?>(
                      value: null, child: Text('无（作为一级分类）')),
                  for (final p in parentOptions)
                    DropdownMenuItem<int?>(
                        value: p.id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppGlyph(p.glyph, size: 16),
                            const SizedBox(width: 4),
                            Flexible(
                                child: Text(p.title,
                                    overflow: TextOverflow.ellipsis)),
                          ],
                        )),
                ],
                onChanged: (v) => setState(() => parentId = v),
              ),
              const SizedBox(height: 14),
              GlyphPicker(
                glyphs: kBucketGlyphs,
                value: glyph,
                onChanged: (g) => setState(() => glyph = g),
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
    if (saved != true) return;
    final name = title.trim();
    if (name.isEmpty) return;
    final store = await ref.read(storeProvider.future);
    if (bucket == null) {
      await store.addBucket(
          bookId: book.id,
          title: name,
          glyph: glyph,
          flow: flow,
          parentId: parentId);
    } else {
      await store.updateBucket(Bucket(
        id: bucket.id,
        bookId: bucket.bookId,
        title: name,
        glyph: glyph,
        flow: bucket.flow,
        archived: bucket.archived,
        parentId: parentId,
      ));
    }
    bumpRevision(ref);
  }
}

class _BucketList extends ConsumerWidget {
  const _BucketList({required this.flow, required this.onEdit});

  final String flow;
  final ValueChanged<Bucket> onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(bucketsProvider(flow));
    final archived = ref.watch(archivedBucketsProvider(flow)).valueOrNull ??
        const <Bucket>[];
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SkeletonList(),
      error: (e, _) => ErrorRetryView(
        message: '读取失败',
        detail: '$e',
        onRetry: () async => ref.invalidate(bucketsProvider(flow)),
      ),
      data: (buckets) {
        // 按层级展开：一级分类下面紧跟它自己的二级分类（缩进 + 小字）
        final tops = buckets.where((b) => b.isTop).toList();
        final childrenOf = <int, List<Bucket>>{};
        for (final b in buckets.where((b) => !b.isTop)) {
          childrenOf.putIfAbsent(b.parentId!, () => []).add(b);
        }
        final ordered = <({Bucket bucket, bool isChild})>[
          for (final t in tops) ...[
            (bucket: t, isChild: false),
            for (final c in childrenOf[t.id] ?? const <Bucket>[])
              (bucket: c, isChild: true),
          ],
        ];

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < ordered.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 56),
                    _tile(context, ref, ordered[i].bucket,
                        isChild: ordered[i].isChild),
                  ],
                  if (ordered.isEmpty)
                    const Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('还没有分类，点右下角 + 新增一个')),
                ],
              ),
            ),
            if (tops.isEmpty)
              const SizedBox.shrink()
            else
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '想把分类归到某个大类下？编辑时选「上级分类」即可变成二级分类。',
                  style:
                      TextStyle(fontSize: 12, color: Palette.inkFaint(context)),
                ),
              ),
            // 归档曾是单向的：一旦归档就从列表消失，且没有任何反向入口。
            // 这里列出已归档分类并给「恢复」，不让用户把自己锁死。
            if (archived.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text('已归档 ${archived.length} 个',
                  style: TextStyle(
                      fontSize: 12, color: Palette.inkFaint(context))),
              const SizedBox(height: 8),
              Panel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < archived.length; i++) ...[
                      if (i > 0) const Divider(height: 1, indent: 56),
                      ListTile(
                        leading: AppGlyph(archived[i].glyph, size: 16),
                        title: Text(archived[i].title,
                            style: TextStyle(
                                fontSize: 14,
                                color: Palette.inkSoft(context))),
                        subtitle: const Text('已归档',
                            style: TextStyle(fontSize: 12)),
                        trailing: TextButton(
                          onPressed: () async {
                            final store =
                                await ref.read(storeProvider.future);
                            await store.archiveBucket(archived[i].id, false);
                            bumpRevision(ref);
                          },
                          child: const Text('恢复'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _tile(BuildContext context, WidgetRef ref, Bucket b,
      {required bool isChild}) {
    return ListTile(
      contentPadding: EdgeInsets.only(left: isChild ? 34 : 16, right: 8),
      leading: AppGlyph(b.glyph, size: isChild ? 15 : 18),
      title: Row(
        children: [
          if (isChild) ...[
            Icon(Icons.subdirectory_arrow_right,
                size: 14, color: Palette.inkFaint(context)),
            const SizedBox(width: 3),
          ],
          Flexible(
            child: Text(b.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: isChild ? 13 : 14,
                    color: isChild
                        ? Palette.inkSoft(context)
                        : Palette.ink(context))),
          ),
        ],
      ),
      onTap: () => Navigator.of(context)
          .push(AppPageRoute(page: CategoryDetailPage(bucket: b))),
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_horiz, size: 18),
        onSelected: (v) async {
          if (v == 'edit') {
            onEdit(b);
            return;
          }
          if (v == 'archive') {
            final store = await ref.read(storeProvider.future);
            await store.archiveBucket(b.id, true);
            bumpRevision(ref);
          }
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('编辑')),
          PopupMenuItem(value: 'archive', child: Text('归档')),
        ],
      ),
    );
  }
}
