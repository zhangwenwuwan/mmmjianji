import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/tags.dart';
import '../services/fixed_tags.dart';
import '../state/ledger_state.dart';
import 'theme.dart';

/// 「标签」编辑弹窗。
///
/// 1.4.x 之前这里叫「备注与标签」，里面有一个和主页面完全重复的备注框 ——
/// 两个真源，改哪个都不确定会不会写回去。现在只管标签，备注只有主页面那一个。
///
/// 标签分两类：
/// - 固定标签：用户加的常用项，点一下即加/即删，长按删除固定项
/// - 历史标签：本账本过去用过的，点一下即加/即删
/// 两类都只是候选，最终值仍是那串逗号分隔文本，落库格式零改动。
Future<String?> showTagEditor({
  required BuildContext context,
  required WidgetRef ref,
  required String initial,
}) async {
  final bookId = ref.read(activeBookProvider).valueOrNull?.id ?? 1;
  final store = await ref.read(storeProvider.future);
  final fixed = await FixedTags.load(bookId);
  final history = await store.allTags(bookId);
  if (!context.mounted) return null;

  final ctrl = TextEditingController(text: initial);
  var currentFixed = List<String>.from(fixed);

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final selected = parseTags(ctrl.text);
        final historyOnly = history
            .where((t) => !currentFixed.contains(t))
            .take(40)
            .toList();

        Widget chip(String tag, {required bool isFixed}) {
          final on = selected.contains(tag);
          return Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 6),
            child: GestureDetector(
              onLongPress: isFixed
                  ? () async {
                      final yes = await showDialog<bool>(
                        context: ctx,
                        builder: (c) => AlertDialog(
                          title: Text('移除固定标签「$tag」？'),
                          content: const Text('只是不再显示为固定候选，已记账的标签不受影响。'),
                          actions: [
                            TextButton(
                                onPressed: () => Navigator.pop(c, false),
                                child: const Text('取消')),
                            FilledButton(
                                onPressed: () => Navigator.pop(c, true),
                                child: const Text('移除')),
                          ],
                        ),
                      );
                      if (yes != true) return;
                      await FixedTags.remove(bookId, tag);
                      currentFixed =
                          currentFixed.where((t) => t != tag).toList();
                      setState(() {});
                    }
                  : null,
              child: FilterChip(
                label: Text(tag),
                selected: on,
                onSelected: (_) {
                  ctrl.text = toggleTag(ctrl.text, tag);
                  setState(() {});
                },
                selectedColor: Palette.brand(ctx).withValues(alpha: 0.14),
                checkmarkColor: Palette.brand(ctx),
              ),
            ),
          );
        }

        return AlertDialog(
          title: const Text('标签'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLength: 40,
                  decoration: const InputDecoration(
                    labelText: '标签',
                    hintText: '逗号分隔，如：聚餐,报销',
                    counterText: '',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('固定标签',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkSoft(ctx))),
                    const SizedBox(width: 6),
                    Text('（长按可移除）',
                        style: TextStyle(
                            fontSize: 11, color: Palette.inkFaint(ctx))),
                  ],
                ),
                const SizedBox(height: 4),
                Wrap(
                  children: [
                    for (final t in currentFixed) chip(t, isFixed: true),
                    Padding(
                      padding: const EdgeInsets.only(right: 6, bottom: 6),
                      child: ActionChip(
                        avatar: const Icon(Icons.add, size: 16),
                        label: const Text('添加固定标签'),
                        onPressed: () async {
                          final name = await showDialog<String>(
                            context: ctx,
                            builder: (c) => _NewFixedTagDialog(),
                          );
                          if (name == null || name.trim().isEmpty) return;
                          await FixedTags.add(bookId, name.trim());
                          if (!ctx.mounted) return;
                          currentFixed = await FixedTags.load(bookId);
                          ctrl.text = toggleTag(ctrl.text, name.trim());
                          setState(() {});
                        },
                      ),
                    ),
                  ],
                ),
                if (historyOnly.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('最近用过',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkSoft(ctx))),
                  const SizedBox(height: 4),
                  Wrap(children: [
                    for (final t in historyOnly) chip(t, isFixed: false),
                  ]),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定')),
          ],
        );
      },
    ),
  );

  if (ok == true) {
    final text = ctrl.text;
    ctrl.dispose();
    return text;
  }
  ctrl.dispose();
  return null;
}

class _NewFixedTagDialog extends StatefulWidget {
  const _NewFixedTagDialog();

  @override
  State<_NewFixedTagDialog> createState() => _NewFixedTagDialogState();
}

class _NewFixedTagDialogState extends State<_NewFixedTagDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('新增固定标签'),
        content: TextField(
          controller: _ctrl,
          autofocus: true,
          maxLength: 16,
          decoration: const InputDecoration(
            labelText: '标签名',
            hintText: '如：出差、 AA、宠物',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
              child: const Text('添加')),
        ],
      );
}
