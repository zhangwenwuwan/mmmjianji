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
    this.highlight = false,
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

  /// **玻璃厚度高光**（2026-10-28 加）。
  ///
  /// CSS 里这一步是 `box-shadow: inset 1px 1px #fff8` —— 一条 1px 的内发光，
  /// 模拟玻璃边缘被光打亮。**Flutter 的 BoxShadow 没有 inset 参数**
  /// （issue #96264 挂了很多年），所以换成等效做法：
  /// **从左上到右下的一层白→透明→微暗渐变**，画在 tint 同一层（不是盖在内容上）。
  ///
  /// 效果比 1px 线更接近真实玻璃：左上受光最亮、右下略沉，整块有了"厚度"。
  /// 默认关闭 —— 只在需要强调"这是一块玻璃"的地方（底栏胶囊）开，
  /// 别的地方开了会让半透明变得更花。
  final bool highlight;

  /// 玻璃高光的三个色标：左上「厚」、中间本色、右下「薄」。
  ///
  /// ⚠️ **必须同时动 alpha，不能只提亮颜色**。
  /// 底栏的 tint 已经接近纯白（`Color.lerp(white, brand, 0.07)` ≈ 93% 白），
  /// 在 1.0 附近做 `c + (1-c)*k` 提亮量只有 0.06 左右 —— 肉眼完全看不出来，
  /// 等于这一步白做。真实玻璃的"边缘发亮"本来就是**叠加了更多反射光**，
  /// 所以这里把 alpha 从 0.20 抬到 0.34，再用亮度微调收边。
  static List<Color> _highlightColors(Color base) => [
        Color.from(
          alpha: (base.a + 0.14).clamp(0.0, 1.0),
          red: base.r + (1 - base.r) * 0.45,
          green: base.g + (1 - base.g) * 0.45,
          blue: base.b + (1 - base.b) * 0.45,
        ),
        base,
        Color.from(
          alpha: (base.a * 0.62).clamp(0.0, 1.0),
          red: base.r * 0.97,
          green: base.g * 0.97,
          blue: base.b * 0.97,
        ),
      ];

  @override
  Widget build(BuildContext context) {
    final base = tint ?? Palette.glass(context);

    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        // ⚠️ BoxDecoration 里 color 和 gradient 互斥（gradient 优先、color 被忽略），
        // 所以开了高光就只给 gradient，没开才给 color。
        color: highlight ? null : base,
        gradient: highlight
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: _highlightColors(base),
                stops: const [0, 0.42, 1],
              )
            : null,
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
