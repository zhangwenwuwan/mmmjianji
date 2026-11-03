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
///
/// [range] 非空时（从统计页带着筛选进来）看的是那一段区间，
/// 不再是「近 6 个月 + 全部流水」—— 否则统计页点「本周 餐饮 ¥320」
/// 进来看到「近 6 个月 ¥5800」，两个页面数字打架。
class CategoryDetailPage extends ConsumerStatefulWidget {
  const CategoryDetailPage({super.key, required this.bucket, this.range});

  final Bucket bucket;
  final ({DateTime from, DateTime to})? range;

  @override
  ConsumerState<CategoryDetailPage> createState() =>
      _CategoryDetailPageState();
}

class _CategoryDetailPageState extends ConsumerState<CategoryDetailPage> {
  /// 首屏只建 60 行（见下面流水那段的说明）
  static const int _pageSize = 60;
  int _shown = _pageSize;

  int _shownCount(int total) => _shown < total ? _shown : total;

  @override
  Widget build(BuildContext context) {
    final bucket = widget.bucket;
    final range = widget.range;
    final monthlyAsync = ref.watch(categoryMonthlyProvider(
        (id: bucket.id, flow: bucket.flow, from: range?.from, to: range?.to)));
    final settings = ref.watch(settingsProvider);
    final entriesAsync = ref.watch(_bucketEntriesProvider(
        (id: bucket.id, flow: bucket.flow, from: range?.from, to: range?.to)));

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
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
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
              // 区间模式下用区间内的月份数，否则「本周」会显示「平均每月 = 全部」。
              final months = range == null
                  ? 6
                  : (points.isEmpty ? 1 : points.length);
              final avg = total ~/ months;
              final maxV =
                  points.fold<int>(0, (m, p) => p.cents > m ? p.cents : m);
              return Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(range == null ? '近 6 个月合计' : '这个区间合计',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                    const SizedBox(height: 4),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        MoneyText(total,
                            style: const TextStyle(
                                fontSize: 28, fontWeight: FontWeight.w700)),
                        Padding(
                          padding: const EdgeInsets.only(left: 8, bottom: 4),
                          child: Text(
                            '平均每月 ${settings.symbol}${centsToText(avg)}',
                            style: TextStyle(
                                fontSize: 12, color: Palette.inkFaint(context)),
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
                                        fontSize: 10.5,
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
          SectionLabel(
              range == null ? '流水（最近 300 笔）' : '这个区间的流水'),
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
            data: (entries) {
              if (entries.isEmpty) {
                return const EmptyView(
                    icon: Icons.receipt_long_outlined, title: '还没有记录');
              }
              // 一次最多建 60 行：这个列表上限 300 条，每行都要 watch 6 个
              // provider，全量建完进页面会有明显顿挫。
              return Column(
                children: [
                  Panel(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (var i = 0; i < _shownCount(entries.length); i++) ...[
                          if (i > 0) const Divider(height: 1, indent: 56),
                          EntryRow(entry: entries[i]),
                        ],
                      ],
                    ),
                  ),
                  if (_shown < entries.length)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Center(
                        child: TextButton(
                          onPressed: () => setState(() => _shown += _pageSize),
                          child: Text(
                            '还有 ${entries.length - _shown} 笔 · 再显示 $_pageSize 笔',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

/// 某分类的流水（按分类筛，走高级搜索）
/// 分类流水：用 (分类 id, 收支方向) 作 key。
/// 之前写死 flow: 'out'，导致点「工资」这种收入分类永远是空的。
final _bucketEntriesProvider = FutureProvider.family<List<Entry>,
    ({int id, String flow, DateTime? from, DateTime? to})>((ref, key) async {
  final store = await ref.watch(storeProvider.future);
  final book = await ref.watch(activeBookProvider.future);
  ref.watch(revisionProvider);
  final tree = await ref.watch(bucketsProvider(key.flow).future);
  return store.searchEntriesEx(
    book.id,
    flow: key.flow,
    bucketIds: bucketFamilyIds(tree, key.id),
    from: key.from,
    to: key.to,
    // 详情页要能一路「再显示」到最早一笔：突破默认 300 条上限。
    // UI 仍按 60 条/页渲染（_shownCount），不会一次全建。
    limit: 1000000,
  );
});
