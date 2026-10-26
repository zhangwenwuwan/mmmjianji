import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'ledger_page.dart';
import 'motion.dart';
import 'theme.dart';

/// 分类详情：这个分类一共花了多少、近半年每月走势、以及具体流水。
class CategoryDetailPage extends ConsumerWidget {
  const CategoryDetailPage({super.key, required this.bucket});

  final Bucket bucket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final monthlyAsync =
        ref.watch(categoryMonthlyProvider((id: bucket.id, flow: bucket.flow)));
    final settings = ref.watch(settingsProvider);
    final entriesAsync =
        ref.watch(_bucketEntriesProvider((id: bucket.id, flow: bucket.flow)));

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppGlyph(bucket.glyph, size: 16),
            const SizedBox(width: 6),
            Flexible(
                child: Text(bucket.title, overflow: TextOverflow.ellipsis)),
          ],
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          monthlyAsync.when(
            skipLoadingOnReload: true,
            loading: () => const Panel(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  children: [
                    Skeleton(height: 30, expand: true, radius: 8),
                    SizedBox(height: 10),
                    Skeleton(height: 26, expand: true, radius: 8),
                  ],
                ),
              ),
            ),
            error: (e, _) => Panel(child: LoadError(error: e, compact: true)),
            data: (points) {
              final total = points.fold<int>(0, (s, p) => s + p.cents);
              // 分母固定 6（标题写的就是「近 6 个月」），不是有数据的月份数。
              // 用 points.length 的话，「半年只花了 1 个月」会显示成
              // 「平均每月 = 那一个月的钱」，高估 6 倍。
              final avg = total ~/ 6;
              final maxV =
                  points.fold<int>(0, (m, p) => p.cents > m ? p.cents : m);
              return Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('近 6 个月合计',
                        style: TextStyle(
                            fontSize: 11, color: Palette.inkFaint(context))),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        MoneyText(total,
                            style: const TextStyle(
                                fontSize: 26, fontWeight: FontWeight.w700)),
                        Padding(
                          padding: const EdgeInsets.only(left: 8, bottom: 4),
                          child: Text(
                            '平均每月 ${settings.symbol}${centsToText(avg)}',
                            style: TextStyle(
                                fontSize: 11, color: Palette.inkFaint(context)),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 92,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final p in points)
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Container(
                                    height: maxV == 0
                                        ? 2
                                        : (p.cents / maxV * 58)
                                            .clamp(2, 58)
                                            .toDouble(),
                                    margin: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    decoration: BoxDecoration(
                                      color: p.cents > 0
                                          ? Palette.brand(context)
                                              .withValues(alpha: 0.8)
                                          : Palette.hairline(context),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    p.month.length >= 7
                                        ? '${int.parse(p.month.substring(5, 7))}月'
                                        : p.month,
                                    style: TextStyle(
                                        fontSize: 9,
                                        color: Palette.inkFaint(context)),
                                  ),
                                ],
                              ),
                            ),
                          if (points.isEmpty)
                            Center(
                              child: Text('这个分类还没有支出',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Palette.inkFaint(context))),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          SectionLabel('流水（最近 300 笔）'),
          entriesAsync.when(
            skipLoadingOnReload: true,
            loading: () => const Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  Skeleton(height: 56, radius: 0),
                  Divider(height: 1, indent: 56),
                  Skeleton(height: 56, radius: 0),
                  Divider(height: 1, indent: 56),
                  Skeleton(height: 56, radius: 0),
                ],
              ),
            ),
            error: (e, _) => Panel(child: LoadError(error: e, compact: true)),
            data: (entries) => entries.isEmpty
                ? const EmptyView(
                    icon: Icons.receipt_long_outlined, title: '还没有记录')
                : Panel(
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
          ),
        ],
      ),
    );
  }
}

/// 某分类的流水（按分类筛，走高级搜索）
/// 分类流水：用 (分类 id, 收支方向) 作 key。
/// 之前写死 flow: 'out'，导致点「工资」这种收入分类永远是空的。
final _bucketEntriesProvider =
    FutureProvider.family<List<Entry>, ({int id, String flow})>(
        (ref, key) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  final tree = await ref.watch(bucketsProvider(key.flow).future);
  return store.searchEntriesEx(
    book.id,
    flow: key.flow,
    bucketIds: bucketFamilyIds(tree, key.id),
  );
});
