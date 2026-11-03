/// 到期提醒的「纯逻辑」层：把"某天该干嘛"换算成一组通知计划。
///
/// 故意不放任何 Flutter / 插件依赖，方便单测（见 test/due_reminder_test.dart）。
/// 通知的真正发送在 [ReminderService]，这里只负责算出"该在哪些天提醒什么"。

library;

import '../data/store.dart';

/// 一项"某天到期"的事。到期前 [leadDays] 天 + 当天各发一条通知。
class DueReminder {
  const DueReminder({
    required this.kind,
    required this.entityId,
    required this.title,
    required this.body,
    required this.occurrence,
  });

  /// 类型：'card_pay' 信用卡还款 / 'card_bill' 账单日 / 'debt' 借还款 / 'goal' 目标
  final String kind;

  /// 实体 id（账户 / 借还款 / 目标的 id）。
  final int entityId;

  /// 通知标题。
  final String title;

  /// 通知正文（不含"还有 N 天"前缀，前缀由发送方补）。
  final String body;

  /// 到期那一天（已归一化到零点）。
  final DateTime occurrence;
}

DateTime _zeroOf(DateTime d) => DateTime(d.year, d.month, d.day);

/// 把"每月 X 日"安全转成具体日期：月份不足 X 天时退回当月最后一天
///（避免 2 月 31 日被 Dart 自动顺延到 3 月，提醒错一周）。
DateTime _safeDay(int year, int month, int day) {
  final dim = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, day > dim ? dim : day);
}

/// 下一次"每月 [monthDay] 日"落在 [from, from+withinDays] 的日期（归一化零点）。
///
/// 信用卡还款日 / 账单日每月循环出现，所以往后看最多 3 个候选月就够了。
List<DateTime> nextMonthlyOccurrences(
  int monthDay,
  DateTime from, {
  int withinDays = 45,
}) {
  final out = <DateTime>[];
  var cursor = DateTime(from.year, from.month, 1);
  for (var i = 0; i < 3; i++) {
    final candidate = _safeDay(cursor.year, cursor.month, monthDay);
    final days = candidate.difference(_zeroOf(from)).inDays;
    if (days >= 0 && days <= withinDays) out.add(candidate);
    cursor = DateTime(cursor.year, cursor.month + 1, 1);
  }
  return out;
}

/// 一次性日期（目标截止 / 借还款到期）若落在窗口内则返回，否则 null。
DateTime? nextOneTimeOccurrence(
  DateTime? date,
  DateTime from, {
  int withinDays = 45,
}) {
  if (date == null) return null;
  final d = _zeroOf(date);
  final days = d.difference(_zeroOf(from)).inDays;
  if (days >= 0 && days <= withinDays) return d;
  return null;
}

String _money(int cents, String symbol) {
  final yuan = cents / 100;
  final s = yuan == yuan.roundToDouble()
      ? yuan.toStringAsFixed(0)
      : yuan.toStringAsFixed(2);
  return '$symbol$s';
}

/// 把账户 / 目标 / 借还款汇总成到期提醒计划。
///
/// [symbol] 用于金额前缀（借还款 / 目标会显示金额）。[leadDays] 提前天数。
List<DueReminder> buildDueReminders(
  List<Pocket> pockets,
  List<Goal> goals,
  List<Debt> debts, {
  required DateTime now,
  required int leadDays,
  required String symbol,
}) {
  final out = <DueReminder>[];

  for (final p in pockets) {
    // 还款日：逾期一天上征信，这是记账 App 最该替用户记住的事。
    if (p.paymentDueDay != null) {
      for (final occ in nextMonthlyOccurrences(p.paymentDueDay!, now,
          withinDays: leadDays + 40)) {
        out.add(DueReminder(
          kind: 'card_pay',
          entityId: p.id,
          title: '信用卡还款日',
          body: '${p.displayName}（每月 ${p.paymentDueDay} 日）',
          occurrence: occ,
        ));
      }
    }
    // 账单日：提醒核对，不催还款。
    if (p.billingDay != null) {
      for (final occ in nextMonthlyOccurrences(p.billingDay!, now,
          withinDays: leadDays + 40)) {
        out.add(DueReminder(
          kind: 'card_bill',
          entityId: p.id + 100000, // 与还款日区分，避免通知 id 撞车
          title: '信用卡账单日',
          body: '${p.displayName}（每月 ${p.billingDay} 日），记得核对',
          occurrence: occ,
        ));
      }
    }
  }

  for (final g in goals) {
    final occ = nextOneTimeOccurrence(g.dueDay, now, withinDays: leadDays + 40);
    if (occ != null) {
      out.add(DueReminder(
        kind: 'goal',
        entityId: g.id,
        title: '目标截止日',
        body: '${g.title}（目标 ${_money(g.targetCents, symbol)}）',
        occurrence: occ,
      ));
    }
  }

  for (final d in debts) {
    final occ = nextOneTimeOccurrence(d.dueOn, now, withinDays: leadDays + 40);
    if (occ != null) {
      final who = d.direction == 'lend' ? '借出应收回' : '借款应归还';
      out.add(DueReminder(
        kind: 'debt',
        entityId: d.id,
        title: who,
        body: '对 ${d.counterparty} 的 ${_money(d.principalCents, symbol)}',
        occurrence: occ,
      ));
    }
  }

  return out;
}
