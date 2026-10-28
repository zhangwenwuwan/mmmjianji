import 'package:flutter/material.dart';

import 'motion.dart';

/// 启动「开幕」时间线。
///
/// 首页内容要在启动幕张开到一半时**依次**浮上来（每块间隔 60ms），
/// 但每一块都是被 provider 数据驱动、随时可能新建的 —— 它们不能
/// "从自己出生那一刻"开始排队，否则晚到 500ms 的流水会自己单独浮一次，
/// 看起来就是「东西乱蹦」。
///
/// 所以这里用**绝对时刻**：每块按自己的序号算出它该出现的时刻，
/// 和当前时刻比，差多少就 delay 多少；已经过了就直接播。
class BootRevealTimeline {
  BootRevealTimeline({
    required this.startAt,
    this.step = const Duration(milliseconds: 60),
  });

  /// 第 0 块开始浮上来的时刻。
  final DateTime startAt;

  /// 相邻两块的间隔。
  final Duration step;

  /// 是否还在「启动这一次」里。
  ///
  /// 启动幕收完就置 false：之后新建的块（刷新列表、切 tab 回来）
  /// 一律直接显示，不再排队。只让冷启动那一次有仪式感。
  bool active = true;

  /// 序号上限：超出这个序号的块跟最后一批同时出现。
  ///
  /// 不封顶的话，一个有 20 组流水的月份要排到 1.2 秒之后才出来，
  /// 观感是「页面卡住、然后突然全出来」。
  static const int maxIndex = 6;

  Duration delayFor(int index) {
    final i = index < 0 ? 0 : (index > maxIndex ? maxIndex : index);
    final d = startAt.add(step * i).difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }
}

/// 把 [BootRevealTimeline] 挂到启动那棵子树上。
///
/// 只在 RootGate 里建一次；启动幕收完之后它仍然在树上，
/// 但 `timeline.active` 已经是 false，新块读到了就直接显示。
class BootRevealScope extends InheritedWidget {
  const BootRevealScope({
    super.key,
    required this.timeline,
    required super.child,
  });

  final BootRevealTimeline timeline;

  static BootRevealTimeline? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<BootRevealScope>()?.timeline;

  @override
  bool updateShouldNotify(covariant BootRevealScope oldWidget) =>
      oldWidget.timeline != timeline;
}

/// 首页的一块内容：冷启动时按 [index] 依次浮上来（淡入 + 从下往上）。
///
/// ⚠️ 只影响冷启动那一次：
/// - 时间线不存在（比如从别的页面 push 进来）→ 直接显示；
/// - 时间线已失效（启动早就结束了）→ 直接显示；
/// - 系统开了「减少动态效果」→ 直接显示。
///
/// 位移用 [Transform.translate] 而不是 SlideTransition：后者是**相对于
/// child 尺寸**的百分比，一个 300 高的卡片和一行 20 高的文字位移量会差
/// 十五倍，错落起来就是乱的。这里要的是固定 22px。
class BootRevealItem extends StatefulWidget {
  const BootRevealItem({
    super.key,
    required this.index,
    required this.child,
    this.y = 22.0,
    this.duration = const Duration(milliseconds: 360),
  });

  /// 出场顺序：0 最先。超出 [BootRevealTimeline.maxIndex] 的按最后一批算。
  final int index;

  /// 起始下沉距离（px）。
  final double y;

  final Duration duration;
  final Widget child;

  @override
  State<BootRevealItem> createState() => _BootRevealItemState();
}

class _BootRevealItemState extends State<BootRevealItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: widget.duration);

  late final Animation<double> _ease =
      CurvedAnimation(parent: _ctrl, curve: XCurve.enter);

  bool _primed = false;

  /// 已经决定「不做动画」：之后不再理会时间线。
  bool _settled = false;

  void _showNow() {
    _settled = true;
    if (_ctrl.value < 1.0) _ctrl.value = 1.0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ⚠️ 读 MediaQuery / InheritedWidget 必须放在这里，不能放 initState：
    // 在 initState 里读会抛 "… was called before initState() completed"。
    if (_settled) return;

    final timeline = BootRevealScope.maybeOf(context);
    if (MediaQuery.of(context).disableAnimations ||
        timeline == null ||
        !timeline.active) {
      _showNow();
      return;
    }
    if (_primed) return;
    _primed = true;

    final delay = timeline.delayFor(widget.index);
    Future<void>.delayed(delay, () {
      if (!mounted) return;
      // 等待期间可能已经过了启动窗口（比如幕被跳过）：那就别动了。
      final now = BootRevealScope.maybeOf(context);
      if (now == null || !now.active) {
        _showNow();
        return;
      }
      _ctrl.forward();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ease,
      // child 只 build 一次：浮入动画不该把整块内容每帧重建
      // （首页那张大卡 + 流水列表重建一次就是好几毫秒）。
      builder: (context, child) {
        final t = _ease.value;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, widget.y * (1 - t)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
