import 'package:flutter_test/flutter_test.dart';

import 'package:jianji/state/ledger_state.dart';

/// 2026-10-26 用户要求：统计页头部改成「周 / 月 / 年 / 全部 / 范围」五段 + 一行日期。
/// 数据层原本只有 month/year/all/custom 四档，缺 week，这里补并钉住边界。
void main() {
  group('周区间', () {
    test('任意一天都落进自己那一周（周一 ~ 周日，共 7 天）', () {
      for (var i = 0; i < 40; i++) {
        final day = DateTime(2026, 10, 1).add(Duration(days: i));
        final r = weekRangeOf(day);
        expect(r.from.weekday, DateTime.monday, reason: '$day 的周首');
        expect(r.to.weekday, DateTime.sunday, reason: '$day 的周末');
        expect(r.to.difference(r.from).inDays, 6);
        expect(day.isBefore(r.from), isFalse, reason: '$day 不该早于周首');
        expect(day.isAfter(r.to), isFalse, reason: '$day 不该晚于周末');
      }
    });

    test('跨月的那周两端不同月（10/26 这周含 11 月 1 日）', () {
      final r = weekRangeOf(DateTime(2026, 10, 26));
      // 2026-10-26 是周一，这一周是 10/26 ~ 11/1
      expect(r.from, DateTime(2026, 10, 26));
      expect(r.to, DateTime(2026, 11, 1));
      expect(r.from.month, isNot(r.to.month));
    });

    test('带时分秒的锚点不会把周首算成前一天', () {
      // 凌晨 vs 深夜都要落在同一周：这是 weekRangeOf 先归一化再减的原因
      final early = DateTime(2026, 10, 26, 0, 5);
      final late = DateTime(2026, 10, 26, 23, 55);
      expect(weekRangeOf(early).from, weekRangeOf(late).from);
      expect(weekRangeOf(early).from.hour, 0);
    });
  });

  group('insightRange 各粒度', () {
    test('week 走的是 weekRangeOf', () {
      final r = insightRange(InsightScope.week, DateTime(2026, 10, 26));
      expect(r.from, DateTime(2026, 10, 26));
      expect(r.to, DateTime(2026, 11, 1));
    });

    test('month 仍是自然月首末日（回归：别把老行为改坏）', () {
      final r = insightRange(InsightScope.month, DateTime(2026, 2, 10));
      expect(r.from, DateTime(2026, 2, 1));
      // 2026 不是闰年，2 月 28 天
      expect(r.to, DateTime(2026, 2, 28));
    });

    test('year 仍是自然年首末日', () {
      final r = insightRange(InsightScope.year, DateTime(2026, 7, 3));
      expect(r.from, DateTime(2026, 1, 1));
      expect(r.to, DateTime(2026, 12, 31));
    });

    test('custom 没选过时回退到本月，绝不返回空区间', () {
      final r = insightRange(InsightScope.custom, DateTime(2026, 5, 20));
      expect(r.from, DateTime(2026, 5, 1));
      expect(r.to, DateTime(2026, 5, 31));
      expect(r.from.isBefore(r.to), isTrue);
    });

    test('custom 传了就用传入的（两端含）', () {
      final r = insightRange(InsightScope.custom, DateTime(2026, 5, 20),
          custom: (from: DateTime(2024, 3, 2), to: DateTime(2025, 1, 9)));
      expect(r.from, DateTime(2024, 3, 2));
      expect(r.to, DateTime(2025, 1, 9));
    });

    test('all 放得足够宽（1900~2200），导入的刁钻日期不会被吞', () {
      final r = insightRange(InsightScope.all, DateTime(2026, 1, 1));
      expect(r.from, DateTime(1900, 1, 1));
      expect(r.to, DateTime(2200, 12, 31));
    });
  });
}
