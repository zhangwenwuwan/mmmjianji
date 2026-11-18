import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/bucket_order.dart';
import '../data/store.dart';
import '../services/app_log.dart';
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

class _BucketList extends ConsumerStatefulWidget {
  const _BucketList({required this.flow, required this.onEdit});

  final String flow;
  final ValueChanged<Bucket> onEdit;

  @override
  ConsumerState<_BucketList> createState() => _BucketListState();
}

class _BucketListState extends ConsumerState<_BucketList> {
  /// 用户刚拖出来的顺序（只存 id）。null = 没拖过，按数据库 rank 来。
  ///
  /// 为什么要在本地留一份：拖完要落库、再 `bumpRevision` 让 provider 重查，
  /// 中间有几十毫秒。若这期间还按旧 rank 渲染，松手的动画会先弹回原位再跳过去。
  /// 本地顺序顶上这两帧，provider 回来时两边已经一致。
  List<int>? _topOrder;

  /// 每个一级分类下的二级分类顺序（key = 一级分类 id）。
  final Map<int, List<int>> _childOrder = {};

  ({List<Bucket> tops, Map<int, List<Bucket>> childrenOf}) _tree(
      List<Bucket> all) {
    final childrenOf = <int, List<Bucket>>{};
    for (final b in all.where((b) => !b.isTop)) {
      childrenOf.putIfAbsent(b.parentId!, () => []).add(b);
    }
    return (tops: all.where((b) => b.isTop).toList(), childrenOf: childrenOf);
  }

  /// 按本地记录的顺序排；本地没记录的（刚新增的）排到末尾。
  List<Bucket> _applyOrder(List<Bucket> items, List<int>? order) {
    if (order == null || order.isEmpty) return items;
    final pos = <int, int>{for (var i = 0; i < order.length; i++) order[i]: i};
    final out = [...items];
    out.sort((a, b) {
      final ia = pos[a.id], ib = pos[b.id];
      if (ia == null && ib == null) return a.id.compareTo(b.id);
      if (ia == null) return 1;
      if (ib == null) return -1;
      return ia.compareTo(ib);
    });
    return out;
  }

  /// 一级分类拖动：组整体移动，其下的二级分类跟着走。
  ///
  /// 用的是 `onReorderItem`（不是已废弃的 `onReorder`）：它传进来的 newIndex
  /// 已经按「先移除 oldIndex 再插入」调整过，这里不能再自己 `-1`，
  /// 否则往下拖一格会少走一格（[moveId] 里也写了同一句话）。
  void _onReorderTop(int oldIndex, int newIndex) {
    final raw = ref.read(bucketsProvider(widget.flow)).valueOrNull;
    if (raw == null) return;
    final tree = _tree(raw);
    final tops = _applyOrder(tree.tops, _topOrder);
    if (oldIndex < 0 || oldIndex >= tops.length) return;
    final byId = {for (final t in tops) t.id: t};
    final ids = moveId(tops.map((e) => e.id).toList(), oldIndex, newIndex);
    setState(() => _topOrder = ids);
    _persistOrder([for (final id in ids) byId[id]!], tree.childrenOf);
  }

  /// 二级分类拖动：只在本组内换位置，不会跑到别的父分类下面。
  void _onReorderChild(int parentId, int oldIndex, int newIndex) {
    final raw = ref.read(bucketsProvider(widget.flow)).valueOrNull;
    if (raw == null) return;
    final tree = _tree(raw);
    final kids = _applyOrder(
        tree.childrenOf[parentId] ?? const <Bucket>[], _childOrder[parentId]);
    if (oldIndex < 0 || oldIndex >= kids.length) return;
    final ids = moveId(kids.map((e) => e.id).toList(), oldIndex, newIndex);
    setState(() => _childOrder[parentId] = ids);
    _persistOrder(_applyOrder(tree.tops, _topOrder), tree.childrenOf);
  }

  /// 把整棵树的顺序压平成一串 id 交给 store：一级后面紧跟它的二级，
  /// 一个连续 rank 空间就能同时表达两层顺序（同层之间按 rank 比较）。
  Future<void> _persistOrder(
      List<Bucket> tops, Map<int, List<Bucket>> childrenOf) async {
    final ids = <int>[];
    for (final t in tops) {
      ids.add(t.id);
      for (final c
          in _applyOrder(childrenOf[t.id] ?? const <Bucket>[], _childOrder[t.id])) {
        ids.add(c.id);
      }
    }
    if (ids.isEmpty) return;
    try {
      final store = await ref.read(storeProvider.future);
      await store.reorderBuckets(ids);
      bumpRevision(ref);
    } catch (e) {
      AppLog.warn('bucket', '保存分类顺序失败: $e');
      // 落库失败就把本地顺序扔掉，回落到数据库里真实的那一份，
      // 不然列表会一直显示一个只有这一屏才存在的假顺序。
      if (mounted) {
        setState(() {
          _topOrder = null;
          _childOrder.clear();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(bucketsProvider(widget.flow));
    final archived = ref.watch(archivedBucketsProvider(widget.flow)).valueOrNull ??
        const <Bucket>[];
    return async.when(
      skipLoadingOnReload: true,
      loading: () => const SkeletonList(),
      error: (e, _) => ErrorRetryView(
        message: '读取失败',
        detail: '$e',
        onRetry: () async => ref.invalidate(bucketsProvider(widget.flow)),
      ),
      data: (raw) {
        final tree = _tree(raw);
        final tops = _applyOrder(tree.tops, _topOrder);
        final groups = [
          for (final t in tops)
            (
              top: t,
              kids: _applyOrder(tree.childrenOf[t.id] ?? const <Bucket>[],
                  _childOrder[t.id]),
            ),
        ];

        // 一级分类 = 一个可拖拽的「组」，二级分类在组内单独可拖拽。
        // 嵌套的 ReorderableListView 都关了自身的滚动（外层才是唯一滚动区），
        // 拖拽走显式手柄（buildDefaultDragHandles: false），
        // 这样点分类进详情、点菜单改分类都不会误触拖动。
        return ReorderableListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          buildDefaultDragHandles: false,
          itemCount: groups.length + 1,
          onReorderItem: _onReorderTop,
          itemBuilder: (context, i) {
            if (i == groups.length) {
              return _footer(context, archived, isEmpty: groups.isEmpty);
            }
            final g = groups[i];
            return Padding(
              key: ValueKey('bucket-group-${g.top.id}'),
              padding: const EdgeInsets.only(bottom: 6),
              child: Panel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _tile(context, g.top, isChild: false, index: i),
                    if (g.kids.isNotEmpty)
                      ReorderableListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        buildDefaultDragHandles: false,
                        itemCount: g.kids.length,
                        onReorderItem: (o, n) =>
                            _onReorderChild(g.top.id, o, n),
                        itemBuilder: (context, j) => Column(
                          key: ValueKey('bucket-child-${g.kids[j].id}'),
                          children: [
                            const Divider(height: 1, indent: 56),
                            _tile(context, g.kids[j],
                                isChild: true, index: j),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _footer(BuildContext context, List<Bucket> archived,
      {required bool isEmpty}) {
    return Column(
      key: const ValueKey('bucket-footer'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text('还没有分类，点右下角 + 新增一个',
                  style: TextStyle(
                      fontSize: 13, color: Palette.inkFaint(context))),
            ),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 2, right: 2),
          child: Text(
            '拖右侧的手柄可以调整顺序（一级、二级都能拖）。想把分类归到某个大类下？'
            '编辑时选「上级分类」即可变成二级分类。',
            style: TextStyle(fontSize: 12, color: Palette.inkFaint(context)),
          ),
        ),
        // 归档曾是单向的：一旦归档就从列表消失，且没有任何反向入口。
        // 这里列出已归档分类并给「恢复」，不让用户把自己锁死。
        if (archived.isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('已归档 ${archived.length} 个',
              style:
                  TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
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
                            fontSize: 14, color: Palette.inkSoft(context))),
                    subtitle:
                        const Text('已归档', style: TextStyle(fontSize: 12)),
                    // 归档区也能删：归档只是「暂时不用」，误建的分类
                    // 不该逼用户先恢复再去主列表里找删除。
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () async {
                            final store =
                                await ref.read(storeProvider.future);
                            await store.archiveBucket(archived[i].id, false);
                            bumpRevision(ref);
                          },
                          child: const Text('恢复'),
                        ),
                        IconButton(
                          tooltip: '删除',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => _delete(context, archived[i]),
                          icon: Icon(Icons.delete_outline,
                              size: 18, color: Palette.expense),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _tile(BuildContext context, Bucket b,
      {required bool isChild, required int index}) {
    return ListTile(
      contentPadding: EdgeInsets.only(left: isChild ? 34 : 16, right: 4),
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
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz, size: 18),
            onSelected: (v) async {
              if (v == 'edit') {
                widget.onEdit(b);
                return;
              }
              if (v == 'archive') {
                final store = await ref.read(storeProvider.future);
                await store.archiveBucket(b.id, true);
                bumpRevision(ref);
                return;
              }
              if (v == 'delete') {
                await _delete(context, b);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('编辑')),
              PopupMenuItem(value: 'archive', child: Text('归档')),
              // 和账户管理同一套口径：有流水 / 子分类 / 周期记账就不让删，
              // 只让归档 —— 删掉会把历史流水变成「未分类」，统计口径全变。
              PopupMenuItem(
                  value: 'delete',
                  child: Text('删除', style: TextStyle(color: Palette.expense))),
            ],
          ),
          // 手柄是**唯一**的拖动入口：整行长按拖动会和「点进详情」抢手势，
          // 而且二级分类在内层列表里，长按会分不清拖的是哪一层。
          ReorderableDragStartListener(
            index: index,
            child: SizedBox(
              width: 34,
              height: 48,
              child: Icon(Icons.drag_handle,
                  size: 18, color: Palette.inkFaint(context)),
            ),
          ),
        ],
      ),
    );
  }

  /// 删除分类。和 [PocketManagePage] 的删除同一套流程：
  /// 先算影响面 → 有引用就拦下并说明 → 没有才二次确认。
  Future<void> _delete(BuildContext context, Bucket b) async {
    final store = await ref.read(storeProvider.future);
    final impact = await store.bucketDeleteImpact(b.id);
    if (!context.mounted) return;
    final blockers = <String>[
      if (impact.entries > 0) '${impact.entries} 笔流水',
      if (impact.children > 0) '${impact.children} 个子分类',
      if (impact.recurring > 0) '${impact.recurring} 条周期记账',
    ];
    if (blockers.isNotEmpty) {
      ScaffoldMessenger.of(context)
          .toast('「${b.title}」还被 ${blockers.join('、')}使用，不能删除，可以改成归档。');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${b.title}」？'),
        // 没有流水才会走到这里；说清楚删的是什么，别只给一句「不可恢复」。
        content: const Text('这个分类没有流水、子分类或周期记账，删除后不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('删除', style: TextStyle(color: Palette.expense))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await store.deleteBucketIfEmpty(b.id);
    } on StateError catch (e) {
      // 并发兜底：确认框打开期间另一边刚记了一笔，落库时再拦一次。
      if (context.mounted) {
        ScaffoldMessenger.of(context).toast(e.message);
      }
      return;
    }
    bumpRevision(ref);
  }
}
