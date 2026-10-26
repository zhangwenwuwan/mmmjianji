/// 应用锁的「多久之后要重新锁」判定。
///
/// 为什么抽成纯函数：这条规则决定了用户的账目在什么情况下会被重新锁住，
/// 边界（正好等于宽限期）、宽限期为 0、以及系统时钟被往回拨这三种情况
/// 最容易出 bug，而且都不该靠真机点按来验证。
library;

/// 切后台 [pausedAt] 之后，[now] 回来时是否要重新锁。
///
/// [grace] 是宽限期（0 = 每次切回都锁）。
/// 判定用「**大于**」而不是「大于等于」：正好等于宽限期的那一刻，
/// 用户多半还盯着屏幕，不该立刻弹锁。
bool shouldLockAfter({
  required DateTime pausedAt,
  required DateTime now,
  required Duration grace,
}) {
  final diff = now.difference(pausedAt);
  // 时钟回拨：差值负数。直接当成"过了很久"，宁可多锁一次也不放行。
  if (diff.isNegative) return true;
  return diff > grace;
}
