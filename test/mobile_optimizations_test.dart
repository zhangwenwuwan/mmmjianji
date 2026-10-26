import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/rules.dart';
import 'package:jianji/services/icon_service.dart';
import 'package:jianji/core/lock_rules.dart';

/// 1.4.0 三项优化的纯逻辑测试：
/// - 日历隔天复位（方案 B）
/// - 滚轮选择器的「日」夹取
/// - 应用锁宽限期判定
/// - 自定义图标的前缀约定
void main() {
  group('滚轮选择器的日夹取', () {
    test('1 月 31 日切到 4 月 → 30', () {
      expect(clampDayOfMonth(31, 2026, 4), 30);
    });

    test('2 月 29 日切到平年 → 28', () {
      expect(clampDayOfMonth(29, 2026, 2), 28);
      expect(clampDayOfMonth(29, 2024, 2), 29); // 闰年
    });

    test('合法日期原样返回；0 夹到 1', () {
      expect(clampDayOfMonth(15, 2026, 10), 15);
      expect(clampDayOfMonth(0, 2026, 10), 1);
    });
  });

  group('应用锁宽限期', () {
    final t0 = DateTime(2026, 10, 25, 12, 0, 0);

    test('刚好等于宽限期 → 不锁（边界含等于）', () {
      expect(
        shouldLockAfter(
          pausedAt: t0,
          now: t0.add(const Duration(seconds: 30)),
          grace: const Duration(seconds: 30),
        ),
        isFalse,
      );
    });

    test('超过宽限期 → 锁', () {
      expect(
        shouldLockAfter(
          pausedAt: t0,
          now: t0.add(const Duration(seconds: 31)),
          grace: const Duration(seconds: 30),
        ),
        isTrue,
      );
    });

    test('宽限期 0（每次切回都锁）→ 只要离开过就锁', () {
      expect(
        shouldLockAfter(
          pausedAt: t0,
          now: t0.add(const Duration(milliseconds: 1)),
          grace: Duration.zero,
        ),
        isTrue,
      );
    });

    test('系统时钟被往回拨 → 宁可多锁', () {
      expect(
        shouldLockAfter(
          pausedAt: t0,
          now: t0.subtract(const Duration(minutes: 5)),
          grace: const Duration(seconds: 30),
        ),
        isTrue,
      );
    });
  });

  group('自定义图标前缀约定', () {
    test('img: 前缀才是图片，emoji 不是', () {
      expect(IconService.isImage('img:icon_123.jpg'), isTrue);
      expect(IconService.isImage('🍜'), isFalse);
      expect(IconService.isImage(''), isFalse);
    });
  });
}
