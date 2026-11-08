import 'package:flutter/material.dart';

import 'theme.dart';

/// 全 App 液态玻璃材质层（2026-11-08）。
///
/// 参考 Kyant0/Backdrop 的材质分级，但在 Skia / 老 GPU 上落地：
/// - **真模糊只在「压在滚动内容上的浮层」**（L2），由 [Glass] 负责；
///   这里不新增任何 BackdropFilter —— 顶栏 + 底栏已经占满同屏模糊预算。
/// - **交互玻璃（L3）**是零模糊的材质模拟：跟手高光 + 按压缩放 + 彩边 +
///   内阴影，用 [LiquidSurface] 包任意控件即可拿到和底栏一致的手感。
///
/// ⚠️ 缩放只作用于内容层，玻璃底/背景不跟着缩（官方 layerBlock 要修的错位）。
class LiquidTokens {
  const LiquidTokens._();

  /// 模糊半径分级：不是所有玻璃都该一样糊。
  /// 条带压的是标题与图标（18 够）、弹窗压的是整页（20 且 tint 更实）、
  /// 底栏压的是金额数字（24 才不串字）。数值是各自调过的，统一的是「引用处」。
  static const double blurBar = 18;
  static const double blurSheet = 20;
  static const double blurDock = 24;

  /// 表面 tint：纯条带透一点，密布输入框/选项的浮层要够实才读得清。
  static const double tintBar = 0.66;
  static const double tintSheet = 0.88;

  /// 交互反馈。
  static const double pressScale = 0.035;
  static const double glowAlpha = 0.22;
  static const double glowRadius = 1.3;
  static const double rimWidth = 1.4;
  static const double innerShadowWidth = 2.4;
  static const Duration pressIn = Duration(milliseconds: 170);
  static const Duration glowFade = Duration(milliseconds: 220);

  /// 表面彩边的三段色（青 → 品牌 → 品红），近似色散。
  static const Color rimCool = Color(0xFF64D8FF);
  static const Color rimWarm = Color(0xFFFF8AD8);
  static const Color darkGlow = Color(0xFF9FD8FF);
}

/// 液态玻璃的表面层：跟手高光 + 按压期边缘色散 + 内阴影。
///
/// ⚠️ 两种亮度分开管：[glow] 是跟手高光，按下同帧到 1、松手才淡出；
/// [progress] 是按压形变/彩边，允许渐入。共用一个值会让快速点击看不到光
/// （1.4.62 修过的 bug）。两者都为 0 时直接 return，静止时零绘制开销。
class LiquidOverlayPainter extends CustomPainter {
  const LiquidOverlayPainter({
    required this.progress,
    required this.glow,
    required this.touch,
    required this.radius,
    required this.accent,
    required this.dark,
  });

  final double progress;
  final double glow;
  final Offset? touch;
  final double radius;
  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.001 && glow <= 0.001) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.save();
    canvas.clipRRect(rrect);

    // ① 跟手高光：从触点散开的软光。浅色偏白、深色偏冷蓝。
    final at = touch;
    if (glow > 0.001 && at != null) {
      final light = dark ? LiquidTokens.darkGlow : Colors.white;
      final cx = ((at.dx / size.width) * 2 - 1).clamp(-1.0, 1.0).toDouble();
      final cy = ((at.dy / size.height) * 2 - 1).clamp(-1.0, 1.0).toDouble();
      final shader = RadialGradient(
        center: Alignment(cx, cy),
        radius: LiquidTokens.glowRadius,
        colors: [
          light.withValues(alpha: LiquidTokens.glowAlpha * glow),
          light.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(rect);
      canvas.drawRect(rect, Paint()..shader = shader);
    }

    if (progress > 0.001) {
      // ② 边缘色散：青 → 品牌 → 品红的一圈细描边。
      final rim = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          LiquidTokens.rimCool.withValues(alpha: 0.34 * progress),
          accent.withValues(alpha: 0.16 * progress),
          LiquidTokens.rimWarm.withValues(alpha: 0.30 * progress),
        ],
      ).createShader(rect);
      canvas.drawRRect(
        rrect.deflate(0.8),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = LiquidTokens.rimWidth
          ..shader = rim,
      );

      // ③ 内阴影：给玻璃一点厚度，只在按着时出现。
      final inner = dark ? Colors.white : Colors.black;
      canvas.drawRRect(
        rrect.deflate(2.4),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = LiquidTokens.innerShadowWidth
          ..color = inner.withValues(alpha: 0.10 * progress),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LiquidOverlayPainter old) =>
      old.progress != progress ||
      old.glow != glow ||
      old.touch != touch ||
      old.radius != radius ||
      old.accent != accent ||
      old.dark != dark;
}

/// 把任意控件变成「会响应按压的液态玻璃」。
///
/// 只用 [Listener] 读原始指针（**不进手势竞技场**，绝不抢 child 自己的
/// 点击/拖动/滑条手势），所以可以直接包 Switch、Slider、按钮、Chip 等。
/// 视觉层用 IgnorePointer，静止时 painter 直接 return。
class LiquidSurface extends StatefulWidget {
  const LiquidSurface({
    super.key,
    required this.child,
    this.radius = 16,
    this.enabled = true,
  });

  final Widget child;
  final double radius;

  /// 关掉后完全不接管（减少动态效果 / 性能降级时用）。
  final bool enabled;

  @override
  State<LiquidSurface> createState() => _LiquidSurfaceState();
}

class _LiquidSurfaceState extends State<LiquidSurface>
    with TickerProviderStateMixin {
  late final AnimationController _glow = AnimationController(
    vsync: this,
    duration: LiquidTokens.glowFade,
    value: 0,
  );
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: LiquidTokens.pressIn,
  );

  Offset? _touch;

  bool get _reduce =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  @override
  void initState() {
    super.initState();
    _glow.addListener(_tick);
    _press.addListener(_tick);
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _glow.dispose();
    _press.dispose();
    super.dispose();
  }

  void _down(Offset at) {
    if (!widget.enabled) return;
    _touch = at;
    _glow.stop();
    _glow.value = 1; // 同帧点亮，位置立刻在手指处
    if (!_reduce) _press.forward();
    _tick();
  }

  void _up() {
    if (!widget.enabled) return;
    // 不清 _touch：淡出期间光留在最后触点慢慢散。
    _press.reverse();
    if (_reduce) {
      _glow.value = 0;
    } else {
      _glow.animateTo(0, curve: Curves.easeOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final dark = Palette.isDark(context);
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _down(e.localPosition),
      onPointerUp: (_) => _up(),
      onPointerCancel: (_) => _up(),
      child: Transform.scale(
        scale: 1.0 + LiquidTokens.pressScale * _press.value,
        child: Stack(
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: LiquidOverlayPainter(
                    progress: _press.value,
                    glow: _glow.value,
                    touch: _touch,
                    radius: widget.radius,
                    accent: Palette.brand(context),
                    dark: dark,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
