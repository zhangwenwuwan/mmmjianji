import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings.dart';
import 'automation_page.dart';
import 'appearance_page.dart';
import 'bill_import_page.dart';
import 'budget_page.dart';
import 'common.dart';
import 'data_manage_page.dart';
import 'goals_page.dart';
import 'insight_hub_page.dart';
import 'loans_page.dart';
import 'motion.dart';
import 'theme.dart';
import 'wishlist_page.dart';

/// 「我的 → 常用」里的一个入口。
class ProfileModuleDef {
  const ProfileModuleDef({
    required this.id,
    required this.label,
    required this.icon,
    required this.page,
    this.note,
  });

  final String id;
  final String label;
  final IconData icon;
  final Widget page;

  /// 设置页里显示的一行小字：这个入口是干什么的 / 为什么默认关着。
  final String? note;

  /// 新装 App 默认隐藏的入口。
  ///
  /// 2026-10-25 用户两次精简后的结论：**只默认显示 4 个**
  /// （数据管理 / 外观与显示 / 自动化 / 导入账单），其余六个都收进齿轮。
  ///
  /// 理由：财务洞察在统计页右上角、目标与债务在
  /// 资产页上方三宫格，这些在「常用」里都是重复入口；愿望清单和预算管理属于
  /// 低频功能，占着首屏反而把真正每天用的四个挤小了。
  /// 目录里仍然保留，用户在齿轮页可以随时打开。
  bool get defaultHidden => !const {
        'dataManage',
        'appearance',
        'automation',
        'billImport',
      }.contains(id);
}

/// 完整目录。顺序就是网格里的顺序。
final List<ProfileModuleDef> kProfileModules = [
  const ProfileModuleDef(
    id: 'dataManage',
    label: '数据管理',
    icon: Icons.storage_outlined,
    page: DataManagePage(),
    note: '备份 / 恢复 / 清空 / 月度总结归档',
  ),
  const ProfileModuleDef(
    id: 'insights',
    label: '财务洞察',
    icon: Icons.insights_outlined,
    page: InsightHubPage(),
    note: '统计页右上角也有同一个入口',
  ),
  const ProfileModuleDef(
    id: 'wishlist',
    label: '愿望清单',
    icon: Icons.shopping_bag_outlined,
    page: WishlistPage(),
    note: '想买的东西，存着比冲动下单便宜',
  ),
  const ProfileModuleDef(
    id: 'budget',
    label: '预算管理',
    icon: Icons.pie_chart_outline,
    page: BudgetPage(),
    note: '月预算、分类预算、结转规则',
  ),
  const ProfileModuleDef(
    id: 'appearance',
    label: '外观与显示',
    icon: Icons.palette_outlined,
    page: AppearancePage(),
    note: '配色 / 字体 / 默认账户',
  ),
  const ProfileModuleDef(
    id: 'automation',
    label: '自动化',
    icon: Icons.bolt_outlined,
    page: AutomationPage(),
    note: '周期记账、记账提醒',
  ),
  const ProfileModuleDef(
    id: 'loans',
    label: '借贷',
    icon: Icons.account_balance_wallet_outlined,
    page: LoansPage(),
    note: '资产页上方「债务」卡也是这里',
  ),
  const ProfileModuleDef(
    id: 'goals',
    label: '目标',
    icon: Icons.savings_outlined,
    page: GoalsPage(),
    note: '资产页上方「目标」卡也是这里',
  ),
  const ProfileModuleDef(
    id: 'billImport',
    label: '导入账单',
    icon: Icons.receipt_long_outlined,
    page: BillImportPage(),
    note: '从微信 / 支付宝账单 CSV 导入',
  ),
];

/// 新装 App 时「常用」默认显示哪些（= 目录去掉四个默认隐藏的）。
List<ProfileModuleDef> defaultProfileModules() =>
    [for (final m in kProfileModules) if (!m.defaultHidden) m];

/// 常用模块管理：勾选要显示的入口。
///
/// 为什么不做拖拽排序：一屏就 6~10 个入口，顺序的价值远低于「能不能关掉」。
/// 真需要排序的人，先把不用的关掉，剩下的自然就够少了。
class ProfileModulesPage extends ConsumerWidget {
  const ProfileModulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final hidden = settings.profileHiddenSet;

    return Scaffold(
      appBar: AppBar(
        title: const Text('常用模块'),
        actions: [
          TextButton(
            onPressed: () async {
              await ref.read(settingsProvider.notifier).resetProfileModules();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('已恢复默认（恢复后新增的入口会显示出来）')));
              }
            },
            child: const Text('恢复默认', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          Panel(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 14, color: Palette.inkFaint(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '关掉的入口不会消失，只是不在「我的」页显示。'
                    '全部关掉后，点「常用」右边的齿轮图标还能打开本页。',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: Palette.inkFaint(context)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < kProfileModules.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 16),
                  _row(context, ref, kProfileModules[i], hidden),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, WidgetRef ref, ProfileModuleDef m,
      Set<String> hidden) {
    final on = !hidden.contains(m.id);
    final brand = Palette.brand(context);
    return PressScale(
      scale: 0.99,
      onTap: () =>
          ref.read(settingsProvider.notifier).setProfileModuleHidden(m.id, on),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: on
                    ? brand.withValues(alpha: 0.10)
                    : Palette.hairline(context).withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(m.icon,
                  size: 18, color: on ? brand : Palette.inkFaint(context)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.label,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: on ? Palette.ink(context) : Palette.inkSoft(context),
                      )),
                  if (m.note != null) ...[
                    const SizedBox(height: 2),
                    Text(m.note!,
                        style: TextStyle(
                            fontSize: 10.5,
                            color: Palette.inkFaint(context))),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Switch(
              value: on,
              onChanged: (v) => ref
                  .read(settingsProvider.notifier)
                  .setProfileModuleHidden(m.id, !v),
            ),
          ],
        ),
      ),
    );
  }
}
