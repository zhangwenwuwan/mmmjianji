import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../data/store.dart';
import '../services/app_log.dart';
import '../state/ledger_state.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 分类迁移：把某个分类下的流水整批改到另一个分类。
///
/// 对齐原版的分类迁移页。用在「分类改名字了想合并」「建错了分类」这类场景，
/// 比一条条改省事。迁移后来源分类会变空，可以再删掉。
class CategoryMigrationPage extends ConsumerStatefulWidget {
  const CategoryMigrationPage({super.key});

  @override
  ConsumerState<CategoryMigrationPage> createState() =>
      _CategoryMigrationPageState();
}

class _CategoryMigrationPageState extends ConsumerState<CategoryMigrationPage> {
  String _flow = 'out';
  int? _fromId;
  int? _toId;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final bucketsAsync = ref.watch(bucketsProvider(_flow));
    final buckets = bucketsAsync.valueOrNull ?? const <Bucket>[];
    final from = buckets.where((b) => b.id == _fromId).firstOrNull;
    final to = buckets.where((b) => b.id == _toId).firstOrNull;
    final canRun = from != null && to != null && from.id != to.id && !_busy;

    return Scaffold(
      appBar: AppBar(title: const Text('分类迁移')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          // 支出 / 收入切换
          Row(
            children: [
              for (final e in const [('out', '支出分类'), ('in', '收入分类')])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: PressScale(
                    scale: 0.95,
                    onTap: () => setState(() {
                      _flow = e.$1;
                      _fromId = null;
                      _toId = null;
                    }),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: _flow == e.$1
                            ? Palette.brand(context).withValues(alpha: 0.12)
                            : Palette.card(context),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: _flow == e.$1
                              ? Palette.brand(context)
                              : Palette.hairline(context),
                        ),
                      ),
                      child: Text(e.$2,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: _flow == e.$1
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: _flow == e.$1
                                ? Palette.brand(context)
                                : Palette.inkSoft(context),
                          )),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          SectionLabel('从哪个分类'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final b in buckets)
                  _pickRow(context, b, selected: _fromId == b.id, onTap: () {
                    setState(() {
                      _fromId = b.id;
                      if (_toId == b.id) _toId = null;
                    });
                  }),
                if (buckets.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('这个方向还没有分类',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('迁到哪个分类'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final b in buckets)
                  if (b.id != _fromId)
                    _pickRow(context, b,
                        selected: _toId == b.id,
                        onTap: () => setState(() => _toId = b.id)),
                if (buckets.length <= 1)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text('至少要有两个分类才能迁移',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (from != null && to != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Palette.brand(context).withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '「${from.title}」下的所有流水会改记到「${to.title}」，'
                '之后「${from.title}」就不再有任何流水，可以删掉。',
                style: TextStyle(
                    fontSize: 12, height: 1.6, color: Palette.inkSoft(context)),
              ),
            ),
          const SizedBox(height: 16),
          SizedBox(
            height: 50,
            child: FilledButton(
              onPressed: canRun ? () => _run(from, to) : null,
              child: _busy
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('开始迁移'),
            ),
          ),
        ],
      ),
    );
  }

  /// 一个可选的分类行（替代已废弃的 RadioListTile）
  Widget _pickRow(BuildContext context, Bucket b,
      {required bool selected, required VoidCallback onTap}) {
    return PressScale(
      scale: 0.98,
      onTap: onTap,
      child: ListTile(
        dense: true,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          size: 20,
          color: selected ? Palette.brand(context) : Palette.inkFaint(context),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppGlyph(b.glyph, size: 14),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                b.title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w400),
              ),
            ),
          ],
        ),
        subtitle: b.parentId == null
            ? null
            : Text('二级分类',
                style: TextStyle(
                    fontSize: 10.5, color: Palette.inkFaint(context))),
      ),
    );
  }

  Future<void> _run(Bucket from, Bucket to) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认迁移？'),
        content: Text('「${from.title}」的流水会全部改到「${to.title}」，无法撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认迁移')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final store = await ref.read(storeProvider.future);
      final book = await ref.read(activeBookProvider.future);
      final n = await store.migrateBucket(book.id, from.id, to.id);
      bumpRevision(ref);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _fromId = null;
        _toId = null;
      });
      messenger.showSnackBar(SnackBar(content: Text('已迁移 $n 条流水')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppLog.error('migration', '分类迁移失败', e);
      messenger.showSnackBar(const SnackBar(content: Text('迁移失败，详情见日志中心')));
    }
  }
}
