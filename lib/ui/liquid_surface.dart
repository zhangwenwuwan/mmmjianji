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

  /// 受光沿（1.4.65）：贴在轮廓上、只亮触点那一侧的一道柔光。
  /// ⚠️ 必须是**模糊**的，宽度略大于 1 —— 硬描边（原来 1.4 + 2.4 黑内阴影
  /// 两条贴在一起）在浅色玻璃上会读成「几层灰黑硬边」，用户实测反馈丑。
  static const double rimWidth = 1.6;
  static const double rimBlur = 1.4;

  /// 内侧厚度光：从边缘向内衰减的一圈柔白，只在触点附近出现，不是整圈线圈。
  static const double depthInset = 2.2;
  static const double depthWidth = 3.4;
  static const double depthBlur = 3.0;

  static const Duration pressIn = Duration(milliseconds: 170);
  static const Duration glowFade = Duration(milliseconds: 220);

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
    final at = touch;
    if (at == null) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.save();
    canvas.clipRRect(rrect);

    final light = dark ? LiquidTokens.darkGlow : Colors.white;
    final cx = ((at.dx / size.width) * 2 - 1).clamp(-1.0, 1.0).toDouble();
    final cy = ((at.dy / size.height) * 2 - 1).clamp(-1.0, 1.0).toDouble();
    final center = Alignment(cx, cy);

    // ① 跟手高光：从触点散开的软光。浅色偏白、深色偏冷蓝。
    if (glow > 0.001) {
      final shader = RadialGradient(
        center: center,
        radius: LiquidTokens.glowRadius,
        colors: [
          light.withValues(alpha: LiquidTokens.glowAlpha * glow),
          light.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(rect);
      canvas.drawRect(rect, Paint()..shader = shader);
    }

    // ② 受光沿（1.4.65 replace 彩边 + 黑内阴影）：
    //
    // 旧版是「青→品牌→品红」整圈描边 1.4px + 内侧再叠一圈黑 2.4px。
    // 两条线只隔 1.6px，浅色玻璃上直接读成几层灰黑硬边；
    // 再加上按压时整层放大 3.5% 被外框裁掉半条，断口更明显。
    //
    // 换成液态玻璃真正的做法：光只沿**触点那一侧**的轮廓出现，向两侧衰减到 0。
    // 整圈没有硬线，光跟着手指走 —— 这才像液体被压出来的高光。
    if (glow > 0.001) {
      final rim = RadialGradient(
        center: center,
        radius: 0.88,
        colors: [
          light.withValues(alpha: 0.52 * glow),
          light.withValues(alpha: 0.16 * glow),
          light.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(rect);
      canvas.drawRRect(
        rrect.deflate(LiquidTokens.rimWidth / 2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = LiquidTokens.rimWidth
          ..maskFilter =
              const MaskFilter.blur(BlurStyle.normal, LiquidTokens.rimBlur)
          ..shader = rim,
      );

      // ③ 内侧厚度：同样跟手、同样模糊，只给一点点"玻璃有厚度"的暗示。
      // 用白而不是黑 —— 黑色内阴影在浅色上是脏灰边，玻璃变厚应该是**更亮**。
      canvas.drawRRect(
        rrect.deflate(LiquidTokens.depthInset),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = LiquidTokens.depthWidth
          ..maskFilter =
              const MaskFilter.blur(BlurStyle.normal, LiquidTokens.depthBlur)
          ..shader = RadialGradient(
            center: center,
            radius: 0.7,
            colors: [
              light.withValues(alpha: (dark ? 0.16 : 0.12) * glow),
              light.withValues(alpha: 0.0),
            ],
          ).createShader(rect),
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
