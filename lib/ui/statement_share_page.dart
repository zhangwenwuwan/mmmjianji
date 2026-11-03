import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/currency.dart';
import '../core/rules.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'theme.dart';

/// 「账单分享」：把一个月的账变成一张能直接发微信的图。
///
/// 为什么需要它：家里人不装 App 也想看「这个月花了多少、花在哪」。
/// 月报页（`month_summary_page.dart`）只给了汇总 + TOP5，看不到明细；
/// 这一页补的是**完整账单**：汇总 → 分类占比 → 逐笔明细。
///
/// 口径上刻意和统计页完全一致（AA 只算我的份额、排除「不计入收支」、
/// 外币按汇率折算），否则发出去的图会和 App 里对不上，反而让人怀疑账不准。
class StatementSharePage extends ConsumerStatefulWidget {
  const StatementSharePage({super.key, required this.month});

  final DateTime month;

  @override
  ConsumerState<StatementSharePage> createState() => _StatementSharePageState();
}

/// 一条明细（已折算成主币种分）。
typedef _Row = ({
  int id,
  DateTime day,
  String bucket,
  String memo,
  int cents,
  bool isIncome,
});

class _StatementData {
  const _StatementData({
    required this.incomeCents,
    required this.expenseCents,
    required this.rows,
    required this.byBucket,
    required this.totalCount,
    required this.hiddenCount,
  });

  final int incomeCents;
  final int expenseCents;
  final List<_Row> rows;
  final List<({String label, int cents})> byBucket;
  final int totalCount;
  final int hiddenCount;
}

/// 明细最多画这么多行。一张图太长分享出去会被压得看不清，
/// 而且 `toImage` 的位图内存会翻倍涨。超出的部分只报数量。
const int _kMaxRows = 80;

class _StatementSharePageState extends ConsumerState<StatementSharePage> {
  final _posterKey = GlobalKey();
  late DateTime _month;
  Future<_StatementData>? _future;

  @override
  void initState() {
    super.initState();
    _month = widget.month;
    _future = _load();
  }

  Future<_StatementData> _load() async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final rates = await store.rates(book.id);
    final pockets = await store.allPockets();
    final currencyOf = {for (final p in pockets) p.id: p.currency};
    final entries = await store.entriesOfMonth(book.id, _month);
    final bucketNames = {
      for (final b in await store.buckets(book.id, 'out', includeArchived: true))
        b.id: b.title,
    };

    var income = 0;
    var expense = 0;
    final byBucket = <String, int>{};
    final rows = <_Row>[];
    for (final e in entries) {
      if (e.flow != 'in' && e.flow != 'out') continue; // 转账不进账单
      if (e.excludeFromStats) continue; // 「不计入收支」不进来
      final from = e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency;
      // 和统计页同口径：AA 只算「我的份额」。
      final base = toBaseCents(e.statsCents, from, book.baseCurrency, rates);
      final isIncome = e.flow == 'in';
      final name = e.bucketId == null
          ? (isIncome ? '收入' : '未分类')
          : (bucketNames[e.bucketId] ?? '未分类');
      if (isIncome) {
        income += base;
      } else {
        expense += base;
        byBucket[name] = (byBucket[name] ?? 0) + base;
      }
      rows.add((
        id: e.id,
        day: e.day,
        bucket: name,
        memo: e.memo.trim(),
        cents: base,
        isIncome: isIncome,
      ));
    }
    // 账单按时间正序读起来最自然（月初 → 月末）；同一天再按 id 排，
    // 因为 List.sort 不保证稳定，只比日期的话同一天几笔会随机跳。
    rows.sort((a, b) {
      final c = a.day.compareTo(b.day);
      return c != 0 ? c : a.id.compareTo(b.id);
    });
    final slices = byBucket.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return _StatementData(
      incomeCents: income,
      expenseCents: expense,
      rows: rows.take(_kMaxRows).toList(),
      byBucket: [for (final e in slices.take(6)) (label: e.key, cents: e.value)],
      totalCount: rows.length,
      hiddenCount: rows.length > _kMaxRows ? rows.length - _kMaxRows : 0,
    );
  }

  void _shift(int delta) {
    setState(() {
      _month = DateTime(_month.year, _month.month + delta);
      _future = _load();
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
            mimeType: 'image/png',
            name: '简记-账单-${_month.year}-${_month.month}.png'),
      ], text: '简记 ${_month.year} 年 ${_month.month} 月账单');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).toast('分享失败，可先截图保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('账单分享'),
        actions: [
          IconButton(
            tooltip: '分享这张账单',
            onPressed: _share,
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          // 月份切换：放在图外面，免得把翻月箭头也画进分享图里
          Row(
            children: [
              IconButton(
                tooltip: '上个月',
                onPressed: () => _shift(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${_month.year} 年 ${_month.month} 月',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '下个月',
                onPressed: () => _shift(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          const SizedBox(height: 4),
          FutureBuilder<_StatementData>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 48),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snap.hasError || snap.data == null) {
                return EmptyView(
                    icon: Icons.error_outline,
                    title: '加载失败',
                    hint: '${snap.error}');
              }
              final d = snap.data!;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  RepaintBoundary(
                    key: _posterKey,
                    child: _StatementPoster(month: _month, data: d),
                  ),
                  const SizedBox(height: 12),
                  Panel(
                    child: Row(
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: Palette.inkFaint(context)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            d.totalCount == 0
                                ? '这个月没有计入收支的流水'
                                : '共 ${d.totalCount} 笔 · 支出按「我的份额」计'
                                    '${d.hiddenCount > 0 ? ' · 图里只画前 $_kMaxRows 笔' : ''}',
                            style: TextStyle(
                                fontSize: 12, color: Palette.inkSoft(context)),
                          ),
                        ),
                      ],
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

/// 真正被截图分享出去的那张卡。
class _StatementPoster extends ConsumerWidget {
  const _StatementPoster({required this.month, required this.data});

  final DateTime month;
  final _StatementData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final symbol = settings.symbol;
    final hide = settings.hideAmounts;
    String money(int c) => hide ? '****' : '$symbol${centsToText(c)}';
    // 负号放币种前（-¥35），别写成 ¥-35。
    String moneySigned(int c) => hide
        ? '****'
        : (c < 0 ? '-$symbol${centsToText(-c)}' : '$symbol${centsToText(c)}');
    final balance = data.incomeCents - data.expenseCents;
    final maxSlice = data.byBucket.isEmpty ? 0 : data.byBucket.first.cents;

    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: Palette.hairline(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('简记',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Palette.brand(context))),
              const SizedBox(width: 8),
              Text('${month.year} 年 ${month.month} 月账单',
                  style: TextStyle(
                      fontSize: 12, color: Palette.inkFaint(context))),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: _kv(context, '支出', money(data.expenseCents),
                    Palette.expense, big: true),
              ),
              Expanded(
                child: _kv(context, '收入', money(data.incomeCents),
                    Palette.income),
              ),
              Expanded(
                child: _kv(
                    context,
                    '结余',
                    moneySigned(balance),
                    balance < 0 ? Palette.expense : Palette.ink(context)),
              ),
            ],
          ),
          if (data.byBucket.isNotEmpty) ...[
            const SizedBox(height: 14),
            Divider(height: 1, color: Palette.hairline(context)),
            const SizedBox(height: 10),
            Text('花在哪',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Palette.inkSoft(context))),
            const SizedBox(height: 8),
            for (final s in data.byBucket)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 58,
                      child: Text(s.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Palette.ink(context))),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: maxSlice == 0 ? 0 : s.cents / maxSlice,
                          minHeight: 6,
                          color: Palette.brand(context),
                          backgroundColor:
                              Palette.brand(context).withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(money(s.cents),
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Palette.inkSoft(context),
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ],
                ),
              ),
          ],
          if (data.rows.isNotEmpty) ...[
            const SizedBox(height: 6),
            Divider(height: 1, color: Palette.hairline(context)),
            const SizedBox(height: 10),
            Text('明细',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Palette.inkSoft(context))),
            const SizedBox(height: 4),
            for (final r in data.rows) _rowLine(context, r, symbol, hide),
            if (data.hiddenCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('还有 ${data.hiddenCount} 笔未显示',
                    style: TextStyle(
                        fontSize: 11, color: Palette.inkFaint(context))),
              ),
          ],
          const SizedBox(height: 10),
          Text('简记 · 记账',
              style: TextStyle(fontSize: 10, color: Palette.inkFaint(context))),
        ],
      ),
    );
  }

  Widget _rowLine(
      BuildContext context, _Row r, String symbol, bool hide) {
    final amount = r.isIncome
        ? '+$symbol${centsToText(r.cents)}'
        : '-$symbol${centsToText(r.cents)}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text('${r.day.month}/${r.day.day}',
                style: TextStyle(
                    fontSize: 11,
                    color: Palette.inkFaint(context),
                    fontFeatures: const [FontFeature.tabularFigures()])),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              r.memo.isEmpty ? r.bucket : '${r.bucket} · ${r.memo}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: Palette.ink(context)),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            hide ? '****' : amount,
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: r.isIncome ? Palette.income : Palette.ink(context),
                fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value, Color color,
      {bool big = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
        const SizedBox(height: 2),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: big ? 24 : 15,
                height: big ? 1.15 : null,
                fontWeight: FontWeight.w800,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
  }
}
