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
import 'motion.dart';
import 'statement_share_page.dart';
import 'theme.dart';

/// 某个月的报告：汇总 + 支出 Top5 + 可分享海报。
///
/// 为什么单独做一页而不是让首页直接翻月：首页是「只看本月」的，
/// `LedgerPage.build` 会把 monthProvider 立刻归位到当月。以前「10 月收支已归档」
/// 那张卡的 onTap 就是去改 monthProvider，结果被归位逻辑当场抹掉 —— 点了没反应。
/// 改成跳这一页，既不跟归位打架，也顺手把「按月报告」补上。
class MonthSummaryPage extends ConsumerStatefulWidget {
  const MonthSummaryPage({super.key, required this.month});

  final DateTime month;

  @override
  ConsumerState<MonthSummaryPage> createState() => _MonthSummaryPageState();
}

class _MonthData {
  const _MonthData({
    required this.incomeCents,
    required this.expenseCents,
    required this.count,
    required this.top,
  });

  final int incomeCents;
  final int expenseCents;
  final int count;
  final List<({String label, int cents})> top;
}

class _MonthSummaryPageState extends ConsumerState<MonthSummaryPage> {
  final _posterKey = GlobalKey();
  Future<_MonthData>? _future;

  DateTime get _month => widget.month;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_MonthData> _load() async {
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
    var count = 0;
    final byBucket = <String, int>{};
    for (final e in entries) {
      if (e.flow != 'in' && e.flow != 'out') continue;
      if (e.excludeFromStats) continue;
      count++;
      final from = e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency;
      // 和统计页同口径：AA 分摊只算「我的份额」。
      final base = toBaseCents(e.statsCents, from, book.baseCurrency, rates);
      if (e.flow == 'in') {
        income += base;
      } else {
        expense += base;
        final name = e.bucketId == null
            ? '未分类'
            : (bucketNames[e.bucketId] ?? '未分类');
        byBucket[name] = (byBucket[name] ?? 0) + base;
      }
    }
    final top = byBucket.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return _MonthData(
      incomeCents: income,
      expenseCents: expense,
      count: count,
      top: [for (final e in top.take(5)) (label: e.key, cents: e.value)],
    );
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
            name: '简记-${_month.year}-${_month.month}.png'),
      ], text: '简记 ${_month.year} 年 ${_month.month} 月账本');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).toast('分享失败，可先截图保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${_month.year} 年 ${_month.month} 月'),
        actions: [
          IconButton(
              tooltip: '分享这张月报',
              onPressed: _share,
              icon: const Icon(Icons.ios_share)),
          // 月报只有汇总 + TOP5；家里人要"看明细"时走这条，出的是完整账单图。
          IconButton(
            tooltip: '分享完整账单',
            onPressed: () => Navigator.of(context).push(
                AppPageRoute(page: StatementSharePage(month: _month))),
            icon: const Icon(Icons.article_outlined),
          ),
        ],
      ),
      body: FutureBuilder<_MonthData>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError || snap.data == null) {
            return EmptyView(
                icon: Icons.error_outline,
                title: '加载失败',
                hint: '${snap.error}');
          }
          final d = snap.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              RepaintBoundary(
                key: _posterKey,
                child: _Poster(month: _month, data: d),
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
                        d.count == 0
                            ? '这个月没有计入收支的流水'
                            : '共 ${d.count} 笔 · 支出按「我的份额」计（AA 已扣除他人承担）',
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
    );
  }
}

/// 可分享的海报卡。
class _Poster extends ConsumerWidget {
  const _Poster({required this.month, required this.data});

  final DateTime month;
  final _MonthData data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final symbol = settings.symbol;
    final hide = settings.hideAmounts;
    String money(int c) => hide ? '****' : '$symbol${centsToText(c)}';
    // 负号放币种前（-¥936），别写成 ¥-936。
    String moneySigned(int c) => hide
        ? '****'
        : (c < 0 ? '-$symbol${centsToText(-c)}' : '$symbol${centsToText(c)}');
    final balance = data.incomeCents - data.expenseCents;
    final maxTop = data.top.isEmpty ? 0 : data.top.first.cents;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
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
              Text('${month.year} 年 ${month.month} 月',
                  style: TextStyle(
                      fontSize: 12, color: Palette.inkFaint(context))),
            ],
          ),
          const SizedBox(height: 14),
          Text('支出',
              style:
                  TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          const SizedBox(height: 2),
          Text(money(data.expenseCents),
              style: TextStyle(
                  fontSize: 30,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  color: Palette.expense,
                  fontFeatures: const [FontFeature.tabularFigures()])),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _kv(context, '收入', money(data.incomeCents),
                    Palette.income),
              ),
              Expanded(
                child: _kv(context, '结余', moneySigned(balance),
                    balance < 0 ? Palette.expense : Palette.ink(context)),
              ),
            ],
          ),
          if (data.top.isNotEmpty) ...[
            const SizedBox(height: 16),
            Divider(height: 1, color: Palette.hairline(context)),
            const SizedBox(height: 12),
            Text('支出 TOP ${data.top.length}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Palette.inkSoft(context))),
            const SizedBox(height: 8),
            for (final t in data.top) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(t.label,
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
                          value: maxTop == 0 ? 0 : t.cents / maxTop,
                          minHeight: 6,
                          color: Palette.brand(context),
                          backgroundColor:
                              Palette.brand(context).withValues(alpha: 0.12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(money(t.cents),
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
          ],
          const SizedBox(height: 10),
          Text('简记 · 记账',
              style: TextStyle(fontSize: 10, color: Palette.inkFaint(context))),
        ],
      ),
    );
  }

  Widget _kv(BuildContext context, String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()])),
      ],
    );
  }
}
