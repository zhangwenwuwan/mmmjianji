/// 会员订阅的纯计算层：倒计时、状态、排序。
///
/// 不依赖 Flutter（和 core/due_reminders.dart 同一套路），方便单测：
/// 见 test/subscription_test.dart。
library;

import '../data/store.dart';

/// 一张订阅卡现在该长什么样（决定颜色和文案）。
enum SubscriptionState {
  /// 提醒窗口内（距离到期 <= remindDays 天）
  soon,

  /// 还早
  normal,

  /// 今天到期
  today,

  /// 已经过期
  expired,
}

/// 倒计时结果。[days] 负数 = 已过期多少天。
class SubscriptionCountdown {
  const SubscriptionCountdown({required this.days, required this.state});

  final int days;
  final SubscriptionState state;

  bool get urgent =>
      state == SubscriptionState.soon ||
      state == SubscriptionState.today ||
      state == SubscriptionState.expired;

  String get text => switch (state) {
        SubscriptionState.expired => '已过期 ${-days} 天',
        SubscriptionState.today => '今天到期',
        _ => '还有 $days 天到期',
      };
}

DateTime _zero(DateTime d) => DateTime(d.year, d.month, d.day);

/// 到期日距离 [today] 还有多少天，按自然日算（忽略时分，避免「今天下午」变成 -1）。
int daysUntil(DateTime due, DateTime today) =>
    _zero(due).difference(_zero(today)).inDays;

SubscriptionCountdown countdownOf(Subscription s, DateTime today) {
  final days = daysUntil(s.dueDate, today);
  final state = days < 0
      ? SubscriptionState.expired
      : days == 0
          ? SubscriptionState.today
          : days <= s.remindDays
              ? SubscriptionState.soon
              : SubscriptionState.normal;
  return SubscriptionCountdown(days: days, state: state);
}

/// 排序：到期日升序（快到期的在最上面），同一天按 id 稳定。
int compareSubscriptions(Subscription a, Subscription b) {
  final c = a.dueDate.compareTo(b.dueDate);
  return c != 0 ? c : a.id.compareTo(b.id);
}

/// 今天起 [days] 天内到期的订阅数（给洞察页入口卡显示「N 个即将到期」）。
///
/// 已过期的不算：它们该显示在列表顶部并被看见，但「即将到期」是一句催办话术，
/// 把过期项也算进去会让这个数字长期不归零。
int expiringSoonCount(List<Subscription> all, DateTime today, {int days = 30}) =>
    all.where((s) {
      final left = daysUntil(s.dueDate, today);
      return left >= 0 && left <= days;
    }).length;
