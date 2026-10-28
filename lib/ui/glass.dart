import 'dart:ui';

import 'package:flutter/material.dart';

import 'theme.dart';

/// 毛玻璃条 / 面板。
///
/// **只用在「下面有内容滚动」的地方**：首页顶栏、底部导航、底部弹窗。
/// 否则模糊的是一层纯色，等于白花钱。
///
/// 为什么这么克制：`BackdropFilter` 每实例一次离屏渲染 + 模糊采样，
/// 是 Flutter 里最贵的常规效果之一。这个项目为了流畅度做过不少让步
/// （关 Impeller、RepaintBoundary 包转场、IndexedStack 换 Offstage），
/// 大面积铺模糊会把这些努力一起还回去 —— 骁龙 710 / Adreno 615 上
/// 两个全宽模糊条就够掉帧了。
///
/// 列表卡片要「玻璃感」用半透明 + 高光边模拟（见 [Panel] 的 tint 参数），
/// 那种没有运行时成本。
///
/// ⚠️ 必须被 ClipRect / ClipRRect 限制区域：`BackdropFilter` 会模糊它
/// 覆盖到的**整块背景**，不裁剪的话整屏都会被糊。
class Glass extends StatelessWidget {
  const Glass({
    super.key,
    required this.child,
    this.blur = 16,
    this.tint,
    this.borderRadius,
    this.border,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;

  /// 模糊半径。16 已经能糊掉正文、但仍看得出"有东西在动"。
  final double blur;

  /// 覆盖色。默认 [Palette.glass]（半透明白 / 深色下是半透明墨绿）。
  final Color? tint;

  /// 非空时会裁剪成圆角（底部弹窗用顶部圆角）。
  final BorderRadius? borderRadius;

  final BoxBorder? border;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: tint ?? Palette.glass(context),
        borderRadius: borderRadius,
        border: border,
      ),
      child: child,
    );

    final blurred = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
      child: content,
    );

    // ⚠️⚠️ 圆角裁剪必须包在 BackdropFilter **外面**，顺序不能反。
    //
    // 反了（ClipRRect 在里、ClipRect 在外）时的表现是：模糊作用在**整块矩形**上，
    // 圆角只裁到了那层 0.6 左右的 tint —— 于是"胶囊"周围露出一圈**带直角的
    // 磨砂方块**，四角糊得很明显，看着就是"没裁干净"。
    // 原因：BackdropFilter 的模糊范围由它**外层**的 clip 决定，内层的 clip 只
    // 影响它自己的 child，影响不到已经采样的背景。
    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: blurred);
    }
    return ClipRect(child: blurred);
  }
}
