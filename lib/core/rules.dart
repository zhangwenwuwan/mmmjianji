/// 金额与日期的基础规则。
///
/// 设计决定（与"参考实现"刻意不同）：金额统一用 **整数分** 存储和运算，
/// 浮点数只出现在输入解析的最后一刻。这样加总一百万笔也不会出现 0.01 的漂移。
library;

import 'package:intl/intl.dart';

/// 把用户输入的 "12.30" / "12.3" / "12" / ".5" 解析成分。
/// 非法输入返回 null。最多接受两位小数，多余的位数直接截断（不再四舍五入，
/// 免得用户看到自己没输入过的数字）。
int? parseAmountToCents(String raw) {
  var text = raw.trim().replaceAll(',', '').replaceAll('，', '');
  if (text.isEmpty) return null;
  if (text.startsWith('+')) text = text.substring(1);
  final negative = text.startsWith('-');
  if (negative) text = text.substring(1);
  if (text.isEmpty) return null;

  final parts = text.split('.');
  if (parts.length > 2) return null;
  final whole = parts.first;
  final fraction = parts.length == 2 ? parts[1] : '';

  if (whole.isNotEmpty && int.tryParse(whole) == null) return null;
  if (fraction.isNotEmpty && int.tryParse(fraction) == null) return null;
  if (whole.isEmpty && fraction.isEmpty) return null;

  final wholeCents = (whole.isEmpty ? 0 : int.parse(whole)) * 100;
  final fracText = fraction.padRight(2, '0').substring(0, 2);
  final fracCents = fracText.isEmpty ? 0 : int.parse(fracText);
  final total = wholeCents + fracCents;
  return negative ? -total : total;
}

final _grouped = NumberFormat('#,##0.##');
final _plain = NumberFormat('#,##0.00');

/// 分 → 展示文本。整数金额不带 ".00"（记账界面里更清爽）。
String centsToText(int cents, {bool alwaysTwoDecimals = false}) {
  final value = cents / 100.0;
  if (alwaysTwoDecimals) return _plain.format(value);
  // 用整数运算判断是否有小数，避免浮点误差
  if (cents % 100 == 0) return _grouped.format(cents ~/ 100);
  return _grouped.format(value);
}

/// 计算器的二元运算：acc 和 v **都是分**，返回也是分。
///
/// ⚠️ 加减可以直接相加，但乘除必须在「元」域做，否则会凭空缩放 100 倍：
/// 17 元 × 2 元 = 1700 分 × 200 分 = 340000 分 = 3400 元（用户眼里的 34 元被放大成 3400）。
/// 所以乘法要除回 100、除法要乘回 100。
///
/// 除数为 0 时返回 acc 本身（按 ÷ 再按 0 不该把屏幕清空）。
int applyAmountOp(int acc, String op, int v) => switch (op) {
      '+' => acc + v,
      '-' => acc - v,
      '×' => (acc * v) ~/ 100,
      '÷' => v == 0 ? acc : (acc * 100) ~/ v,
      _ => v,
    };

/// 分 → 带符号文本（支出为负）。
String centsToSignedText(int cents) {
  if (cents == 0) return centsToText(0);
  final sign = cents > 0 ? '+' : '-';
  return '$sign${centsToText(cents.abs())}';
}

/// 月份键：2026-10
String monthKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}';

/// 日期键：2026-10-21（数据库里就存这个，字符串排序天然等于时间排序）
String dayKey(DateTime date) =>
    '${monthKey(date)}-${date.day.toString().padLeft(2, '0')}';

DateTime firstDayOfMonth(DateTime date) => DateTime(date.year, date.month);

DateTime lastDayOfMonth(DateTime date) =>
    DateTime(date.year, date.month + 1, 0);

/// 某月天数
int daysInMonth(DateTime date) => lastDayOfMonth(date).day;

/// 月份增减
DateTime shiftMonth(DateTime month, int delta) =>
    DateTime(month.year, month.month + delta);

/// 中文月份标题：2026 年 10 月
String monthTitle(DateTime month) => '${month.year} 年 ${month.month} 月';

/// 展示用日期：10月21日
String dayLabel(DateTime d) => '${d.month} 月 ${d.day} 日';

/// 今天所在月份还剩多少天（含今天）
int daysLeftInMonth(DateTime today) => daysInMonth(today) - today.day + 1;

/// 两位补零（时间、日期拼接用）
String pad2(int v) => v.toString().padLeft(2, '0');

/// 字节数 → 人话（B / KB / MB）。
/// 之前存储页和数据管理页各抄了一份，改一处另一处就过期。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
}

/// 把「日」夹到该年月的合法范围（1..天数）。
///
/// 2 月 29 日切到平年 → 28；1 月 31 日切到 4 月 → 30。
int clampDayOfMonth(int day, int year, int month) {
  final max = daysInMonth(DateTime(year, month));
  if (day < 1) return 1;
  if (day > max) return max;
  return day;
}
