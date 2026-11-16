/// 保存前的防错判断（纯函数，不碰数据库）。
///
/// 目标只有一个：挡住「手滑连点两次保存」产生的重复账，
/// 不能挡住真的要在短时间内记两笔相同金额的合法场景。
/// 所以判定条件刻意收紧：同账户、同金额、同备注、同流向、60 秒内。
library;

import '../data/store.dart';

/// 重复保存判定窗口。
const Duration kDuplicateWindow = Duration(seconds: 60);

/// [candidate] 是刚写进库、时间最新的那一笔（同账户同金额同备注同流向已由调用方筛过）。
///
/// 返回 true 的条件：
/// - 不是软删除的笔
/// - 至少有一笔的 day 与 now 同一天
/// - 用 `day + timeMinutes` 还原出的保存时刻落在 [now] 前 60 秒内
///
/// ⚠️ 补记历史流水时 `timeMinutes` 为空（见 saveTimeMinutes），这类笔不能算
/// 「刚刚记的」，直接跳过 —— 否则补记昨天的一笔会拦住今天同额的记账。
bool isRecentDuplicate({
  required Entry candidate,
  required DateTime now,
  Duration window = kDuplicateWindow,
}) {
  if (candidate.deletedAt != null) return false;
  final t = candidate.timeMinutes;
  if (t == null) return false;
  if (candidate.day.year != now.year ||
      candidate.day.month != now.month ||
      candidate.day.day != now.day) {
    return false;
  }
  final savedAt = DateTime(
    candidate.day.year,
    candidate.day.month,
    candidate.day.day,
    t ~/ 60,
    t % 60,
  );
  final diff = now.difference(savedAt);
  return !diff.isNegative && diff <= window;
}

/// 给一组候选流水，判断是否命中重复。取最新一笔即可（调用方按 id DESC 取）。
bool anyRecentDuplicate({
  required Iterable<Entry> candidates,
  required DateTime now,
  Duration window = kDuplicateWindow,
}) =>
    candidates.any((e) => isRecentDuplicate(candidate: e, now: now, window: window));
