import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'motion.dart';
import 'theme.dart';

/// 启动幕各阶段时长。
///
/// RootGate 要用它们算「首页内容第几毫秒开始浮上来」，所以必须是导出的常量，
/// 不能藏进 State 里。
///
/// **2026-10-28 全线压缩**（真机实测后改的，不是拍脑袋）：
/// - 引擎首帧只要 443ms（三次均值），原来动画硬拖到 1750ms —— 多等的 1.3 秒
///   全是仪式感，记账工具一天开七八次，这个成本天天在付。
/// - 行业口径：静态 splash ≤500ms、动画 splash ≤1000ms。
/// - 现在 180 + 420 = 600ms，总感知 ≈ 443 + 600 ≈ **1.05 秒**。
const Duration kBootBreath = Duration(milliseconds: 180);
const Duration kBootOpen = Duration(milliseconds: 420);

/// 首页内容在「幕张开到这个进度」时开始浮上来。
///
/// 和幕重叠：等幕完全张开再动，中间会有一段"空首页"，观感是断成两截；
/// 有重叠才是「门开着、东西正长出来」。原来是 350ms（叠在 700ms 的张开上），
/// 现在张开只有 420ms，重叠量也跟着降到 120ms，比例保持不变。
const Duration kBootContentDelay = Duration(milliseconds: 120);

/// 启动幕：Logo 呼吸一次 → 以 Logo 为圆心把幕撑开 → 首页从圆里露出来。
///
/// 设计要点：
/// - **幕是画出来的，不是盖一层 widget**：用 CustomPaint 画「整屏矩形 挖掉
///   中间一个圆」的差集路径，圆内就是真的首页（不是截图、不是渐变假的）。
/// - **圆和 Logo 同心**：Logo 直径 96、半径 48，孔的起始半径 46，
///   Logo 刚好把孔盖住 —— 所以「呼吸」阶段屏幕上只有深色底 + 圆形 Logo，
///   不会在 Logo 边上露出一圈首页的亮边。
/// - **先慢后快**：[kBootOpen] 用 `Cubic(0.62, 0, 0.86, 0.33)`，起步几乎不动，
///   后段一下铺满；终点半径取「盖满屏幕所需半径」的 1.32 倍，
///   最后那 15% 的加速发生在屏幕外，看不出硬停。
/// - **不阻塞、不白屏**：本页不 await 任何插件，首帧立刻出；
///   底色 [kBootScrim] 和原生 launch_background 是同一个值，
///   Flutter 首帧之前和之后颜色完全一致，看不出交接。
class SplashCurtain extends StatefulWidget {
  const SplashCurtain({
    super.key,
    required this.onOpenStart,
    required this.onDone,
  });

  /// 呼吸结束、幕开始张开的那一刻。
  ///
  /// RootGate 在这一刻才把首页插到幕底下（首页的构建和数据库加载
  /// 因此和「张开」并行，不会让张开的第一帧卡一下）。
  final VoidCallback onOpenStart;

  /// 幕完全张开：可以把它从树上摘掉了（此时它已经是全透明）。
  final VoidCallback onDone;

  @override
  State<SplashCurtain> createState() => _SplashCurtainState();
}

/// 幕的底色。
///
/// 2026-10-27 从近黑改成**浅薄荷**：原来那套 #141821 跟简记的纸白
/// (#F4F6F5) + 松石绿 (#0E7C66) 是两种语言 —— 一个记账工具没必要用
/// 影视感的深色开场。现在亮色下是"绿色的一层薄幕"，和首页同一色系，
/// 拉开就是首页，衔接几乎没有色差。
///
/// **两套色值必须和原生资源一致**（否则原生窗口 → Flutter 首帧会闪色）：
/// - 亮色 → `res/values/colors.xml` 的 `boot_scrim`
/// - 暗色 → `res/values-night/colors.xml` 的 `boot_scrim`
/// 暗色不能跟着改浅：系统深色模式下先闪一块浅色再进深色首页，比什么都刺眼。
const Color kBootScrimLight = Color(0xFFE7F1ED);
const Color kBootScrimDark = Color(0xFF101614);

/// Logo 直径。孔的起始半径必须略小于它的一半。
const double kBootLogoSize = 96.0;

class _SplashCurtainState extends State<SplashCurtain>
    with TickerProviderStateMixin {
  /// ⚠️ 必须在 initState 里建，不能写成 `late final` 的字段初始化器：
  /// 开了「减少动态效果」时动画一帧都不播，那两个字段永远没被访问过，
  /// 到 dispose() 里第一次摸到它们才执行初始化 —— 而那时 element 已经
  /// deactivate，AnimationController 去查祖先 TickerMode 会直接抛
  /// "Looking up a deactivated widget's ancestor is unsafe"。
  late AnimationController _breath;
  late AnimationController _open;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(vsync: this, duration: kBootBreath);
    _open = AnimationController(vsync: this, duration: kBootOpen);
    _tick = Listenable.merge([_breath, _open]);
  }

  /// 呼吸：从略小放到原尺寸 —— 一次，不是循环。
  ///
  /// 2026-10-28 改：原来是 `0.86 → 1.06 → 1.0`（两段、幅度 20%、600ms），
  /// 那不是"呼吸"是"心跳一下" —— 60fps 下每秒变化 33%，看着像抽搐。
  /// 真呼吸感要**长时长 + 小幅度**；现在时长只剩 180ms，幅度也必须跟着收到 6%，
  /// 否则短时间大位移会更跳。
  late final Animation<double> _breathScale = Tween<double>(begin: 0.94, end: 1.0)
      .chain(CurveTween(curve: XCurve.smooth))
      .animate(_breath);

  /// 呼吸阶段的淡入（只占前 45%）：Logo 不该"啪"地出现。
  late final Animation<double> _breathFade = CurvedAnimation(
    parent: _breath,
    curve: const Interval(0, 0.45, curve: Curves.easeOut),
  );

  /// 张开曲线。
  ///
  /// 2026-10-28 换：原来 `Cubic(0.62, 0.0, 0.86, 0.33)` 是**极端的先慢后快** ——
  /// 0~300ms 曲线值几乎不动（0~5%），遮罩半径只从 46 涨到 50，屏幕上等于没变化。
  /// 那 300ms 里只有 Logo 在放大淡出，主观感受就是「抖一下 → 停住 → 突然铺开」，
  /// **这就是"不流畅"的真正来源（不是掉帧，实测动画期间 0 掉帧）**。
  ///
  /// 现在用 ease-out 主导：起步就有速度，末端自然收住。
  static const Curve _openCurve = Cubic(0.22, 0.61, 0.36, 1);

  /// 两个 controller 合成一个可监听对象。
  ///
  /// 在 initState 里建一次，不要在 build 里 `Listenable.merge`：
  /// 那样每帧新建一个 merge 对象，AnimatedBuilder 就得每帧摘/挂一次监听。
  late Listenable _tick;

  bool _primed = false;

  /// 系统开了「减少动态效果」：一帧都不演，直接进首页。
  bool _skipped = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ⚠️ 读 MediaQuery 必须放在这里，不能放 initState（debug 下会抛）。
    if (_primed) return;
    _primed = true;
    if (MediaQuery.of(context).disableAnimations) {
      _skipped = true;
      // ⚠️ 不能同步回调：didChangeDependencies 是在 BuildOwner 的锁里跑的，
      // 这时候 markNeedsBuild（RootGate 的 setState）直接触发 debug 断言
      // "setState() called during build"。推到这一帧之后就安全了。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.onOpenStart();
        widget.onDone();
      });
      return;
    }
    _breath.forward().then((_) async {
      if (!mounted) return;
      // 幕开始张开的同时把首页插进来，让它的构建/取数据并行跑完。
      widget.onOpenStart();
      await _open.forward();
      if (!mounted) return;
      widget.onDone();
    });
  }

  @override
  void dispose() {
    _breath.dispose();
    _open.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_skipped) return const SizedBox.shrink();

    final brand = Palette.brand(context);
    final dark = Palette.isDark(context);
    final scrim = dark ? kBootScrimDark : kBootScrimLight;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // 状态栏 / 导航栏跟着幕的明暗走：浅底用深图标，深底用浅图标。
      // 幕摘掉后由首页自己的主题接管，不用手动还原。
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: scrim,
        systemNavigationBarIconBrightness:
            dark ? Brightness.light : Brightness.dark,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          // 圆心到四角的最大距离（圆心在正中，所以取中心点的模长即可）。
          final coverR = size.center(Offset.zero).distance;
          return AnimatedBuilder(
            animation: _tick,
            builder: (context, _) {
              final t = _open.value;
              final e = _openCurve.transform(t);
              // 46 < 48：呼吸阶段 Logo 把孔盖得严严实实。
              //
              // 终止半径 1.08：原来的 1.32 是给"先慢后快"曲线做补偿的
              // （最后 15% 的加速要发生在屏幕外，才看不出硬停）。
              // 换成 ease-out 之后末端本来就收得住，多留 8% 只是保证盖满。
              final hole = t <= 0
                  ? 0.0
                  : 46.0 + (coverR * 1.08 - 46.0) * e;
              // 张开的前 55%（≈230ms）把 Logo 化进"门"里。
              // 原来只给 35%：在 700ms 的张开里是 245ms，还行；但张开压到 420ms
              // 后 35% 只剩 147ms，Logo 会"啪"地消失，得同步放宽到 55%。
              final logoOpacity = _breathFade.value * (1 - _clamp01(t / 0.55));
              return Stack(
                fit: StackFit.expand,
                children: [
                  CustomPaint(
                    painter: _CurtainPainter(
                      holeRadius: hole,
                      color: scrim,
                      ringColor: brand,
                      // 光圈只在"正推开"的时候看得见，铺满前自己淡掉。
                      // 浅底上要更淡一点，否则那圈绿边比 Logo 还抢眼。
                      ringAlpha:
                          (dark ? 0.42 : 0.22) * (1 - e) * (t > 0 ? 1 : 0),
                    ),
                  ),
                  // Logo 背后的一团柔光：浅底上纯色 + 一个圆盖会显得"贴上去"，
                  // 加一层几乎看不见的绿色光晕，Logo 才像从纸里浮出来。
                  // 它和 Logo 同步淡出，不参与遮罩。
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Center(
                        child: Opacity(
                          opacity: logoOpacity,
                          child: Container(
                            width: 240,
                            height: 240,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: RadialGradient(
                                colors: [
                                  brand.withValues(alpha: dark ? 0.20 : 0.13),
                                  brand.withValues(alpha: 0),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Center(
                    child: _Logo(
                      // 放大和淡出都挂在**线性**进度 t 上，不用曲线值 e：
                      // e 前段几乎不动，用它的话 Logo 会一直停在中间、
                      // 等孔已经开到半屏才慢慢化掉，看起来是"Logo 糊在首页上"。
                      //
                      // 放大只有 35%：原来 60% 是配 700ms 的，420ms 内放 60%
                      // 会像"弹射"而不是"化开"。
                      scale: _breathScale.value * (1 + 0.35 * t),
                      opacity: logoOpacity,
                      brand: brand,
                      dark: dark,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

/// 圆形 Logo + 字标。
///
/// 整组向上挪 22px，让 **Logo 的圆心**而不是整组的中心落在屏幕正中 ——
/// 幕的圆是以屏幕中心为圆心的，两者必须同心，否则张开时会歪。
class _Logo extends StatelessWidget {
  const _Logo({
    required this.scale,
    required this.opacity,
    required this.brand,
    required this.dark,
  });

  final double scale;
  final double opacity;
  final Color brand;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    return Transform.translate(
      offset: const Offset(0, -22),
      child: Opacity(
        opacity: _clamp01(opacity),
        child: Transform.scale(
          scale: scale,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: kBootLogoSize,
                height: kBootLogoSize,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    // 亮色底上不要压太黑，否则绿色发闷；暗色底才用原来的深度。
                    colors: [
                      brand,
                      Color.lerp(brand, Colors.black, dark ? 0.30 : 0.14)!,
                    ],
                  ),
                  // 浅底上给一圈极细的白边，绿圆不会显得"贴"在背景上，
                  // 而是有一点被光托起来的感觉。
                  border: dark
                      ? null
                      : Border.all(
                          color: Colors.white.withValues(alpha: 0.85),
                          width: 1.5,
                        ),
                  boxShadow: [
                    BoxShadow(
                      color: brand.withValues(alpha: dark ? 0.38 : 0.24),
                      blurRadius: dark ? 34 : 26,
                      offset: Offset(0, dark ? 14 : 10),
                    ),
                  ],
                ),
                child: const Text(
                  '简',
                  style: TextStyle(
                    fontSize: 46,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              // letterSpacing 会把最后一个字符也顶开一格，左边补回来才居中
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Text(
                  '简记',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 6,
                    // 浅底上用墨绿灰，比纯黑柔和，和首页标题同一支笔
                    color: dark
                        ? Colors.white.withValues(alpha: 0.88)
                        : Palette.inkSoft(context),
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

/// 幕：整屏矩形挖掉中间一个圆，圆内透出下面的首页。
class _CurtainPainter extends CustomPainter {
  const _CurtainPainter({
    required this.holeRadius,
    required this.color,
    required this.ringColor,
    required this.ringAlpha,
  });

  /// 0 = 不挖孔（整屏纯色）。
  final double holeRadius;
  final Color color;
  final Color ringColor;
  final double ringAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // 纯色，不再每帧 createShader。
    //
    // 原来这里每帧 `RadialGradient(...).createShader(rect)` —— 那个渐变只是让
    // 中心比边缘偏绿 14%（在浅薄荷底上肉眼几乎看不出），却要每帧新建一个
    // Shader 对象。420ms × 60fps ≈ 25 次分配，纯亏。
    final paint = Paint()..color = color;

    if (holeRadius <= 0) {
      canvas.drawRect(rect, paint);
      return;
    }

    final center = size.center(Offset.zero);

    // 挖孔：saveLayer + BlendMode.clear，**不用 Path.combine**。
    //
    // Path.combine 是 Skia 的 CPU 路径布尔运算（单次 0.5~2ms），40 多帧累积
    // 就是几十毫秒。这台 OPPO 扛住了，但千元机上就是肉眼可见的顿。
    // clear 走的是 GPU 混合，同一个视觉结果，成本低一个数量级。
    canvas.saveLayer(rect, Paint());
    canvas.drawRect(rect, paint);
    canvas.drawCircle(
      center,
      holeRadius,
      Paint()..blendMode = BlendMode.clear,
    );
    canvas.restore();

    // 孔壁上那圈光：幕被推开时有一道边在跑，比"纯色消失"有质感。
    if (ringAlpha > 0.01) {
      canvas.drawCircle(
        center,
        holeRadius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = ringColor.withValues(alpha: ringAlpha),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CurtainPainter old) =>
      old.holeRadius != holeRadius ||
      old.color != color ||
      old.ringColor != ringColor ||
      old.ringAlpha != ringAlpha;
}
