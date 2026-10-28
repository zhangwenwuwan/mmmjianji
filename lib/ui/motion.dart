import 'package:flutter/material.dart';
// Ticker 在 scheduler 库里，material/widgets 都不导出它
import 'package:flutter/scheduler.dart' show Ticker;

import 'glass.dart';
import 'theme.dart';

/// ui-motion 动效基础层。
///
/// 设计原则（来自 ui-motion-skill）：
/// - 时长分级：小元素 150–250ms / 面板 300–450ms / 转场 450–600ms，最长不超过 700ms。
/// - 曲线：进场 ease-out、退场 ease-in、弹性超调 ≤8%；禁止 linear。
/// - 性能：只动 transform / opacity；层次错落 30–60ms；按下缩到 0.96–0.98。
/// - 尊重系统「减少动态效果」：MediaQuery.disableAnimations 时压成 120ms 淡入。
class Motion {
  const Motion._();

  static const Duration small = Duration(milliseconds: 200);

  /// 面板/浮现：320ms。原来是 380ms，配 easeOut 的长尾太拖；
  /// 换成 320ms + [XCurve.enter] 后是「唰地到位」，跟 Reveal 默认值一致。
  static const Duration panel = Duration(milliseconds: 320);

  /// 页面转场（进场）。480ms 对原生页面太慢，且配合 easeOut 的长尾会显得"蹭"，
  /// 换成 Material 3 的常规值 300ms。
  static const Duration page = Duration(milliseconds: 300);

  /// 页面退场比进场更快（原生惯例）：退场是"回到上一页"，不该让用户等。
  static const Duration pageOut = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 600);

  /// 根据系统设置返回实际时长（减少动态时统一压短）。
  static Duration d(BuildContext context, Duration base) =>
      MediaQuery.of(context).disableAnimations
          ? const Duration(milliseconds: 120)
          : base;
}

/// 曲线令牌。
class XCurve {
  const XCurve._();
  static const easeOut = Cubic(0.0, 0.0, 0.2, 1.0); // 进场
  static const easeIn = Cubic(0.4, 0.0, 1.0, 1.0); // 退场
  static const smooth = Cubic(0.4, 0.0, 0.2, 1.0); // 双向
  static const spring = Cubic(0.34, 1.56, 0.64, 1.0); // 轻微回弹（超调≤8%）

  /// 页面转场专用：Material 3 **emphasized-decelerate**（0.05,0.7,0.1,1）。
  ///
  /// 前 20% 的时间就走完约 70% 的位移，剩下的时间只收尾 —— 观感是
  /// 「唰地到位，然后稳住」；而 [easeOut] 是全程匀速衰减，最后的 2%
  /// 位移还要蹭很久，那就是拖沓感的来源。
  static const enter = Cubic(0.05, 0.7, 0.1, 1.0);
}

bool _reduced(BuildContext context) => MediaQuery.of(context).disableAnimations;

/// 按下反馈：点下去缩到 0.96，松开带弹性回弹到 1。
///
/// 包裹任意可点元素（卡片、行、按钮），给到"按得下去"的手感，
/// 而不是只换个颜色。尊重减少动态效果。
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.96,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 长按（流水行进入批量选择用）。为空则不接管长按。
  final VoidCallback? onLongPress;
  final double scale;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 120),
    lowerBound: 0.8,
    upperBound: 1.0,
  )..value = 1.0;

  /// 是否正按着（用来区分「用户还按着」和「转场把动画打断了」）
  bool _pressed = false;

  bool get _reduce => _reduced(context);

  void _down() {
    if (_reduce) return;
    _pressed = true;
    _ctrl.animateTo(widget.scale, curve: XCurve.easeOut);
  }

  void _up() {
    if (_reduce) return;
    _pressed = false;
    _ctrl.animateTo(1.0, curve: XCurve.spring);
  }

  void _handleTap() {
    widget.onTap?.call();
    _pressed = false;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 【关键】卡片"阻滞感"的真正来源：
    // onTapUp 会起一段 120ms 回弹动画，紧接着 onTap 里 push 了新页面，
    // 本页的 TickerMode 立刻被禁用 → 回弹动画冻结在半路，卡片就一直保持
    // 缩小状态；等 pop 回来 TickerMode 恢复，它才突然弹回 1.0，
    // 看起来就是"卡片卡住、顿一下"。
    // 所以在页面重新可见时，如果还停在缩小态就直接复位，不做动画。
    if (!_pressed &&
        TickerMode.valuesOf(context).enabled &&
        _ctrl.value < 0.999) {
      _ctrl.value = 1.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _down(),
      onTapUp: (_) => _up(),
      onTapCancel: () => _up(),
      onTap: widget.onTap == null ? null : _handleTap,
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              widget.onLongPress!.call();
              _pressed = false;
              _ctrl.animateTo(1.0, curve: XCurve.easeOut);
            },
      behavior: HitTestBehavior.opaque,
      child: ScaleTransition(
        scale: _ctrl,
        child: widget.child,
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
}

/// 进场浮现：淡入 + 轻微上移（10px），可错开 delay 形成层次。
///
/// 一组元素依次出现，间隔 40–60ms；首屏内容不要藏起来等滚动，直接显示。
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    // 380ms 配 easeOut 的长尾太拖；320ms 配 emphasized-decelerate 才是
    // 「东西已经出来了」而不是「正在慢慢出来」。
    this.duration = const Duration(milliseconds: 320),
    this.y = 10.0,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;
  final double y;

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _ctrl,
    curve: XCurve.enter,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: Offset(0, widget.y / 100),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ctrl, curve: XCurve.enter));

  bool _primed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ⚠️ 读 MediaQuery 必须放在这里：放 initState 里读 InheritedWidget，
    // debug 下会抛 "… was called before initState() completed"。
    // didChangeDependencies 可能被多次调用，所以只跑第一次。
    if (_primed) return;
    _primed = true;
    if (_reduced(context)) {
      _ctrl.value = 1.0;
      return;
    }
    // 延迟封顶 240ms：分组多的月份如果一档一档排队，最后几组要等很久，
    // 观感是「页面卡住然后突然全出来」。
    final wait = widget.delay > const Duration(milliseconds: 240)
        ? const Duration(milliseconds: 240)
        : widget.delay;
    Future.delayed(wait, () {
      if (mounted) _ctrl.forward();
    });
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _opacity,
        child: SlideTransition(position: _slide, child: widget.child),
      );

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }
}

/// 全局扫光时钟。
///
/// 之前每个 Shimmer 各建一个 AnimationController 并 repeat：明细页加载时
/// 有 19 个骨架就是 **19 个常驻控制器**，而且各自起始相位不同，扫光看起来
/// 是「一片乱闪」。改成一条共享时间轴后只有一个 Ticker，所有骨架同相位
/// 扫过，画面干净，也省电。
class _ShimmerClock {
  _ShimmerClock._();

  static final ValueNotifier<double> value = ValueNotifier<double>(0);
  static Ticker? _ticker;
  static int _refs = 0;

  static void attach() {
    _refs++;
    if (_ticker != null) return;
    _ticker = Ticker((elapsed) {
      value.value = (elapsed.inMilliseconds % 1500) / 1500;
    })..start();
  }

  static void detach() {
    _refs--;
    if (_refs > 0) return;
    _ticker?.dispose();
    _ticker = null;
    _refs = 0;
    value.value = 0;
  }
}

/// 骨架屏扫光：所有骨架共用一道柔和斜向光带，周期 1.5s，峰值不刺眼。
///
/// 形状、尺寸、位置和真实内容一致，加载前后布局不跳。
class Shimmer extends StatefulWidget {
  const Shimmer({
    super.key,
    required this.child,
    this.base,
    this.highlight,
  });

  final Widget child;
  final Color? base;
  final Color? highlight;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> {
  bool _attached = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ⚠️ 读 MediaQuery 必须放在这里：放 initState 里读 InheritedWidget，
    // debug 下会抛 "dependOnInheritedWidgetOfExactType<MediaQuery>() ... before
    // initState() completed"，骨架屏一出现就红屏。
    // didChangeDependencies 会跟着系统设置变化重复调用，所以做成幂等的。
    final reduce = MediaQuery.of(context).disableAnimations;
    if (reduce && _attached) {
      _ShimmerClock.detach();
      _attached = false;
    } else if (!reduce && !_attached) {
      _ShimmerClock.attach();
      _attached = true;
    }
  }

  @override
  void dispose() {
    if (_attached) _ShimmerClock.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reduced(context)) return widget.child;
    final base = widget.base ?? Palette.hairline(context);
    final hi = widget.highlight ??
        Color.lerp(base, Colors.white, 0.45)!.withValues(alpha: 0.9);
    return ValueListenableBuilder<double>(
      valueListenable: _ShimmerClock.value,
      builder: (context, v, _) {
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => LinearGradient(
            begin: const Alignment(-1.2, -1.2),
            end: const Alignment(1.2, 1.2),
            colors: [base, hi, base],
            stops: [0.0, v, 1.0],
          ).createShader(bounds),
          child: widget.child,
        );
      },
    );
  }
}

/// 骨架占位块（圆角矩形，带扫光）。
class Skeleton extends StatelessWidget {
  const Skeleton({
    super.key,
    this.width,
    this.height,
    this.radius = 12,
    this.expand = false,
  });

  final double? width;
  final double? height;
  final double radius;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final base = Palette.hairline(context);
    final block = Container(
      width: expand ? double.infinity : width,
      height: height,
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    return Shimmer(child: block);
  }
}

/// 列表页加载态：几条等高骨架行，形状与真实行一致，加载前后布局不跳。
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    super.key,
    this.count = 5,
    this.height = 58,
    this.gap = 8,
    this.radius = 14,
  });

  final int count;
  final double height;
  final double gap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 88),
      children: [
        for (var i = 0; i < count; i++) ...[
          Skeleton(height: height, radius: radius),
          if (i < count - 1) SizedBox(height: gap),
        ],
      ],
    );
  }
}

// SlidingPill 已删除：全项目无人引用，而且它的 right 边距写成了绝对值
// slot*0.12（没有减掉左侧偏移），算出来的宽度是「好几个 tab 那么宽」——
// 一旦有人拿去用就会看到一个横跨半屏的怪胶囊。底栏那份是直接在
// 「Positioned 里嵌 LayoutBuilder」的写法上实现的（见 shell.dart），
// 那套写法才是对的。

/// 方向转场：新页面从点击方向轻推淡入，旧页面同向退场。
///
/// 用作 Navigator.push 的路由，让页面切换有空间关系而不是硬切。
///
/// ⚠️ 关于淡入曲线：`opaque: true` 的路由在转场期间，Overlay 只绘制最上面那个
/// 不透明 entry、**跳过下层**。所以淡入绝不能是平滑的 ease-out —— 那会让新页面
/// 在整段 480ms 里保持半透明，屏幕露出 Overlay 底色，看起来就是「残影」。
/// Flutter 官方 `MaterialPageRoute` 的转场用的是 `Threshold(0.10)`：前 10%
/// 阶跃到位、之后恒为 1。这里照做，并且 pop（reverse）时干脆不淡入。
class AppPageRoute extends PageRouteBuilder {
  AppPageRoute({
    required Widget page,
    bool forward = true,
    super.settings,
  }) : super(
          pageBuilder: (context, animation, secondary) => page,
          transitionDuration: Motion.page,
          reverseTransitionDuration: Motion.pageOut,
          opaque: true,
          barrierDismissible: false,
          transitionsBuilder: (context, animation, secondary, child) {
            // 尊重「减少动态效果」：直接不转场
            if (MediaQuery.of(context).disableAnimations) return child;
            // 位移必须保持很小：opaque 路由转场时 Overlay 只绘制最上面那一页
            // （overlay.dart 的 onstage 遇到 opaque 就把下面的全转 offstage），
            // 所以页面一横移，没被覆盖的那条边就露出 Scaffold 底色。
            // 8% 进场 / 6% 退场：够表达"推进方向"，又不至于看出空条。
            final dx = (forward ? 1 : -1) * (forward ? 0.08 : 0.06);
            final slide = Tween<Offset>(
              begin: Offset(dx, 0),
              end: Offset.zero,
            ).animate(CurvedAnimation(
              parent: animation,
              // 原来用 easeOut(0,0,0.2,1)：80% 的时间只走最后 2% 的位移，
              // 观感就是"冲一下然后长时间蹭"。换成 emphasized-decelerate。
              curve: XCurve.enter,
            ));
            // 【性能·关键】RepaintBoundary 必须放在 SlideTransition **里面**：
            // 这样页面先栅格化成自己的图层，转场期间只是换一个合成偏移，
            // 不再每帧重画整页（卡片阴影 / 圆角裁剪 / 渐变都很贵）。
            // 放到外面就白搭 —— boundary 里含 transform，照样每帧重画。
            // 弱 GPU（Adreno 615）上这是 60fps 与掉帧的分界线。
            //
            // 另外原来那层 `Threshold(0.12)` 的 FadeTransition 已经删掉：
            // 它前 12% 是全透明、之后直接跳到 1.0，视觉上就是硬切，
            // 却让整页白走一次 full-screen saveLayer。删掉更快也更干净。
            return SlideTransition(
              position: slide,
              child: RepaintBoundary(child: child),
            );
          },
        );
}

/// 通用底部弹窗：圆角顶部 + 拖拽手柄 + 弹簧升起；背后由系统 scrim 压暗。
///
/// 用于分类/账户/日期等选择面板，统一"从底部升起"的手感。
///
/// [scrollable] 默认 true：外层套 SingleChildScrollView，内容多时整页滚动。
/// 若内容自身带滚动控件（内部已有 ListView/SingleChildScrollView，
/// 且用了 Flexible 分配剩余高度），必须传 false——否则外层无界高度会让
/// Column 里的 Flexible 抛「unbounded height」异常。
///
/// [fillsHeight] = true 时（必须同时 `scrollable: false`），面板会把剩余高度
/// **撑满**交给内容，内容里才能用 Expanded 把「键盘常驻底部 + 上半部分可滚动」
/// 这类布局撑起来。普通短面板不要开，否则底部会空出一大块。
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  bool isScrollControlled = true,
  bool scrollable = true,
  bool fillsHeight = false,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _AppSheetBody(
      title: title,
      builder: builder,
      scrollable: scrollable,
      fillsHeight: fillsHeight,
    ),
  );
}

class _AppSheetBody extends StatelessWidget {
  const _AppSheetBody({
    this.title,
    required this.builder,
    this.scrollable = true,
    this.fillsHeight = false,
  });

  final String? title;
  final WidgetBuilder builder;
  final bool scrollable;
  final bool fillsHeight;

  @override
  Widget build(BuildContext context) {
    // 把手和标题必须和内容在同一个圆角容器里。
    // 原来它们画在容器外面（透明背景），看起来像「悬空的一段灰条 + 白字」。
    // 另外底部留出键盘高度：isScrollControlled 的面板默认会被输入法盖住，
    // 含输入框的面板（改名、备注、金额）不处理就是体验事故。
    // viewInsets = 输入法高度，viewPadding = 系统导航栏高度；
    // 键盘弹起时 viewPadding.bottom 会自动归零，两者不会重复叠加。
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom +
        MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      // 底部面板也用玻璃：它压在整个页面上，模糊能透出后面的内容，
      // 但 tint 要更实一点（0.88）—— 面板里全是输入框和选项，
      // 透得太厉害会看不清自己在填什么。
      child: Glass(
        blur: 20,
        tint: Palette.glass(context).withValues(alpha: 0.88),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        child: Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.86,
          ),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Palette.inkFaint(context).withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(title!,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
              ),
            scrollable
                ? Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: builder(context),
                    ),
                  )
                : fillsHeight
                    ? Expanded(child: builder(context))
                    : Flexible(child: builder(context)),
          ],
        ),
        ),
      ),
    );
  }
}

/// 保存成功对勾（对应原版 save_success_overlay）。
///
/// 在 rootOverlay 上弹一个圆底对勾：缩放进场（带轻微回弹）→ 停一下 → 淡出，
/// 不阻塞后续的关闭流程。连续记账时不弹，避免打断录入。
Future<void> showSaveSuccessCheck(BuildContext context) async {
  if (MediaQuery.of(context).disableAnimations) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => const IgnorePointer(child: Center(child: _CheckBurst())),
  );
  overlay.insert(entry);
  await Future<void>.delayed(const Duration(milliseconds: 760));
  if (entry.mounted) entry.remove();
}

class _CheckBurst extends StatefulWidget {
  const _CheckBurst();

  @override
  State<_CheckBurst> createState() => _CheckBurstState();
}

class _CheckBurstState extends State<_CheckBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  @override
  void initState() {
    super.initState();
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brand = Theme.of(context).colorScheme.primary;
    final scale = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.5, end: 1.08)
            .chain(CurveTween(curve: const Cubic(0.34, 1.56, 0.64, 1))),
        weight: 40,
      ),
      TweenSequenceItem(tween: Tween(begin: 1.08, end: 1.0), weight: 60),
    ]).animate(_ctrl);
    final opacity = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 25),
      TweenSequenceItem(tween: ConstantTween<double>(1), weight: 45),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 30),
    ]).animate(_ctrl);

    return FadeTransition(
      opacity: opacity,
      child: ScaleTransition(
        scale: scale,
        child: Container(
          width: 84,
          height: 84,
          decoration: BoxDecoration(
            color: brand,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: brand.withValues(alpha: 0.35),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(Icons.check_rounded, color: Colors.white, size: 44),
        ),
      ),
    );
  }
}

/// 果冻开关：圆点滑向另一端时先横向拉长成胶囊再回弹，底色渐变。
///
/// 替换原生 Switch，给设置项一点"手感"。
class JellySwitch extends StatefulWidget {
  const JellySwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.activeColor,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final Color? activeColor;

  @override
  State<JellySwitch> createState() => _JellySwitchState();
}

class _JellySwitchState extends State<JellySwitch>
    with SingleTickerProviderStateMixin {
  @override
  Widget build(BuildContext context) {
    final active = widget.activeColor ?? Palette.brand(context);
    final inactive = Palette.hairline(context);
    const trackW = 46.0;
    const trackH = 28.0;
    const knob = 22.0;
    final on = widget.value;
    return GestureDetector(
      onTap: () => widget.onChanged(!on),
      child: AnimatedContainer(
        duration: Motion.d(context, const Duration(milliseconds: 350)),
        curve: XCurve.spring,
        width: trackW,
        height: trackH,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(trackH / 2),
          color: on ? active : inactive,
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedPositioned(
              duration: Motion.d(context, const Duration(milliseconds: 350)),
              curve: XCurve.spring,
              left: on ? trackW - knob - 3 : 3,
              top: (trackH - knob) / 2,
              child: Container(
                width: knob,
                height: knob,
                decoration: const BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x22000000),
                      blurRadius: 3,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 提交按钮三连变（Submit Morph）：空闲是完整按钮，保存时收缩成圆形转圈，
/// 成功后由调用方直接 pop，无需在按钮内画对勾。
class MorphButton extends StatelessWidget {
  const MorphButton({
    super.key,
    required this.saving,
    required this.onPressed,
    required this.label,
    required this.color,
  });

  final bool saving;
  final VoidCallback? onPressed;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final size = 50.0;
    return SizedBox(
      height: size,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          // ⚠️ 不能用 `width: double.infinity`：AnimatedContainer 会把 width
          // 当成 BoxConstraints(minWidth: ∞, maxWidth: ∞) 来和保存态的 50
          // 做 lerp，而 BoxConstraints.lerp 不允许 finite 与 infinite 之间插值，
          // 会直接断言崩溃（Cannot interpolate between finite and unbounded）。
          // 改成用 LayoutBuilder 取到的「父级有限宽度」作为展开态宽度。
          final full = constraints.maxWidth;
          return Center(
            child: AnimatedContainer(
              duration: Motion.d(context, const Duration(milliseconds: 300)),
              curve: XCurve.smooth,
              width: saving ? size : full,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(saving ? size / 2 : 12),
              ),
              child: Center(
                child: saving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      )
                    : PressScale(
                        scale: 0.97,
                        onTap: onPressed,
                        child: Center(
                          child: Text(
                            label,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}
