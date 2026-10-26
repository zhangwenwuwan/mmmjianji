import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/state/settings.dart';
import 'package:jianji/ui/profile_modules.dart';

/// 「我的 → 常用」模块的默认显隐。
///
/// 2026-10-25 用户两次精简：**默认只显示 4 个**（数据管理 / 外观与显示 /
/// 自动化 / 导入账单），其余五个收进齿轮页。目录必须留全集——
/// 「默认收起」不等于「删掉」。
void main() {
  test('新装 App：常用默认只显示这 4 个', () {
    final shown = defaultProfileModules();
    expect(shown.length, 4);
    expect(shown.map((m) => m.id), [
      'dataManage',
      'appearance',
      'automation',
      'billImport',
    ]);
  });

  test('目录是全集：默认收起的五个仍然在，用户能打开', () {
    final ids = kProfileModules.map((m) => m.id).toSet();
    for (final id in [
      'insights',
      'goals',
      'loans',
      'wishlist',
      'budget',
    ]) {
      expect(ids, contains(id), reason: '$id 应该还在目录里');
    }
    // homeModules 入口已按用户要求撤下（待重做），不再出现在目录里
    expect(ids, isNot(contains('homeModules')));
    expect(kProfileModules.length, 9);
  });

  test('id 唯一（否则开关会互相串）', () {
    final ids = kProfileModules.map((m) => m.id).toList();
    expect(ids.toSet().length, ids.length);
  });

  test('默认隐藏集合与 catalog 的 defaultHidden 一致', () {
    final csv = defaultProfileHiddenCsv.split(',').toSet();
    final def = kProfileModules.where((m) => m.defaultHidden).map((m) => m.id).toSet();
    expect(csv, def);
  });

  test('AppSettings 从没设置过 → 用默认隐藏集合', () {
    const s = AppSettings();
    expect(s.profileHiddenSet, {...defaultProfileHiddenCsv.split(',')});
    // 用户显式存了空串 → 全部显示（不能和"从没设置过"混为一谈）
    const all = AppSettings(profileHidden: '');
    expect(all.profileHiddenSet, isEmpty);
    // 未知 id 原样留着也无害：渲染时按目录过滤，不会显示不存在的入口
    const some = AppSettings(profileHidden: 'goals,unknown');
    expect(some.profileHiddenSet, {'goals', 'unknown'});
  });
}
