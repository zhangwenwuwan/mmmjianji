import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/state/settings.dart';

/// 首页「备份提醒」的判据。
///
/// 这块看着简单，真正会出事的是**边界**：
/// 从没备份过（0）和「刚刚备份过（今天）」必须区分清楚 ——
/// 前者要提醒，后者不能提醒；用 0 表示"没备份过"时，`-0 天` 的写法
/// 会让新用户看到「距上次备份已 -1 天」这种鬼文案。
void main() {
  group('daysSinceBackup', () {
    test('从没备份过 → null（提示里走「还没导出过备份」）', () {
      expect(const AppSettings().daysSinceBackup, isNull);
    });

    test('刚刚备份过 → 0 天（低于阈值，不出提示条）', () {
      final s =
          AppSettings(lastBackupAt: DateTime.now().millisecondsSinceEpoch);
      expect(s.daysSinceBackup, 0);
    });

    test('10 天前备份 → 10（超过 7 天阈值）', () {
      final s = AppSettings(
        lastBackupAt: DateTime.now()
            .subtract(const Duration(days: 10))
            .millisecondsSinceEpoch,
      );
      expect(s.daysSinceBackup, 10);
    });

    test('差几分钟满一天不是负数也不是 1 天以上', () {
      final s = AppSettings(
        lastBackupAt: DateTime.now()
            .subtract(const Duration(hours: 23))
            .millisecondsSinceEpoch,
      );
      expect(s.daysSinceBackup, 0);
    });

    test('时间戳在将来（改过系统时间）不会算成负数', () {
      final s = AppSettings(
        lastBackupAt:
            DateTime.now().add(const Duration(days: 3)).millisecondsSinceEpoch,
      );
      expect(s.daysSinceBackup, 0);
    });

    test('copyWith 带得上 lastBackupAt', () {
      expect(const AppSettings().copyWith(lastBackupAt: 12345).lastBackupAt,
          12345);
    });
  });
}
