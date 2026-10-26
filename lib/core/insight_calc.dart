/// 洞察类纯计算：预测、订阅识别、热力图、碳足迹、情绪、如果模拟器。
///
/// 全部是纯函数，输入流水、输出结果——不碰数据库，方便穷举测试。
/// 凡是"估算"的（碳足迹）都在返回值里标出来，不假装精确。
library;

import '../data/store.dart';
import 'rules.dart';

// ---------------------------------------------------------------- 现金流预测

class Forecast {
  const Forecast({
    required this.netWorthCents,
    required this.dailyNetCents,
    required this.dailyExpenseCents,
    required this.in7Days,
    required this.in30Days,
    required this.lowestCents,
    required this.daysToZero,
  });

  final int netWorthCents;
  final int dailyNetCents;
  final int dailyExpenseCents;
  final int in7Days;
  final int in30Days;

  /// 未来 30 天里的最低点（考虑收入也会有波动时不过是线性外推）
  final int lowestCents;

  /// 按当前日均支出，钱能撑多少天（负值表示已经为负）
  final int? daysToZero;
}

/// 用最近 N 天的日均收支做线性外推。
///
/// [days] 是样本天数（建议 30），[netWorthCents] 是当前净资产。
Forecast forecastCashFlow({
  required int netWorthCents,
  required int sampleExpenseCents,
  required int sampleIncomeCents,
  required int sampleDays,
}) {
  final days = sampleDays <= 0 ? 1 : sampleDays;
  final dailyExpense = sampleExpenseCents ~/ days;
  final dailyIncome = sampleIncomeCents ~/ days;
  final dailyNet = dailyIncome - dailyExpense;

  int at(int n) => netWorthCents + dailyNet * n;

  // 30 天内的最低点：净流入为正时最低就是当前值
  var lowest = netWorthCents;
  if (dailyNet < 0) lowest = at(30);

  int? daysToZero;
  if (netWorthCents <= 0) {
    daysToZero = 0;
  } else if (dailyNet < 0) {
    daysToZero = (netWorthCents / -dailyNet).floor();
  } else if (dailyExpense > 0) {
    // 净流入非负时不会见底，但按"只花不赚"能给个保守答案
    daysToZero = null;
  }

  return Forecast(
    netWorthCents: netWorthCents,
    dailyNetCents: dailyNet,
    dailyExpenseCents: dailyExpense,
    in7Days: at(7),
    in30Days: at(30),
    lowestCents: lowest,
    daysToZero: daysToZero,
  );
}

// ---------------------------------------------------------------- 订阅识别

class SubscriptionCandidate {
  const SubscriptionCandidate({
    required this.label,
    required this.cents,
    required this.months,
    required this.lastDay,
  });

  final String label;
  final int cents;

  /// 出现过几个月（≥2 才算候选）
  final int months;
  final DateTime lastDay;

  int get yearlyCents => cents * 12;
}

/// 找出"像订阅"的支出：同一备注/分类、金额基本相同、在不同月份反复出现。
///
/// 规则刻意保守（宁可漏报也不误报）：金额必须一致（允许 1% 浮动，应付调价），
/// 至少出现在 2 个不同月份。
List<SubscriptionCandidate> findSubscriptions(List<Entry> entries) {
  final groups = <String, List<Entry>>{};
  for (final e in entries) {
    if (e.flow != 'out') continue;
    final label = e.memo.trim().isEmpty ? null : e.memo.trim();
    if (label == null) continue; // 没备注的不猜
    groups.putIfAbsent(label, () => []).add(e);
  }

  final result = <SubscriptionCandidate>[];
  for (final entry in groups.entries) {
    final list = entry.value;
    final months = <String>{for (final e in list) monthKey(e.day)};
    if (months.length < 2) continue;
    // 取众数金额（出现最多的那个）
    final amountCount = <int, int>{};
    for (final e in list) {
      amountCount[e.amountCents] = (amountCount[e.amountCents] ?? 0) + 1;
    }
    final sorted = amountCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final cents = sorted.first.key;
    // 金额与主金额相差超过 1% 的视为不同消费，剔除
    final sameAmount =
        list.where((e) => (e.amountCents - cents).abs() <= cents * 0.01);
    final sameMonths = <String>{for (final e in sameAmount) monthKey(e.day)};
    if (sameMonths.length < 2) continue;
    list.sort((a, b) => b.day.compareTo(a.day));
    result.add(SubscriptionCandidate(
      label: entry.key,
      cents: cents,
      months: sameMonths.length,
      lastDay: list.first.day,
    ));
  }
  result.sort((a, b) => b.cents.compareTo(a.cents));
  return result;
}

// ---------------------------------------------------------------- 消费热力图

/// 近 [weeks] 周、按「周一~周日 × 周」排列的支出强度
class HeatmapData {
  const HeatmapData(
      {required this.grid, required this.maxCents, required this.startDay});

  /// grid[week][weekday]，weekday 0=周一
  final List<List<int>> grid;
  final int maxCents;
  final DateTime startDay;
}

HeatmapData buildHeatmap(List<Entry> entries,
    {int weeks = 12, DateTime? today}) {
  final now = today ?? DateTime.now();
  final todayDate = DateTime(now.year, now.month, now.day);
  // 本周周一
  final thisMonday = todayDate.subtract(Duration(days: todayDate.weekday - 1));
  final start = thisMonday.subtract(Duration(days: (weeks - 1) * 7));

  final grid = List.generate(weeks, (_) => List<int>.filled(7, 0));
  for (final e in entries) {
    if (e.flow != 'out') continue;
    final d = DateTime(e.day.year, e.day.month, e.day.day);
    final diff = d.difference(start).inDays;
    if (diff < 0 || diff >= weeks * 7) continue;
    final week = diff ~/ 7;
    final weekday = diff % 7;
    grid[week][weekday] += e.amountCents;
  }
  var maxCents = 0;
  for (final w in grid) {
    for (final v in w) {
      if (v > maxCents) maxCents = v;
    }
  }
  return HeatmapData(grid: grid, maxCents: maxCents, startDay: start);
}

// ---------------------------------------------------------------- 碳足迹

/// 每元支出的估算碳排放（克 CO₂e）。**这是粗略估算**，不是核算。
const Map<String, int> kCarbonGramsPerYuan = {
  '交通': 300,
  '餐饮': 150,
  '购物': 200,
  '居住': 100,
  '娱乐': 120,
  '医疗': 80,
  '学习': 50,
  '其他': 100,
};

int estimateCarbonGrams(String bucketTitle, int cents) {
  final yuan = cents / 100.0;
  final perYuan = kCarbonGramsPerYuan[bucketTitle] ?? 100;
  return (yuan * perYuan).round();
}

/// 一棵树一年大约吸收 18.3 kg CO₂e
int treesNeeded(int grams) => (grams / 18300).ceil();

// ---------------------------------------------------------------- 情绪账本

class MoodStats {
  const MoodStats({
    required this.marked,
    required this.worthIt,
    required this.neutral,
    required this.regret,
    required this.regretCents,
    required this.markedCents,
  });

  final int marked;
  final int worthIt;
  final int neutral;
  final int regret;
  final int regretCents;
  final int markedCents;

  double get regretRate => marked == 0 ? 0 : regret / marked;
  double get worthRate => marked == 0 ? 0 : worthIt / marked;
}

MoodStats moodStats(List<Entry> entries) {
  var worthIt = 0;
  var neutral = 0;
  var regret = 0;
  var regretCents = 0;
  var markedCents = 0;
  for (final e in entries) {
    if (e.mood == 0) continue;
    markedCents += e.amountCents;
    switch (e.mood) {
      case 1:
        worthIt++;
      case 3:
        regret++;
        regretCents += e.amountCents;
      default:
        neutral++;
    }
  }
  return MoodStats(
    marked: worthIt + neutral + regret,
    worthIt: worthIt,
    neutral: neutral,
    regret: regret,
    regretCents: regretCents,
    markedCents: markedCents,
  );
}

// ---------------------------------------------------------------- 如果模拟器

/// 每天省 [dailyCents]，持续 [days] 天能省下多少
int simulateSaving({required int dailyCents, required int days}) =>
    dailyCents <= 0 || days <= 0 ? 0 : dailyCents * days;
