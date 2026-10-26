import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/insight_calc.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'theme.dart';

// ============================================================ 现金流预测

class ForecastPage extends ConsumerWidget {
  const ForecastPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent =
        ref.watch(recentEntriesProvider).valueOrNull ?? const <Entry>[];
    final balances = ref.watch(balancesProvider).valueOrNull ?? const [];
    final book = ref.watch(activeBookProvider).valueOrNull;
    final base = book?.baseCurrency ?? 'CNY';
    final rates = ref.watch(ratesProvider).valueOrNull ?? const {};
    final settings = ref.watch(settingsProvider);

    // 净资产：资产 - 负债（折算主币）
    var net = 0;
    for (final b in balances) {
      final cents = toBaseCents(b.balanceCents, b.pocket.currency, base, rates);
      net += cents;
    }
    final now = DateTime.now();
    final from = now.subtract(const Duration(days: 30));
    var expense = 0;
    var income = 0;
    // 样本必须折算成主币：这里原来是裸和，
    // 一笔 100 USD（7.1）+ 一笔 100 CNY 会算成日均 ¥6.6（真实 ¥27），
    // 「钱够用多少天」被拉长 4 倍。
    final currencyOf = {for (final b in balances) b.pocket.id: b.pocket.currency};
    for (final e in recent) {
      if (e.day.isBefore(from)) continue;
      // 「不计入收支」的笔不参与现金流预测的样本
      if (e.excludeFromStats) continue;
      final fromCur = e.currency ?? currencyOf[e.pocketId] ?? base;
      final cents = toBaseCents(e.amountCents, fromCur, base, rates);
      if (e.flow == 'out') expense += cents;
      if (e.flow == 'in') income += cents;
    }
    final f = forecastCashFlow(
      netWorthCents: net,
      sampleExpenseCents: expense,
      sampleIncomeCents: income,
      sampleDays: 30,
    );

    String money(int c) => settings.hideAmounts
        ? '****'
        : '${settings.symbol}${centsToText(c.abs())}${c < 0 ? '' : ''}';

    return Scaffold(
      appBar: AppBar(title: const Text('现金流预测')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前净资产',
                    style: TextStyle(
                        fontSize: 11, color: Palette.inkFaint(context))),
                const SizedBox(height: 4),
                Text(money(f.netWorthCents),
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: f.netWorthCents < 0
                          ? Palette.expense
                          : Palette.ink(context),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    )),
                const SizedBox(height: 14),
                Row(
                  children: [
                    _cell(context, '7 天后', f.in7Days, settings),
                    _cell(context, '30 天后', f.in30Days, settings),
                    _cell(context, '30 天最低', f.lowestCents, settings),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('近 30 天的日均',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context))),
                const SizedBox(height: 8),
                _line(context, '日均支出',
                    '${settings.symbol}${centsToText(f.dailyExpenseCents)}/天'),
                _line(context, '日均净流入',
                    '${f.dailyNetCents >= 0 ? '+' : '-'}${settings.symbol}${centsToText(f.dailyNetCents.abs())}/天'),
                if (f.daysToZero != null)
                  _line(context, '按当前速度钱够用', '${f.daysToZero} 天'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '说明：这是「最近 30 天的节奏继续下去」的线性外推，'
            '不考虑你还没发生的收入、也不考虑一次性大额（比如交房租）。'
            '用来判断"这个月会不会紧"，不是账务承诺。',
            style: TextStyle(
                fontSize: 11, height: 1.6, color: Palette.inkFaint(context)),
          ),
        ],
      ),
    );
  }

  Widget _cell(BuildContext context, String label, int cents, AppSettings s) {
    return Expanded(
      child: Column(
        children: [
          Text(label,
              style:
                  TextStyle(fontSize: 10.5, color: Palette.inkFaint(context))),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              s.hideAmounts
                  ? '****'
                  : '${cents < 0 ? '-' : ''}${s.symbol}${centsToText(cents.abs())}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: cents < 0 ? Palette.expense : Palette.ink(context),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(label,
              style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
          const Spacer(),
          Text(value,
              style:
                  const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

// ============================================================ 订阅猎人

class SubscriptionsPage extends ConsumerWidget {
  const SubscriptionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries =
        ref.watch(halfYearEntriesProvider).valueOrNull ?? const <Entry>[];
    final settings = ref.watch(settingsProvider);
    final list = findSubscriptions(entries);
    final monthly = list.fold<int>(0, (s, c) => s + c.cents);

    return Scaffold(
      appBar: AppBar(title: const Text('订阅猎人')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          Panel(
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('每月固定支出',
                          style: TextStyle(
                              fontSize: 11, color: Palette.inkFaint(context))),
                      const SizedBox(height: 4),
                      Text(
                        settings.hideAmounts
                            ? '****'
                            : '${settings.symbol}${centsToText(monthly)}',
                        style: const TextStyle(
                            fontSize: 24, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('一年就是',
                        style: TextStyle(
                            fontSize: 10.5, color: Palette.inkFaint(context))),
                    Text(
                      settings.hideAmounts
                          ? '****'
                          : '${settings.symbol}${centsToText(monthly * 12)}',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Palette.expense),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (list.isEmpty)
            const EmptyView(
              icon: Icons.subscriptions_outlined,
              title: '没找到像订阅的支出',
              hint: '同一备注、金额接近、连续两三个月都有的支出才能被识别',
            )
          else
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < list.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 16),
                    ListTile(
                      dense: true,
                      title: Text(list[i].label,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '出现 ${list[i].months} 个月 · 最近 ${dayKey(list[i].lastDay)}',
                        style: const TextStyle(fontSize: 10.5),
                      ),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            settings.hideAmounts
                                ? '****'
                                : '${settings.symbol}${centsToText(list[i].cents)}',
                            style: const TextStyle(
                                fontSize: 13.5, fontWeight: FontWeight.w600),
                          ),
                          Text(
                              '年 ${settings.symbol}${centsToText(list[i].yearlyCents)}',
                              style: TextStyle(
                                  fontSize: 9.5,
                                  color: Palette.inkFaint(context))),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            '识别规则（故意保守）：备注相同、金额相差不超过 1%、至少在 2 个月里出现。'
            '所以不是每个订阅都能抓到，也基本不会把日常消费误判成订阅。',
            style: TextStyle(
                fontSize: 11, height: 1.6, color: Palette.inkFaint(context)),
          ),
        ],
      ),
    );
  }
}

// ============================================================ 消费热力图

class HeatmapPage extends ConsumerWidget {
  const HeatmapPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries =
        ref.watch(recentEntriesProvider).valueOrNull ?? const <Entry>[];
    final data = buildHeatmap(entries, weeks: 12);
    final settings = ref.watch(settingsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('消费热力')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('近 12 周 · 每天花多少',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context))),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const SizedBox(width: 18),
                    for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
                      Expanded(
                        child: Center(
                          child: Text(w,
                              style: TextStyle(
                                  fontSize: 9,
                                  color: Palette.inkFaint(context))),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                for (var week = 0; week < data.grid.length; week++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 1.5),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 18,
                          child: Text('${week + 1}',
                              style: TextStyle(
                                  fontSize: 8,
                                  color: Palette.inkFaint(context))),
                        ),
                        for (var d = 0; d < 7; d++)
                          Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 1.5),
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: _heat(context, data.grid[week][d],
                                        data.maxCents),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text('少',
                        style: TextStyle(
                            fontSize: 9, color: Palette.inkFaint(context))),
                    const SizedBox(width: 4),
                    for (final v in [0.0, 0.25, 0.5, 0.75, 1.0])
                      Container(
                        width: 12,
                        height: 12,
                        margin: const EdgeInsets.only(right: 3),
                        decoration: BoxDecoration(
                          color: _heat(context, (v * data.maxCents).round(),
                              data.maxCents),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    const SizedBox(width: 4),
                    Text('多',
                        style: TextStyle(
                            fontSize: 9, color: Palette.inkFaint(context))),
                    const Spacer(),
                    if (settings.hideAmounts)
                      Text('金额已隐藏',
                          style: TextStyle(
                              fontSize: 9, color: Palette.inkFaint(context))),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '颜色越深当天花得越多。找找规律：是周末集中花，还是每周三固定一笔？',
            style: TextStyle(
                fontSize: 11, height: 1.6, color: Palette.inkFaint(context)),
          ),
        ],
      ),
    );
  }

  /// 热力色由主题主色推导：暗色模式下不会再出现一片惨白的格子。
  static Color _heat(BuildContext context, int cents, int max) {
    final base = Palette.brand(context);
    if (cents <= 0 || max <= 0) {
      return Palette.hairline(context).withValues(alpha: 0.55);
    }
    final t = (cents / max).clamp(0.12, 1.0);
    final faint = Color.lerp(base, Palette.card(context), 0.80)!;
    return Color.lerp(faint, base, t)!;
  }
}

// ============================================================ 碳足迹

class CarbonPage extends ConsumerWidget {
  const CarbonPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(monthProvider);
    final buckets =
        ref.watch(bucketsProvider('out')).valueOrNull ?? const <Bucket>[];
    final spent = ref.watch(bucketSpentProvider).valueOrNull ?? const {};
    final settings = ref.watch(settingsProvider);

    var totalGrams = 0;
    final rows = <({String title, int cents, int grams})>[];
    for (final b in buckets) {
      final cents = spent[b.id] ?? 0;
      if (cents <= 0) continue;
      final grams = estimateCarbonGrams(b.title, cents);
      totalGrams += grams;
      rows.add((title: b.title, cents: cents, grams: grams));
    }
    rows.sort((a, b) => b.grams.compareTo(a.grams));

    return Scaffold(
      appBar: AppBar(title: const Text('碳足迹（估算）')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${monthTitle(month)} 估算碳排放',
                    style: TextStyle(
                        fontSize: 11, color: Palette.inkFaint(context))),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text((totalGrams / 1000).toStringAsFixed(1),
                        style: const TextStyle(
                            fontSize: 28, fontWeight: FontWeight.w700)),
                    const Padding(
                      padding: EdgeInsets.only(left: 4, bottom: 5),
                      child: Text('kg CO₂e', style: TextStyle(fontSize: 12)),
                    ),
                    const Spacer(),
                    Text('≈ ${treesNeeded(totalGrams)} 棵树吸收一年',
                        style: TextStyle(
                            fontSize: 11, color: Palette.inkSoft(context))),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (rows.isEmpty)
            const EmptyView(icon: Icons.eco_outlined, title: '这个月还没有支出记录')
          else
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 16),
                    ListTile(
                      dense: true,
                      title: Text(rows[i].title),
                      subtitle: Text(
                        settings.hideAmounts
                            ? '****'
                            : '花了 ${settings.symbol}${centsToText(rows[i].cents)}',
                        style: const TextStyle(fontSize: 10.5),
                      ),
                      trailing: Text(
                          '${(rows[i].grams / 1000).toStringAsFixed(1)} kg',
                          style: const TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 12),
          Text(
            '这是粗略估算：按分类给每元支出一个碳排放系数（交通 300g、购物 200g、餐饮 150g…），'
            '不是真实核算，只能用来比较"哪类花销更费地球"。',
            style: TextStyle(
                fontSize: 11, height: 1.6, color: Palette.inkFaint(context)),
          ),
        ],
      ),
    );
  }
}

// ============================================================ 情绪账本

class MoodPage extends ConsumerWidget {
  const MoodPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries =
        ref.watch(recentEntriesProvider).valueOrNull ?? const <Entry>[];
    final settings = ref.watch(settingsProvider);
    final s = moodStats(entries);

    return Scaffold(
      appBar: AppBar(title: const Text('情绪账本')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('近 90 天标记了 ${s.marked} 笔',
                    style: TextStyle(
                        fontSize: 11, color: Palette.inkFaint(context))),
                const SizedBox(height: 10),
                if (s.marked == 0)
                  Text('还没有标记过情绪。记账时在支出下面选「值 / 一般 / 后悔」，这里就会有统计。',
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: Palette.inkSoft(context)))
                else ...[
                  Row(
                    children: [
                      _moodCell(context, '😊 值', s.worthIt, Palette.income),
                      _moodCell(context, '😐 一般', s.neutral,
                          Palette.inkSoft(context)),
                      _moodCell(context, '😣 后悔', s.regret, Palette.expense),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: s.regretRate,
                      minHeight: 8,
                      backgroundColor: Palette.hairline(context),
                      valueColor: AlwaysStoppedAnimation(Palette.expense),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '后悔率 ${(s.regretRate * 100).round()}%'
                    '${settings.hideAmounts ? '' : ' · 后悔金额 ${settings.symbol}${centsToText(s.regretCents)}'}',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context)),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '情绪是你自己标的，不是系统猜的。标几周之后，你会看到"哪类花销最容易后悔"——'
            '这比单纯看金额有用。',
            style: TextStyle(
                fontSize: 11, height: 1.6, color: Palette.inkFaint(context)),
          ),
        ],
      ),
    );
  }

  Widget _moodCell(BuildContext context, String label, int count, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text('$count',
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w700, color: color)),
          Text(label,
              style:
                  TextStyle(fontSize: 10.5, color: Palette.inkFaint(context))),
        ],
      ),
    );
  }
}

// ============================================================ 如果模拟器

class SimulatorPage extends ConsumerStatefulWidget {
  const SimulatorPage({super.key});

  @override
  ConsumerState<SimulatorPage> createState() => _SimulatorPageState();
}

class _SimulatorPageState extends ConsumerState<SimulatorPage> {
  int _dailyCents = 1500; // 默认每天 15 元
  int _days = 365;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final total = simulateSaving(dailyCents: _dailyCents, days: _days);

    return Scaffold(
      appBar: AppBar(title: const Text('如果…')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('如果每天少花',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context))),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                        '${settings.symbol}${(_dailyCents / 100).toStringAsFixed(0)}',
                        style: const TextStyle(
                            fontSize: 34, fontWeight: FontWeight.w700)),
                    Padding(
                      padding: const EdgeInsets.only(left: 6, bottom: 6),
                      child: Text('每天',
                          style: TextStyle(
                              fontSize: 12, color: Palette.inkSoft(context))),
                    ),
                  ],
                ),
                Slider(
                  value: _dailyCents.toDouble(),
                  min: 100,
                  max: 10000,
                  divisions: 99,
                  label: '${(_dailyCents / 100).toStringAsFixed(0)} 元',
                  onChanged: (v) => setState(() => _dailyCents = v.round()),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final preset in const [
                      ('一杯咖啡', 1500),
                      ('一顿外卖', 2500),
                      ('烟钱', 2000),
                      ('打车改公交', 800),
                    ])
                      ActionChip(
                        label: Text(preset.$1,
                            style: const TextStyle(fontSize: 11)),
                        onPressed: () =>
                            setState(() => _dailyCents = preset.$2),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Text('坚持', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 8),
                    for (final d in const [30, 90, 365])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(d == 365 ? '一年' : '$d 天',
                              style: const TextStyle(fontSize: 11)),
                          selected: _days == d,
                          onSelected: (_) => setState(() => _days = d),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Text('能省下',
                    style: TextStyle(
                        fontSize: 11, color: Palette.inkFaint(context))),
                const SizedBox(height: 4),
                Text(
                  settings.hideAmounts
                      ? '****'
                      : '${settings.symbol}${centsToText(total)}',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w700,
                    color: Palette.income,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _days == 365
                      ? '相当于 ${(total / 100 / 30).toStringAsFixed(0)} 天的日均生活费'
                      : '这笔钱够买 ${(total / 100 / 3000).toStringAsFixed(1)} 台三千块的手机',
                  style: TextStyle(
                      fontSize: 11.5, color: Palette.inkSoft(context)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text('只是算术：每天省 X 元 × N 天。真正的难点从来不是算不出来。',
              style: TextStyle(
                  fontSize: 11, height: 1.6, color: Palette.inkFaint(context))),
        ],
      ),
    );
  }
}
