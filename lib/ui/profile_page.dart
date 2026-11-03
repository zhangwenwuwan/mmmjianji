import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/version.dart';
import '../services/avatar_service.dart';
import '../services/update_service.dart';
import 'update_dialog.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'about_page.dart';
import 'common.dart';
import 'data_manage_page.dart';
import 'month_notes_page.dart';
import 'motion.dart';
import 'profile_modules.dart';
import 'reimburse_page.dart';
import 'report_page.dart';
import 'tab_header.dart';
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
      // 顶栏浮在内容上，顶部留出它的高度
      padding: EdgeInsets.fromLTRB(12, TabHeader.heightOf(context) + 6, 12, 88),
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
            icon: Icon(Icons.tune, size: 18, color: Palette.inkFaint(context)),
          ),
        ),
        _grid(context, ref.watch(settingsProvider).profileHiddenSet),
        const SizedBox(height: 12),
        // 这一组分两类东西：高频功能入口（报销 / 年度报告 / 月度总结）
        // 和"设置类"（检查更新 / 关于）。原来标题叫「数据管理」，但下面
        // 大半不是数据管理，而点「备份与恢复」进去的那页才叫「数据管理」——
        // 两个同名不同义，用户找不着东西。改成「更多功能」。
        SectionLabel('更多功能'),
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
              // 2026-11-03：从「数据管理 → 月度总结」提到一级。
              // 原来要 我的 → 数据管理 → 月度总结 三层才够得着，
              // 用户翻月后就再也找不到写过的总结。
              _nav(context, Icons.notes_outlined, '月度总结',
                  '每月总结归档，可回看 / 复制', const MonthNotesPage()),
              const Divider(height: 1, indent: 16),
              const _CheckUpdateTile(),
              const Divider(height: 1, indent: 16),
              _nav(context, Icons.info_outline, '关于简记',
                  '本地优先，没有账号、没有服务器', const AboutPage()),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text('简记 $appVersion · 数据只存在这台手机上',
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
        ),
      ],
    );
  }

  /// 常用入口网格。清单和显隐都在 `profile_modules.dart`：
  /// 默认只显示 数据管理 / 外观与显示 / 自动化 / 导入账单 四项；
  /// 财务洞察在统计页右上角、目标与债务在资产页上方三宫格，
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
        // ⚠️ 必须显式写 EdgeInsets.zero。
        // ScrollView 的 padding 为 null 时，会自动把 **MediaQuery.padding** 当成
        // 自己的内边距。而 Shell 的 Scaffold 开了 extendBody（底栏浮在内容上），
        // 它给 body 的 MediaQuery.padding.bottom 正好等于整条底栏的高度（62）——
        // 于是这个网格底下凭空多出 62px 空白，看着像"网格下面漏了一块"。
        // 4 个入口只占一行，多出来的那一条就是纯白面板。
        padding: EdgeInsets.zero,
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
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
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
            const Icon(Icons.chevron_right, size: 18),
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
                        size: 14, color: Colors.white),
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
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Palette.ink(context)),
                ),
                const SizedBox(height: 4),
                Text('数据只存在这台手机上，没有账号、没有服务器',
                    style: TextStyle(
                        fontSize: 12,
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
        final out = await AvatarService.pickFromGallery(oldPath: old);
        if (!context.mounted) return;
        // 三种结果分开说：取消不弹，权限被拒要指路，其它失败要说清
        switch (out.result) {
          case PickResult.ok:
            await ref.read(settingsProvider.notifier).setAvatar(out.path!);
            if (context.mounted) _toast(context, '头像已更新');
          case PickResult.cancelled:
            break;
          case PickResult.denied:
            _toast(context, '相册权限被拒绝了，去系统设置里打开');
          case PickResult.error:
            _toast(context, '读图失败，详情见日志中心');
        }
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
      leading: Icon(icon, size: 18),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
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
    ScaffoldMessenger.of(context).toast(msg);
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
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
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
                        fontSize: 12, color: Palette.inkSoft(context))),
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
            child: Icon(icon, size: 18, color: Palette.brand(context)),
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

/// 「检查更新」行：**只查有没有新版，不下载、不安装**。
///
/// 为什么不做成启动时自动检查：这是全 App 唯一一处联网（其余数据都只在本机），
/// 静默请求会让「本地优先、没有服务器」这句话变得不诚实。
/// 放在设置里、由用户点，行为可控，出问题也只影响这一行。
class _CheckUpdateTile extends StatefulWidget {
  const _CheckUpdateTile();

  @override
  State<_CheckUpdateTile> createState() => _CheckUpdateTileState();
}

class _CheckUpdateTileState extends State<_CheckUpdateTile> {
  bool _checking = false;

  /// 上次检查的结论，贴在副标题上（不用每次都弹 toast 才知道结果）
  String? _hint;

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _hint = null;
    });
    final r = await UpdateService.check();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _hint = switch (r.status) {
        UpdateStatus.available => '发现新版本 ${r.info!.versionName}',
        UpdateStatus.latest => '已是最新版本',
        UpdateStatus.notConfigured => null,
        UpdateStatus.failed => '上次检查失败',
      };
    });
    if (!mounted) return;
    switch (r.status) {
      case UpdateStatus.available:
        await showUpdateDialog(context, r.info!);
      case UpdateStatus.latest:
        ScaffoldMessenger.of(context).toast('已是最新版本 $appVersion');
      case UpdateStatus.notConfigured:
        ScaffoldMessenger.of(context).toast('当前版本还没接入更新服务');
      case UpdateStatus.failed:
        ScaffoldMessenger.of(context).toast('检查失败：${r.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.98,
      onTap: _checking ? null : _check,
      child: ListTile(
        leading: const Icon(Icons.system_update_alt),
        title: const Text('检查更新'),
        subtitle: Text(
          _hint ?? '当前 $appVersion（$appBuild）',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: _checking
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Palette.brand(context)),
              )
            : const Icon(Icons.chevron_right, size: 18),
      ),
    );
  }
}
