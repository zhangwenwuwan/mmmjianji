import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/rules.dart';

/// 手动选时分的纯口径测试。
/// 关键：不破坏原来的「今天写当前时刻 / 补记历史留空」，
/// 用户明确选过的时间（含 00:00）才有最高优先级。
void main() {
  final today = DateTime(2026, 11, 17, 15, 42);
  final yesterday = DateTime(2026, 11, 16);

  test('格式化：null → --:--，分钟补零，越界钳制', () {
    expect(formatTimeMinutes(null), '--:--');
    expect(formatTimeMinutes(0), '00:00');
    expect(formatTimeMinutes(9 * 60 + 5), '09:05');
    expect(formatTimeMinutes(23 * 60 + 59), '23:59');
    expect(formatTimeMinutes(9999), '23:59');
  });

  test('手动选过 → 一律用它，包括历史日期和 00:00', () {
    expect(
      resolveTimeMinutes(
        day: yesterday,
        originalDay: null,
        picked: 0,
        now: today,
      ),
      0,
    );
  });

  test('没手动选 + 今天 → 用传入的当前时刻', () {
    expect(
      resolveTimeMinutes(
        day: DateTime(2026, 11, 17),
        originalDay: null,
        now: today,
      ),
      15 * 60 + 42,
    );
  });

  test('没手动选 + 历史 → 留空', () {
    expect(
      resolveTimeMinutes(
        day: yesterday,
        originalDay: null,
        now: today,
      ),
      isNull,
    );
  });

  test('编辑且日期没变、没手动选 → null（保留库里原值）', () {
    expect(
      resolveTimeMinutes(
        day: DateTime(2026, 11, 17, 9, 30),
        originalDay: DateTime(2026, 11, 17, 8, 0),
        now: today,
      ),
      isNull,
    );
  });

  test('clearTime：只有改了日期且新日期没时分才清', () {
    expect(
      shouldClearTime(
        day: yesterday,
        originalDay: DateTime(2026, 11, 17),
        resolvedMinutes: null,
      ),
      isTrue,
    );
    expect(
      shouldClearTime(
        day: yesterday,
        originalDay: DateTime(2026, 11, 17),
        resolvedMinutes: 9 * 60,
      ),
      isFalse,
    );
    expect(
      shouldClearTime(
        day: DateTime(2026, 11, 17),
        originalDay: DateTime(2026, 11, 17),
        resolvedMinutes: null,
      ),
      isFalse,
    );
  });

  test('chip 显示：编辑未改日期用库里原值，手动选优先', () {
    expect(
      displayTimeMinutes(
        day: DateTime(2026, 11, 17, 15, 42),
        originalDay: DateTime(2026, 11, 17, 8, 5),
        originalMinutes: 8 * 60 + 5,
        picked: null,
      ),
      8 * 60 + 5,
    );
    expect(
      displayTimeMinutes(
        day: DateTime(2026, 11, 17),
        originalDay: DateTime(2026, 11, 17, 8, 5),
        originalMinutes: 8 * 60 + 5,
        picked: 21 * 60 + 30,
      ),
      21 * 60 + 30,
    );
  });

  test('today 变量仅供可读性，不依赖真实时钟', () {
    expect(today.hour, 15);
  });
}
