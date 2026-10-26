import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/holiday_calendar.dart';

/// 官方节假日表的回归测试。
///
/// 重点不是"记住日期"，而是锁住三件事：
/// 1. 调休上班日必须能被查出来（算法永远猜不到）；
/// 2. 未录入年份必须安全回退（返回 null，不抛错）；
/// 3. 连续假期区间不能出现空洞（首尾各查一次 + 天数对得上）。
void main() {
  group('2026 元旦', () {
    test('1/1~1/3 放假，1/4 调休上班', () {
      for (final d in [1, 2, 3]) {
        final h = holidayOf(DateTime(2026, 1, d));
        expect(h, isNotNull, reason: '2026-01-$d 应该是假期');
        expect(h!.kind, HolidayKind.rest);
        expect(h.label, '元旦');
      }
      final work = holidayOf(DateTime(2026, 1, 4));
      expect(work, isNotNull);
      expect(work!.kind, HolidayKind.work, reason: '1/4 周日要上班');
    });
  });

  group('2026 春节', () {
    test('2/15~2/23 连续 9 天假', () {
      var restDays = 0;
      for (var d = 15; d <= 23; d++) {
        final h = holidayOf(DateTime(2026, 2, d));
        expect(h, isNotNull, reason: '2026-02-$d 应在春节假期内');
        expect(h!.kind, HolidayKind.rest);
        restDays++;
      }
      expect(restDays, 9);
    });

    test('2/14 与 2/28 都是调休上班', () {
      expect(holidayOf(DateTime(2026, 2, 14))!.kind, HolidayKind.work);
      expect(holidayOf(DateTime(2026, 2, 28))!.kind, HolidayKind.work);
    });
  });

  group('2026 其余假期', () {
    test('清明 4/4~4/6', () {
      for (var d = 4; d <= 6; d++) {
        expect(holidayOf(DateTime(2026, 4, d))!.kind, HolidayKind.rest);
      }
    });

    test('劳动节 5/1~5/5，5/9 补班', () {
      for (var d = 1; d <= 5; d++) {
        expect(holidayOf(DateTime(2026, 5, d))!.kind, HolidayKind.rest);
      }
      expect(holidayOf(DateTime(2026, 5, 9))!.kind, HolidayKind.work);
    });

    test('端午 6/19~6/21', () {
      for (var d = 19; d <= 21; d++) {
        expect(holidayOf(DateTime(2026, 6, d))!.kind, HolidayKind.rest);
      }
    });

    test('中秋 9/25~9/27', () {
      for (var d = 25; d <= 27; d++) {
        expect(holidayOf(DateTime(2026, 9, d))!.kind, HolidayKind.rest);
      }
    });

    test('国庆 10/1~10/7，9/20 与 10/10 补班', () {
      for (var d = 1; d <= 7; d++) {
        final h = holidayOf(DateTime(2026, 10, d));
        expect(h, isNotNull, reason: '2026-10-$d 应在国庆假期内');
        expect(h!.kind, HolidayKind.rest);
      }
      expect(holidayOf(DateTime(2026, 9, 20))!.kind, HolidayKind.work);
      expect(holidayOf(DateTime(2026, 10, 10))!.kind, HolidayKind.work);
    });
  });

  group('2025 关键差异（法定假日 +2 天后）', () {
    test('元旦只放 1 天，不调休', () {
      expect(holidayOf(DateTime(2025, 1, 1))!.kind, HolidayKind.rest);
      expect(holidayOf(DateTime(2025, 1, 2)), isNull);
    });

    test('春节 1/28(除夕)~2/4 共 8 天，1/26 与 2/8 补班', () {
      var rest = 0;
      for (var d = 28; d <= 31; d++) {
        expect(holidayOf(DateTime(2025, 1, d))!.kind, HolidayKind.rest);
        rest++;
      }
      for (var d = 1; d <= 4; d++) {
        expect(holidayOf(DateTime(2025, 2, d))!.kind, HolidayKind.rest);
        rest++;
      }
      expect(rest, 8);
      expect(holidayOf(DateTime(2025, 1, 26))!.kind, HolidayKind.work);
      expect(holidayOf(DateTime(2025, 2, 8))!.kind, HolidayKind.work);
    });

    test('国庆与中秋合并：10/1~10/8 共 8 天，9/28 与 10/11 补班', () {
      for (var d = 1; d <= 8; d++) {
        expect(holidayOf(DateTime(2025, 10, d))!.kind, HolidayKind.rest,
            reason: '2025-10-$d 应在合并假期内');
      }
      expect(holidayOf(DateTime(2025, 9, 28))!.kind, HolidayKind.work);
      expect(holidayOf(DateTime(2025, 10, 11))!.kind, HolidayKind.work);
    });
  });

  group('边界与回退', () {
    test('普通日子返回 null', () {
      expect(holidayOf(DateTime(2026, 3, 15)), isNull);
      expect(holidayOf(DateTime(2026, 11, 11)), isNull);
    });

    test('未录入年份安全回退，不抛错', () {
      // 2027 官方还没发文（国办每年 11 月才发次年安排），不该编造
      expect(hasHolidayData(2027), isFalse);
      expect(holidayOf(DateTime(2027, 2, 16)), isNull);
      expect(hasHolidayData(2024), isFalse);
      expect(holidayOf(DateTime(2024, 10, 1)), isNull);
      // 极端日期也不该炸
      expect(holidayOf(DateTime(1900, 1, 1)), isNull);
      expect(holidayOf(DateTime(2200, 12, 31)), isNull);
    });

    test('跨年边界：12/31 无安排，次年 1/1 有安排', () {
      expect(holidayOf(DateTime(2024, 12, 31)), isNull);
      expect(holidayOf(DateTime(2025, 1, 1))!.kind, HolidayKind.rest);
      expect(holidayOf(DateTime(2025, 12, 31)), isNull);
      expect(holidayOf(DateTime(2026, 1, 1))!.kind, HolidayKind.rest);
    });

    test('2025 与 2026 都有数据', () {
      expect(hasHolidayData(2025), isTrue);
      expect(hasHolidayData(2026), isTrue);
    });

    test('连续假期天数与官方口径一致', () {
      int daysOf(int year, int month) {
        final last = DateTime(year, month + 1, 0).day;
        var n = 0;
        for (var d = 1; d <= last; d++) {
          if (holidayOf(DateTime(year, month, d))?.isRest ?? false) n++;
        }
        return n;
      }

      // 元旦 3、春节 9、清明 3、劳动 5、端午 3、中秋 3、国庆 7
      expect(daysOf(2026, 1), 3);
      expect(daysOf(2026, 2), 9);
      expect(daysOf(2026, 4), 3);
      expect(daysOf(2026, 5), 5);
      expect(daysOf(2026, 6), 3);
      expect(daysOf(2026, 9), 3);
      expect(daysOf(2026, 10), 7);
    });
  });
}
