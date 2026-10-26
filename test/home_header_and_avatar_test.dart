import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/home_modules.dart';
import 'package:jianji/state/settings.dart';

/// 2026-10-26 的两处改动：
/// 1. 首页顶栏删掉月份条 / 收支三段，「本月概览」固定在最前（不可拖、不可关）；
/// 2. 「我的」页头像可换、昵称可改。
///
/// 这里只锁**数据层**的契约 —— 版面本身靠真机截图验收。
void main() {
  group('本月概览固定显示', () {
    test('hero 是固定项：不能隐藏，也不该出现在可拖列表里', () {
      expect(HomeModule.hero.fixed, isTrue);
      expect(HomeModule.hero.canHide, isFalse);
    });

    test('「记一笔」仍然不可隐藏（老的约束别被 fixed 覆盖掉）', () {
      expect(HomeModule.addEntry.canHide, isFalse);
      expect(HomeModule.safeToSpend.canHide, isTrue);
    });

    test('老存档里没有 hero 也能补回来（否则升级后概览消失）', () {
      final order = normalizeOrder('addEntry,safeToSpend');
      expect(order, contains(HomeModule.hero));
      // 已知 id 的顺序不能被这次改动打乱
      expect(order.indexOf(HomeModule.addEntry),
          lessThan(order.indexOf(HomeModule.safeToSpend)));
    });

    test('hero 即使被写进隐藏集合也不生效（parseHidden 会丢掉不可隐藏项）', () {
      expect(parseHidden('hero,lastMonth'), {HomeModule.lastMonth});
    });
  });

  group('头像与昵称', () {
    test('昵称默认「记账人」，空白也当没填', () {
      expect(const AppSettings().displayName, '记账人');
      expect(const AppSettings(nickname: '   ').displayName, '记账人');
      expect(const AppSettings(nickname: ' 老王 ').displayName, '老王');
    });

    test('copyWith 能带出头像路径和昵称，且不影响其他字段', () {
      final s = const AppSettings()
          .copyWith(avatarPath: '/data/user/0/x/files/avatar/a.jpg', nickname: '老王');
      expect(s.avatarPath, '/data/user/0/x/files/avatar/a.jpg');
      expect(s.nickname, '老王');
      expect(s.symbol, '¥');
      expect(s.hideAmounts, isFalse);
    });

    test('恢复默认头像 = 空串（渲染层靠它回退到钱包图标）', () {
      final s = const AppSettings(avatarPath: '/a.jpg').copyWith(avatarPath: '');
      expect(s.avatarPath, isEmpty);
    });
  });
}
