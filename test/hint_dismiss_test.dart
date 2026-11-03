import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页三张提醒卡（预算 / 备份 / 已归档）的「点过就不再烦」。
///
/// 起因：这三张卡以前只能在**本次会话**里 ✕ 掉，冷启动原样弹回来。
/// 用户点了、也进了对应页面，下次开机还是一条，久了就当装饰看了。
/// 现在落盘成 token（`<kind>:<yyyy-MM>`）：预算/备份本月内不再出现，
/// 下个月重新提醒；归档卡按"被归档的那个月"记，看过就永远不再提。
void main() {
  group('hintToken', () {
    test('月份补零，跨月才是不同的 token', () {
      expect(AppSettings.hintToken('budget', DateTime(2026, 11)), 'budget:2026-11');
      expect(AppSettings.hintToken('budget', DateTime(2026, 3)), 'budget:2026-03');
      // 12 月 → 1 月必须变，否则"下个月重新提醒"就失效了
      expect(AppSettings.hintToken('budget', DateTime(2026, 12)),
          isNot(AppSettings.hintToken('budget', DateTime(2027, 1))));
    });

    test('同月同日不同日期 → 同一个 token（本月只提醒一次）', () {
      expect(AppSettings.hintToken('backup', DateTime(2026, 11, 1)),
          AppSettings.hintToken('backup', DateTime(2026, 11, 28)));
    });

    test('三种类型互不影响', () {
      final m = DateTime(2026, 11);
      expect(
        {
          AppSettings.hintToken('budget', m),
          AppSettings.hintToken('backup', m),
          AppSettings.hintToken('archive', m),
        }.length,
        3,
      );
    });
  });

  group('isHintDismissed', () {
    test('空字符串一个都不算', () {
      expect(const AppSettings().isHintDismissed('budget:2026-11'), isFalse);
    });

    test('逗号集合里精确匹配（不能前缀命中）', () {
      const s = AppSettings(hintsDismissed: 'budget:2026-11,backup:2026-11');
      expect(s.isHintDismissed('budget:2026-11'), isTrue);
      expect(s.isHintDismissed('backup:2026-11'), isTrue);
      // 同类型、不同月
      expect(s.isHintDismissed('budget:2026-12'), isFalse);
      // 有共同前缀的另一种类型
      expect(s.isHintDismissed('archive:2026-11'), isFalse);
    });

    test('copyWith 带得上 hintsDismissed', () {
      expect(
        const AppSettings().copyWith(hintsDismissed: 'x:1').hintsDismissed,
        'x:1',
      );
    });
  });

  group('dismissHint', () {
    test('写进 state 也落盘，且重复点不会写出两条', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(settingsProvider.notifier);
      // 等 _hydrate 拿到 prefs，否则 setString 会静默跳过
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await notifier.dismissHint('budget:2026-11');
      expect(container.read(settingsProvider).isHintDismissed('budget:2026-11'),
          isTrue);

      await notifier.dismissHint('budget:2026-11');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('home_hints_dismissed'), 'budget:2026-11');

      // 另一条追加在后面，前面的不丢
      await notifier.dismissHint('backup:2026-11');
      expect(prefs.getString('home_hints_dismissed'),
          'budget:2026-11,backup:2026-11');
    });

    test('冷启动读回来仍然有效（已点过的不再出现）', () async {
      SharedPreferences.setMockInitialValues(
          {'home_hints_dismissed': 'archive:2026-10'});
      final container = ProviderContainer();
      addTearDown(container.dispose);

      // 触发 build → 微任务补水
      container.read(settingsProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final s = container.read(settingsProvider);
      expect(s.isHintDismissed('archive:2026-10'), isTrue);
      expect(s.isHintDismissed('budget:2026-11'), isFalse);
    });

    test('空 token 不写脏数据', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      await notifier.dismissHint('');
      expect(container.read(settingsProvider).hintsDismissed, isEmpty);
    });
  });
}
