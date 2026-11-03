import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/currency.dart';
import '../core/rules.dart';
import '../core/version.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 年度报告：汇总 + 12 个月柱状 + Top 分类 + 分享海报。
class ReportPage extends ConsumerStatefulWidget {
  const ReportPage({super.key});

  @override
  ConsumerState<ReportPage> createState() => _ReportPageState();
}

class _YearReport {
  const _YearReport({
    required this.year,
    required this.incomeCents,
    required this.expenseCents,
    required this.monthlyExpense,
    required this.monthlyIncome,
    required this.topBuckets,
    required this.activeDays,
    required this.count,
    required this.missingRate,
    required this.busiestMonth,
    required this.busiestMonthCents,
    required this.avgPerRecord,
    required this.categoryCount,
    required this.achievements,
  });

  final int year;
  final int incomeCents;
  final int expenseCents;
  final List<int> monthlyExpense;
  final List<int> monthlyIncome;
  final List<({String label, int cents})> topBuckets;
  final int activeDays;
  final int count;
  final bool missingRate;

  /// 花得最多的月份（1-12）与金额
  final int busiestMonth;
  final int busiestMonthCents;

  /// 单笔平均
  final int avgPerRecord;

  /// 用到的分类数
  final int categoryCount;

  /// 成就徽章（纯文案，逗号分隔展示）
  final List<String> achievements;
}

class _ReportPageState extends ConsumerState<ReportPage> {
  late int _year = DateTime.now().year;
  Future<_YearReport>? _future;
  final _posterKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _future = _load(_year);
  }

  Future<_YearReport> _load(int year) async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final rates = await store.rates(book.id);
    final pockets = await store.allPockets();
    final currencyOf = {for (final p in pockets) p.id: p.currency};
    final entries = await store.entriesOfYear(book.id, year);

    final monthlyExpense = List<int>.filled(12, 0);
    final monthlyIncome = List<int>.filled(12, 0);
    var missingRate = false;

    // 分类合计：先按 bucketId 累加（折算主币种），最后换成分类名
    final byBucket = <int?, int>{};
    for (final e in entries) {
      if (e.flow != 'in' && e.flow != 'out') continue;
      // 全 app 只有年度报告漏了这条：勾了「不计入收支」的笔会被算进来，
      // 于是首页支出 5000、年报支出 10000，用户会认定统计是坏的。
      if (e.excludeFromStats) continue;
      final from = e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency;
      if (!hasRate(from, book.baseCurrency, rates)) missingRate = true;
      final base = toBaseCents(e.statsCents, from, book.baseCurrency, rates);
      final m = e.day.month - 1;
      if (e.flow == 'in') {
        monthlyIncome[m] += base;
      } else {
        monthlyExpense[m] += base;
        byBucket[e.bucketId] = (byBucket[e.bucketId] ?? 0) + base;
      }
    }

    final bucketNames = <int, String>{
      for (final b
          in await store.buckets(book.id, 'out', includeArchived: true))
        b.id: b.title,
    };
    final named = <String, int>{};
    for (final e in byBucket.entries) {
      final name = e.key == null ? '未分类' : (bucketNames[e.key!] ?? '未分类');
      named[name] = (named[name] ?? 0) + e.value;
    }
    final top = named.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final days = <String>{};
    for (final e in entries) {
      days.add(dayKey(e.day));
    }

    // 最忙月份
    var busiestMonth = 1;
    var busiestCents = 0;
    for (var i = 0; i < 12; i++) {
      if (monthlyExpense[i] > busiestCents) {
        busiestCents = monthlyExpense[i];
        busiestMonth = i + 1;
      }
    }
    // 分母也要排除「不计入收支」，否则单笔平均被这些笔拉低
    final counted = entries
        .where((e) => e.flow != 'transfer' && !e.excludeFromStats)
        .length;
    final avgPerRecord = counted == 0
        ? 0
        : ((monthlyIncome.fold<int>(0, (a, b) => a + b) +
                monthlyExpense.fold<int>(0, (a, b) => a + b)) ~/
            counted);
    final categoryCount = named.length;

    // 成就：只在真的达成时给，不凑数
    final savingsRate = monthlyIncome.fold<int>(0, (a, b) => a + b) == 0
        ? 0.0
        : 1 -
            monthlyExpense.fold<int>(0, (a, b) => a + b) /
                monthlyIncome.fold<int>(0, (a, b) => a + b);
    final achievements = <String>[
      if (days.length >= 200) '记账 ${days.length} 天，几乎全年无休',
      if (savingsRate >= 0.3) '储蓄率 ${(savingsRate * 100).round()}%，钱留住了',
      if (categoryCount >= 8) '分类用得细，$categoryCount 个分类都有记录',
      if (busiestCents == 0) '这一年没有支出记录',
    ];

    return _YearReport(
      year: year,
      incomeCents: monthlyIncome.fold(0, (a, b) => a + b),
      expenseCents: monthlyExpense.fold(0, (a, b) => a + b),
      monthlyExpense: monthlyExpense,
      monthlyIncome: monthlyIncome,
      topBuckets: [
        for (final t in top.take(5)) (label: t.key, cents: t.value),
      ],
      activeDays: days.length,
      count: counted,
      missingRate: missingRate,
      busiestMonth: busiestMonth,
      busiestMonthCents: busiestCents,
      avgPerRecord: avgPerRecord,
      categoryCount: categoryCount,
      achievements: achievements,
    );
  }

  void _shiftYear(int delta) {
    setState(() {
      _year += delta;
      _future = _load(_year);
    });
  }

  Future<void> _share() async {
    try {
      final boundary = _posterKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      await Share.shareXFiles([
        XFile.fromData(Uint8List.view(bytes.buffer),
            mimeType: 'image/png', name: '简记-$_year.png'),
      ], text: '简记 $_year 年度账本');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .toast('分享失败，可先截图保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text('$_year 年度报告'),
        actions: [
          IconButton(
              onPressed: () => _shiftYear(-1),
              icon: const Icon(Icons.chevron_left)),
          IconButton(
              onPressed: () => _shiftYear(1),
              icon: const Icon(Icons.chevron_right)),
          IconButton(onPressed: _share, icon: const Icon(Icons.ios_share)),
        ],
      ),
      body: FutureBuilder<_YearReport>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            if (snap.hasError) {
              return Center(child: Text('统计失败：${snap.error}'));
            }
            return const SkeletonList(count: 4, height: 88);
          }
          final r = snap.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
            children: [
              RepaintBoundary(
                key: _posterKey,
                child: _Poster(
                    report: r,
                    symbol: settings.symbol,
                    hide: settings.hideAmounts),
              ),
              const SizedBox(height: 16),
              if (r.missingRate)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    '注意：有外币账户没填汇率，这部分按 1:1 计入，金额可能不准。可在「账本与汇率」里补。',
                    style: TextStyle(fontSize: 12, color: Palette.expense),
                  ),
                ),
              _RecentMonths(
                  symbol: settings.symbol, hide: settings.hideAmounts),
              const SizedBox(height: 14),
              _MonthlyBars(report: r),
              const SizedBox(height: 14),
              _TopList(
                  report: r,
                  symbol: settings.symbol,
                  hide: settings.hideAmounts),
              const SizedBox(height: 14),
              _YearFacts(
                  report: r,
                  symbol: settings.symbol,
                  hide: settings.hideAmounts),
              const SizedBox(height: 20),
              Center(
                child: Text('数据只来自这台手机 · 简记 $appVersion',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkFaint(context))),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 供分享的海报卡（也是页面顶部的主体）
class _Poster extends StatelessWidget {
  const _Poster(
      {required this.report, required this.symbol, required this.hide});

  final _YearReport report;
  final String symbol;
  final bool hide;

  String _m(int cents) => hide ? '****' : '$symbol${centsToText(cents)}';

  @override
  Widget build(BuildContext context) {
    final net = report.incomeCents - report.expenseCents;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        // 跟随「配色方案」，不再写死松石绿（换了配色报告头还是绿的）
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Palette.brand(context),
            Color.lerp(Palette.brand(context), Colors.black, 0.28)!,
          ],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(Icons.check_rounded,
                    color: Colors.white, size: 18),
              ),
              const SizedBox(width: 8),
              const Text('简记',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2)),
              const Spacer(),
              Text('${report.year} 年度',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.8),
                      fontSize: 12)),
            ],
          ),
          const SizedBox(height: 18),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_m(net.abs()),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      fontFeatures: [FontFeature.tabularFigures()])),
              Padding(
                padding: const EdgeInsets.only(bottom: 5, left: 6),
                child: Text(net >= 0 ? '净结余' : '净超支',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _mini('收入', _m(report.incomeCents)),
              const SizedBox(width: 18),
              _mini('支出', _m(report.expenseCents)),
              const SizedBox(width: 18),
              _mini('记账', '${report.activeDays} 天'),
            ],
          ),
          const SizedBox(height: 16),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.18)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              for (final t in report.topBuckets.take(3))
                Text('${t.label} ${_m(t.cents)}',
                    style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.9),
                        fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _mini(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.65), fontSize: 10.5)),
        const SizedBox(height: 2),
        Text(value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
                fontFeatures: [FontFeature.tabularFigures()])),
      ],
    );
  }
}

class _MonthlyBars extends StatelessWidget {
  const _MonthlyBars({required this.report});

  final _YearReport report;

  @override
  Widget build(BuildContext context) {
    final maxV = [
      ...report.monthlyExpense,
      ...report.monthlyIncome,
    ].fold<int>(0, (a, b) => a > b ? a : b);
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('各月支出',
              style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
          const SizedBox(height: 10),
          SizedBox(
            height: 110,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (var m = 0; m < 12; m++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Container(
                            height: maxV == 0
                                ? 2
                                : (report.monthlyExpense[m] / maxV * 88)
                                    .clamp(2, 88)
                                    .toDouble(),
                            decoration: BoxDecoration(
                              color: Palette.expense.withValues(alpha: 0.8),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text('${m + 1}',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: Palette.inkFaint(context))),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopList extends StatelessWidget {
  const _TopList(
      {required this.report, required this.symbol, required this.hide});

  final _YearReport report;
  final String symbol;
  final bool hide;

  @override
  Widget build(BuildContext context) {
    if (report.topBuckets.isEmpty) {
      return const EmptyView(icon: Icons.bar_chart, title: '这一年还没有支出记录');
    }
    final total = report.expenseCents;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('花得最多的分类',
              style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
          const SizedBox(height: 10),
          for (final t in report.topBuckets)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                      child:
                          Text(t.label, style: const TextStyle(fontSize: 13))),
                  Text(
                    hide
                        ? '****'
                        : '$symbol${centsToText(t.cents)} · ${(t.cents / (total == 0 ? 1 : total) * 100).round()}%',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 近 6 个月收支对比 + 环比。
class _RecentMonths extends ConsumerWidget {
  const _RecentMonths({required this.symbol, required this.hide});

  final String symbol;
  final bool hide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(monthProvider);
    final seriesAsync =
        ref.watch(monthSeriesProvider((count: 6, anchor: month)));
    return Panel(
      child: seriesAsync.when(
        skipLoadingOnReload: true,
        loading: () => const Padding(
          padding: EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(child: Skeleton(height: 100, radius: 6)),
              SizedBox(width: 4),
              Expanded(child: Skeleton(height: 100, radius: 6)),
              SizedBox(width: 4),
              Expanded(child: Skeleton(height: 100, radius: 6)),
              SizedBox(width: 4),
              Expanded(child: Skeleton(height: 100, radius: 6)),
              SizedBox(width: 4),
              Expanded(child: Skeleton(height: 100, radius: 6)),
              SizedBox(width: 4),
              Expanded(child: Skeleton(height: 100, radius: 6)),
            ],
          ),
        ),
        error: (e, _) => LoadError(error: e, compact: true),
        data: (points) {
          final maxV = points.fold<int>(0, (m, p) {
            final v =
                p.incomeCents > p.expenseCents ? p.incomeCents : p.expenseCents;
            return v > m ? v : m;
          });
          // 环比：最后一个月 vs 上一个月（只看支出）
          final cur = points.last;
          final prev = points.length >= 2 ? points[points.length - 2] : null;
          String? mom;
          var momUp = false;
          if (prev != null && prev.expenseCents > 0) {
            final diff = cur.expenseCents - prev.expenseCents;
            final pct = (diff / prev.expenseCents * 100).round();
            momUp = diff > 0;
            mom = pct == 0
                ? '与上月持平'
                : (pct > 0 ? '比上月多花 $pct%' : '比上月少花 ${-pct}%');
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('近 6 个月',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkSoft(context))),
                  const Spacer(),
                  if (mom != null)
                    Text(mom,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: momUp ? Palette.expense : Palette.income)),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 118,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final p in points)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  _bar(p.expenseCents, maxV, Palette.expense),
                                  const SizedBox(width: 2),
                                  _bar(p.incomeCents, maxV, Palette.income),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text('${p.month.month}月',
                                  style: TextStyle(
                                      fontSize: 10.5,
                                      color: Palette.inkFaint(context))),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _legend(context, '支出', Palette.expense),
                  const SizedBox(width: 12),
                  _legend(context, '收入', Palette.income),
                  const Spacer(),
                  if (!hide && cur.expenseCents > 0)
                    Text('本月支出 $symbol${centsToText(cur.expenseCents)}',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _bar(int cents, int maxV, Color color) {
    final h = maxV == 0 ? 2.0 : (cents / maxV * 78).clamp(2.0, 78).toDouble();
    return Container(
      width: 7,
      height: h,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _legend(BuildContext context, String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 4),
        Text(label,
            style: TextStyle(fontSize: 10.5, color: Palette.inkFaint(context))),
      ],
    );
  }
}

/// 年度细节：最忙月份、单笔平均、分类数、成就
class _YearFacts extends StatelessWidget {
  const _YearFacts(
      {required this.report, required this.symbol, required this.hide});

  final _YearReport report;
  final String symbol;
  final bool hide;

  @override
  Widget build(BuildContext context) {
    String money(int cents) => hide ? '****' : '$symbol${centsToText(cents)}';

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('这一年',
              style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
          const SizedBox(height: 10),
          _row(
              context,
              '花得最多的月份',
              report.busiestMonthCents == 0
                  ? '—'
                  : '${report.busiestMonth} 月 · ${money(report.busiestMonthCents)}'),
          _row(context, '单笔平均', money(report.avgPerRecord)),
          _row(context, '用到的分类', '${report.categoryCount} 个'),
          _row(context, '记账天数', '${report.activeDays} 天'),
          if (report.achievements.isNotEmpty) ...[
            const Divider(height: 20),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final a in report.achievements)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Palette.brand(context).withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(a,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: Palette.brand(context),
                            fontWeight: FontWeight.w600)),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
          const Spacer(),
          Text(value,
              style:
                  const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
