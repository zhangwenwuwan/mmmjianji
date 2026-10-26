import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/rules.dart';
import 'package:jianji/state/ledger_state.dart';

/// 统计范围换算（insightRange）的回归测试。
///
/// 自定义范围最容易出的两个问题：
/// 1. 用户取消选择时算出无效区间 → 统计静默变空；
/// 2. 起止日的**时间部分**没被截掉 → 最后一天漏掉（dayKey 只取日期，这里要保证一致）。
void main() {
  final anchor = DateTime(2026, 10, 24);

  test('month / year / all 不受 custom 影响', () {
    final custom = (from: DateTime(2020, 1, 1), to: DateTime(2020, 1, 31));

    final m = insightRange(InsightScope.month, anchor, custom: custom);
    expect(dayKey(m.from), '2026-10-01');
    expect(dayKey(m.to), '2026-10-31');

    final y = insightRange(InsightScope.year, anchor, custom: custom);
    expect(dayKey(y.from), '2026-01-01');
    expect(dayKey(y.to), '2026-12-31');

    final a = insightRange(InsightScope.all, anchor, custom: custom);
    expect(dayKey(a.from), '1900-01-01');
    expect(dayKey(a.to), '2200-12-31');
  });

  test('custom 有值时按用户选的起止（跨月、两端都含）', () {
    final r = insightRange(
      InsightScope.custom,
      anchor,
      custom: (from: DateTime(2026, 3, 5, 18, 30), to: DateTime(2026, 4, 7, 6, 15)),
    );
    expect(dayKey(r.from), '2026-03-05', reason: '时间部分必须被截掉');
    expect(dayKey(r.to), '2026-04-07', reason: '结束日必须包含当天');
  });

  test('custom 跨年也正确', () {
    final r = insightRange(
      InsightScope.custom,
      anchor,
      custom: (from: DateTime(2025, 12, 20), to: DateTime(2026, 1, 10)),
    );
    expect(dayKey(r.from), '2025-12-20');
    expect(dayKey(r.to), '2026-01-10');
  });

  test('custom 为 null 时回退本月，绝不返回无效区间', () {
    final r = insightRange(InsightScope.custom, anchor);
    expect(dayKey(r.from), '2026-10-01');
    expect(dayKey(r.to), '2026-10-31');
    expect(r.from.isAfter(r.to), isFalse);
  });

  test('单日范围：起止同一天也成立', () {
    final r = insightRange(
      InsightScope.custom,
      anchor,
      custom: (from: DateTime(2026, 6, 18), to: DateTime(2026, 6, 18)),
    );
    expect(dayKey(r.from), dayKey(r.to));
  });
}
