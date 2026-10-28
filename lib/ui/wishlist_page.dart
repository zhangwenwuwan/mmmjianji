import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'amount_keypad.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 愿望清单：想买的东西先放进来晾几天，冷静期过了再决定。
class WishlistPage extends ConsumerWidget {
  const WishlistPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(wishesProvider);
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('愿望清单')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _edit(context, ref, null),
        child: const Icon(Icons.add),
      ),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(height: 72),
        error: (e, _) => Center(child: LoadError(error: e)),
        data: (list) {
          if (list.isEmpty) {
            return const EmptyView(
              icon: Icons.shopping_bag_outlined,
              title: '还没有想买的东西',
              hint: '放进来晾 7 天，还想要再买',
            );
          }
          final waiting = list.where((w) => w.isWaiting).toList();
          final decided = list.where((w) => !w.isWaiting).toList();
          final coolingTotal = waiting.fold<int>(0, (s, w) => s + w.priceCents);

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 96),
            children: [
              Panel(
                child: Row(
                  children: [
                    Icon(Icons.hourglass_bottom,
                        size: 18, color: Palette.brand(context)),
                    const SizedBox(width: 8),
                    Text('${waiting.length} 件在冷静期',
                        style: TextStyle(
                            fontSize: 13, color: Palette.ink(context))),
                    const Spacer(),
                    Text(
                      settings.hideAmounts
                          ? '****'
                          : '合计 ${settings.symbol}${centsToText(coolingTotal)}',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkFaint(context)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (waiting.isNotEmpty) ...[
                SectionLabel('冷静中'),
                for (final w in waiting) ...[
                  _wishCard(context, ref, w, settings, waiting: true),
                  const SizedBox(height: 10),
                ],
              ],
              if (decided.isNotEmpty) ...[
                const SizedBox(height: 6),
                SectionLabel('已决定'),
                for (final w in decided) ...[
                  _wishCard(context, ref, w, settings, waiting: false),
                  const SizedBox(height: 10),
                ],
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _wishCard(
      BuildContext context, WidgetRef ref, Wish w, AppSettings settings,
      {required bool waiting}) {
    final left = w.coolLeft(DateTime.now());
    final cooling = w.isWaiting && left > 0;
    final done = w.status == 'bought';
    final color = !w.isWaiting
        ? Palette.inkFaint(context)
        : (cooling ? Palette.brand(context) : Palette.income);

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppGlyph(w.glyph, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(w.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            decoration: w.status == 'dropped'
                                ? TextDecoration.lineThrough
                                : null)),
                    Text(
                      waiting
                          ? (cooling ? '冷静期还剩 $left 天' : '冷静期已过，可以决定了')
                          : (done ? '已买' : '已放弃'),
                      style: TextStyle(
                          fontSize: 12,
                          color: cooling ? Palette.brand(context) : color),
                    ),
                  ],
                ),
              ),
              Text(
                settings.hideAmounts
                    ? '****'
                    : '${settings.symbol}${centsToText(w.priceCents)}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: w.status == 'dropped'
                      ? Palette.inkFaint(context)
                      : Palette.ink(context),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (waiting) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _decide(ref, w, 'bought'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Palette.income,
                      side: BorderSide(
                          color: Palette.income.withValues(alpha: 0.5)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('买了', style: TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _decide(ref, w, 'dropped'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Palette.inkSoft(context),
                      side: BorderSide(color: Palette.hairline(context)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('算了', style: TextStyle(fontSize: 13)),
                  ),
                ),
                IconButton(
                  tooltip: '删除',
                  onPressed: () async {
                    final store = await ref.read(storeProvider.future);
                    await store.deleteWish(w.id);
                    bumpRevision(ref);
                  },
                  icon: Icon(Icons.close,
                      size: 16, color: Palette.inkFaint(context)),
                ),
              ],
            ),
          ] else
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () async {
                  final store = await ref.read(storeProvider.future);
                  await store.setWishStatus(w.id, 'waiting');
                  bumpRevision(ref);
                },
                child: const Text('放回冷静期', style: TextStyle(fontSize: 12)),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _decide(WidgetRef ref, Wish w, String status) async {
    final store = await ref.read(storeProvider.future);
    await store.setWishStatus(w.id, status);
    bumpRevision(ref);
  }

  Future<void> _edit(BuildContext context, WidgetRef ref, Wish? wish) async {
    final book = await ref.read(activeBookProvider.future);
    String title = wish?.title ?? '';
    // 常驻 controller：放在 build 里每帧新建会让光标跳到开头、
    // 敲一半点图标/下拉就丢位置（这个坑在记账备注框踩过，这里不能再犯）。
    final titleCtrl = TextEditingController(text: title);
    String glyph = wish?.glyph ?? '🎁';
    int coolDays = wish?.coolDays ?? 7;
    int priceCents = wish?.priceCents ?? 0;
    final noteCtrl = TextEditingController(text: wish?.note ?? '');
    const glyphs = ['🎁', '👟', '📱', '💻', '🎧', '⌚️', '👜', '🎮', '✈️', '🪑'];

    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(wish == null ? '想要点什么' : '编辑'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppTextField(
                  label: '名称',
                  controller: titleCtrl,
                  hint: '例如 降噪耳机',
                  onChanged: (v) => title = v,
                ),
                const SizedBox(height: 14),
                AmountField(
                  label: '价格',
                  cents: priceCents,
                  hint: '大概多少钱',
                  onChanged: (v) => setState(() => priceCents = v),
                ),
                const SizedBox(height: 14),
                GlyphPicker(
                  glyphs: glyphs,
                  value: glyph,
                  onChanged: (g) => setState(() => glyph = g),
                ),
                const SizedBox(height: 14),
                // 冷静期：标签和值同一行，滑块单独占一行，说明放下面
                Row(
                  children: [
                    Text('冷静期',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Palette.inkSoft(context))),
                    const Spacer(),
                    Text('$coolDays 天',
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Palette.brand(context))),
                  ],
                ),
                Slider(
                  value: coolDays.toDouble(),
                  min: 0,
                  max: 30,
                  divisions: 30,
                  label: '$coolDays 天',
                  onChanged: (v) => setState(() => coolDays = v.round()),
                ),
                Text(
                  '先晾几天再决定，冲动消费大多撑不过一周。',
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.5,
                      color: Palette.inkFaint(context)),
                ),
                const SizedBox(height: 14),
                AppTextField(
                  label: '备注',
                  controller: noteCtrl,
                  hint: '为什么想要（可不填）',
                  maxLines: 2,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('加入')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final price = priceCents;
    if (price <= 0 || title.trim().isEmpty) return;
    final store = await ref.read(storeProvider.future);
    if (wish == null) {
      await store.addWish(Wish(
        id: 0,
        bookId: book.id,
        title: title.trim(),
        glyph: glyph,
        priceCents: price,
        note: noteCtrl.text.trim(),
        coolDays: coolDays,
        createdOn: DateTime.now(),
        status: 'waiting',
      ));
    } else {
      await store.updateWish(wish.copyWith(
        title: title.trim(),
        glyph: glyph,
        priceCents: price,
        note: noteCtrl.text.trim(),
        coolDays: coolDays,
      ));
    }
    if (!context.mounted) return;
    bumpRevision(ref);
  }
}
