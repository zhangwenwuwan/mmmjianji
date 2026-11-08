import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass.dart';
import 'liquid_surface.dart';
import 'theme.dart';

/// 四个 tab 共用的顶部条：玻璃底 + 48 高 + 17px 标题 + 右侧动作。
///
/// 2026-10-28 之前的状况是两套顶栏：
/// - 首页：自绘 `SliverPersistentHeader`，**玻璃模糊**、48 高、左侧是账本 chip、没有标题；
/// - 统计 / 资产 / 我的：Material `AppBar`，**纸色不透明**、52 高、有 17px 标题。
///
/// 切 tab 时高度差 4px、材质一变（磨砂→实体）、"有没有标题"也在变，
/// 是四个主页面里最明显的割裂。现在统一成这一套：
/// **48 高 + 玻璃 + 左标题 + 右动作**，首页那套自绘顶栏也是 48，两边对齐。
///
/// ⚠️ 这是**浮在内容上方**的（Shell 里用 Stack 叠着），页面自己的滚动区
/// 必须留出 [heightOf] 的顶部内边距，否则第一张卡会被压在条底下。
class TabHeader extends StatelessWidget {
  const TabHeader({
    super.key,
    required this.title,
    this.actions = const [],
  });

  final String title;
  final List<Widget> actions;

  /// 条高（不含状态栏）。首页自绘顶栏的 `_barHeight` 也是 48，别单方面改。
  static const double barHeight = 48;

  /// 整条（含状态栏）占的高度 —— 页面滚动区的顶部内边距要用它。
  static double heightOf(BuildContext context) =>
      barHeight + MediaQuery.paddingOf(context).top;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    // 标题字形跟着主题走：用户选「标题用美好体」时这里也要换，否则
    // 页面标题和弹窗标题是两种字。
    final titleFont = Theme.of(context).appBarTheme.titleTextStyle?.fontFamily;
    // 少了 Material AppBar 之后，状态栏图标明暗没人管了 —— 亮色主题下
    // 系统默认可能还是白图标，白底白字看不见。这里显式声明。
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Palette.isDark(context)
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: SizedBox(
      height: barHeight + top,
      child: Glass(
        blur: LiquidTokens.blurBar,
        child: Column(
          children: [
            SizedBox(height: top),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          fontFamily: titleFont,
                          color: Palette.ink(context),
                        ),
                      ),
                    ),
                    ...actions,
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
