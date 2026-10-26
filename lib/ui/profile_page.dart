import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/version.dart';
import '../services/avatar_service.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'about_page.dart';
import 'common.dart';
import 'data_manage_page.dart';
import 'motion.dart';
import 'profile_modules.dart';
import 'reimburse_page.dart';
import 'report_page.dart';
import 'theme.dart';

/// 我的：头像卡 + 八宫格入口 + 数据管理列表（无会员 / 付费入口）。
class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(profileStatsProvider).valueOrNull;
    final days = stats?.earliest == null
        ? 0
        : DateTime.now().difference(stats!.earliest!).inDays + 1;
    final count = stats?.count ?? 0;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 88),
      children: [
        const _AvatarCard(),
        const SizedBox(height: 10),
        // 两个关键指标
        Row(
          children: [
            Expanded(
              child: _MetricCard(
                label: '坚持记账',
                value: '$days',
                unit: '天',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _MetricCard(
                label: '累计笔数',
                value: '$count',
                unit: '笔',
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // 「常用」右侧的齿轮：入口太多/太少都在这里调（见 profile_modules.dart）。
        // 为什么常驻：用户可能把全部入口都关掉，那时唯一的回去的路就是它。
        SectionLabel(
          '常用',
          trailing: IconButton(
            tooltip: '管理常用模块',
            visualDensity: VisualDensity.compact,
            onPressed: () => Navigator.of(context)
                .push(AppPageRoute(page: const ProfileModulesPage())),
            icon: Icon(Icons.tune, size: 17, color: Palette.inkFaint(context)),
          ),
        ),
        _grid(context, ref.watch(settingsProvider).profileHiddenSet),
        const SizedBox(height: 12),
        SectionLabel('数据管理'),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              _nav(context, Icons.assignment_turned_in_outlined, '报销',
                  '待报销 / 已报销', const ReimbursePage(),
                  badge: ref.watch(pendingReimburseCountProvider).valueOrNull),
              const Divider(height: 1, indent: 16),
              _nav(context, Icons.backup_outlined, '备份与恢复',
                  '自动备份 / 恢复 / 清空', const DataManagePage()),
              const Divider(height: 1, indent: 16),
              _nav(context, Icons.auto_graph_rounded, '年度报告',
                  '全年汇总 + 分享海报', const ReportPage()),
              const Divider(height: 1, indent: 16),
              _nav(context, Icons.info_outline, '关于简记',
                  '本地优先，没有账号、没有服务器', const AboutPage()),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text('简记 $appVersion · 数据只存在这台手机上',
              style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
        ),
      ],
    );
  }

  /// 常用入口网格。清单和显隐都在 `profile_modules.dart`：
  /// 默认只显示 数据管理 / 外观与显示 / 自动化 / 导入账单 四项；
  /// 财务洞察在统计页右上角、储蓄目标与借贷在资产页下方，
  /// 都在别处有入口 —— 想留可以在齿轮里打开。
  Widget _grid(BuildContext context, Set<String> hidden) {
    final items = [
      for (final m in kProfileModules)
        if (!hidden.contains(m.id)) m,
    ];
    return Panel(
      padding: const EdgeInsets.all(10),
      child: GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 8,
        childAspectRatio: 1.04,
        children: [
          for (final it in items)
            _GridItem(icon: it.icon, label: it.label, page: it.page),
        ],
      ),
    );
  }

  Widget _nav(BuildContext context, IconData icon, String title,
      String subtitle, Widget page,
      {int? badge}) {
    return PressScale(
      scale: 0.98,
      onTap: () => Navigator.of(context).push(AppPageRoute(page: page)),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: Motion.d(context, Motion.small),
              curve: XCurve.easeOut,
              alignment: Alignment.centerRight,
              child: badge != null && badge > 0
                  ? Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      constraints:
                          const BoxConstraints(minWidth: 20, minHeight: 18),
                      decoration: BoxDecoration(
                        color: Palette.expense.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: Palette.expense.withValues(alpha: 0.18),
                        ),
                      ),
                      // ⚠️ 这里不能用 Container 的 alignment：
                      // alignment 会包一层 Align，而 Align 在「高度约束有界、
                      // heightFactor 为 null」时会吃掉父级全部可用高度 ——
                      // 于是胶囊在 ListTile.trailing 里被纵向拉满（宽度却正常，
                      // 因为 Row 给的是无界宽度）。要用 Center + factor 1 让它
                      // 只包住文字本身，再由 minHeight 撑到 18。
                      child: Center(
                        widthFactor: 1,
                        heightFactor: 1,
                        child: Text(
                          badge > 99 ? '99+' : '$badge',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                            color: Palette.expense,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    );
  }
}

/// 头像卡：头像（可点，从相册换图 / 改昵称）+ 一句本地存储的强调。
///
/// 2026-10-26 用户要求「我的页面可以让用户自定义更换头像」。
/// 点整块头像弹层，三个动作：相册选图 / 改昵称 / 恢复默认。
/// 昵称是顺带做的：头像换成了自己的照片，名字还叫「记账人」会很割裂，
/// 而且只多一个 prefs 字段，成本几乎为零。
class _AvatarCard extends ConsumerWidget {
  const _AvatarCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final brand = Palette.brand(context);
    final avatar = settings.avatarPath;

    return Panel(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          PressScale(
            scale: 0.94,
            onTap: () => _openSheet(context, ref),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _avatarBody(context, brand, avatar),
                // 右下角相机角标：不给提示的话，没人会想到这块能点。
                Positioned(
                  right: -1,
                  bottom: -1,
                  child: Container(
                    width: 19,
                    height: 19,
                    decoration: BoxDecoration(
                      color: brand,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: Palette.card(context), width: 1.6),
                    ),
                    child: const Icon(Icons.photo_camera,
                        size: 10.5, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '你好，${settings.displayName}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: Palette.ink(context)),
                ),
                const SizedBox(height: 4),
                Text('数据只存在这台手机上，没有账号、没有服务器',
                    style: TextStyle(
                        fontSize: 11.5,
                        height: 1.4,
                        color: Palette.inkSoft(context))),
              ],
            ),
          ),
          Icon(Icons.chevron_right,
              size: 18, color: Palette.inkFaint(context)),
        ],
      ),
    );
  }

  Widget _avatarBody(BuildContext context, Color brand, String path) {
    final fallback = Center(
      child: Icon(Icons.account_balance_wallet_outlined,
          size: 24, color: brand),
    );
    return Container(
      width: 56,
      height: 56,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: brand.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      // 头像文件可能被清理软件删掉 / 换机后不存在：一律静默退回默认图标。
      child: path.isEmpty
          ? fallback
          : Image.file(
              File(path),
              fit: BoxFit.cover,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, __, ___) => fallback,
            ),
    );
  }

  Future<void> _openSheet(BuildContext context, WidgetRef ref) async {
    final hasAvatar = ref.read(settingsProvider).avatarPath.isNotEmpty;
    final action = await showAppSheet<String>(
      context: context,
      title: '头像与昵称',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _tile(ctx, Icons.photo_library_outlined, '从相册选择头像',
              hasAvatar ? '换一张图片' : '用你自己的照片当头像', 'pick'),
          _tile(ctx, Icons.badge_outlined, '修改昵称',
              ref.read(settingsProvider).displayName, 'name'),
          if (hasAvatar)
            _tile(ctx, Icons.restart_alt, '恢复默认头像', '换回钱包图标', 'reset'),
          const SizedBox(height: 10),
        ],
      ),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'pick':
        final old = ref.read(settingsProvider).avatarPath;
        final path = await AvatarService.pickFromGallery(oldPath: old);
        // 用户在相册里点了取消：什么都不做，也不要弹「失败」。
        if (path == null || !context.mounted) return;
        await ref.read(settingsProvider.notifier).setAvatar(path);
        if (context.mounted) _toast(context, '头像已更新');
      case 'reset':
        await ref.read(settingsProvider.notifier).clearAvatar();
        await AvatarService.clear();
        if (context.mounted) _toast(context, '已恢复默认头像');
      case 'name':
        await _editNickname(context, ref);
    }
  }

  Widget _tile(BuildContext context, IconData icon, String title,
      String subtitle, String value) {
    return ListTile(
      leading: Icon(icon, size: 20),
      title: Text(title, style: const TextStyle(fontSize: 14.5)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
      onTap: () => Navigator.pop(context, value),
    );
  }

  Future<void> _editNickname(BuildContext context, WidgetRef ref) async {
    final ctrl =
        TextEditingController(text: ref.read(settingsProvider).nickname);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改昵称'),
        content: AppTextField(
          label: '昵称',
          controller: ctrl,
          hint: '记账人',
          autofocus: true,
          maxLength: 12,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(settingsProvider.notifier).setNickname(ctrl.text);
    }
    // 直接 dispose 会撞上关闭动画（AlertDialog 还在树上用这个 controller），
    // 推迟一拍更安全；控制器本身很小，不存在泄漏风险。
    Future.delayed(const Duration(milliseconds: 400), ctrl.dispose);
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }
}

/// 指标卡（坚持天数 / 累计笔数）。
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.unit,
  });

  final String label;
  final String value;
  final String unit;

  @override
  Widget build(BuildContext context) {
    return Panel(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(fontSize: 11.5, color: Palette.inkFaint(context))),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: Palette.brand(context),
                      fontFeatures: const [FontFeature.tabularFigures()])),
              const SizedBox(width: 3),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(unit,
                    style: TextStyle(
                        fontSize: 11, color: Palette.inkSoft(context))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 八宫格里的单个入口。
class _GridItem extends StatelessWidget {
  const _GridItem({
    required this.icon,
    required this.label,
    required this.page,
  });

  final IconData icon;
  final String label;
  final Widget page;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.95,
      onTap: () => Navigator.of(context).push(AppPageRoute(page: page)),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Palette.brand(context).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 20, color: Palette.brand(context)),
          ),
          const SizedBox(height: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w500,
                  color: Palette.ink(context))),
        ],
      ),
    );
  }
}
