import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 顶部下拉 → 触发一次回调（简记用在首页：下拉记一笔）。
///
/// ## 交互设计（2026-10-24 按真机反馈重做）
///
/// 第一版是「一过阈值就立刻跳转」，真机上手感很突兀——手指还没拉出感觉，
/// 页面已经跳走了，用户不知道刚才触发了什么。现在改成两步：
///
/// 1. 下拉过程中给出**可见提示**（"继续下拉" → "松开手指"）；
/// 2. **只在松手时**才触发，阈值提到 260dp。
///
/// 2026-10-25 再调一次：150 在真机上仍然太灵敏 —— 想滚回顶部时手指带一下
/// 就记一笔，反而打断动作。260 ≈ 接近半屏高度，必须是"明确的、刻意的下拉"，
/// 顺手带一下不会误触。
///
/// ## 三个必须处理的细节
///
/// - **只在顶部**累计：`metrics.pixels <= 0` 才认，列表不在顶部时的 overscroll 不算。
/// - **只算纵向**：页面里还有横向滚动区（月份条），它的通知会冒泡到这里，
///   不判 axis 会把左右滑误当成下拉。
/// - **一次手势只触发一次**：`_fired` 在 ScrollStart 复位。
class PullToAdd extends StatefulWidget {
  const PullToAdd({
    super.key,
    required this.child,
    required this.onTrigger,
    this.threshold = 260,
  });

  final Widget child;
  final VoidCallback onTrigger;

  /// 触发阈值（逻辑像素）。260 ≈ 半屏高度的一半：刻意下拉才够，顺手带一下不够。
  final double threshold;

  @override
  State<PullToAdd> createState() => _PullToAddState();
}

class _PullToAddState extends State<PullToAdd> {
  double _drag = 0;
  bool _fired = false;

  /// 0~1 的下拉进度，只用于提示条透明度；变化小于 2% 不重建。
  double _shown = 0;

  /// 是否已过阈值（决定提示文案与触觉反馈）。
  bool _armed = false;

  void _syncHint() {
    final v = (_drag / widget.threshold).clamp(0.0, 1.0);
    final armed = _drag >= widget.threshold;
    if ((v - _shown).abs() < 0.02 && armed == _armed) return;
    if (armed && !_armed) HapticFeedback.selectionClick();
    setState(() {
      _shown = v;
      _armed = armed;
    });
  }

  void _reset() {
    _drag = 0;
    if (_shown != 0 || _armed) {
      setState(() {
        _shown = 0;
        _armed = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.axis != Axis.vertical) return false;

            if (n is ScrollStartNotification) {
              _drag = 0;
              _fired = false;
              _reset();
              return false;
            }
            if (n is OverscrollNotification) {
              // overscroll 为负 = 越过顶部继续下拉。只累计下拉量。
              // 注：Flutter 在"往回推"时不发 overscroll 通知，所以一旦过了阈值
              // 就无法靠回推取消——这和系统下拉刷新的手感一致，不做特殊处理。
              if (n.metrics.pixels <= 0 && n.overscroll < 0) {
                _drag += -n.overscroll;
                _syncHint();
              }
              return false;
            }
            if (n is ScrollEndNotification) {
              // 松手才判定：够阈值就跳转，然后立刻收起提示
              final shouldFire = _armed && !_fired;
              _drag = 0;
              _reset();
              if (shouldFire) {
                _fired = true;
                widget.onTrigger();
              }
            }
            return false;
          },
          child: widget.child,
        ),
        // 下拉提示条：只在手势过程中出现，不拦事件
        Positioned(
          top: MediaQuery.of(context).padding.top + 6,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _shown,
              duration: const Duration(milliseconds: 120),
              child: Center(child: _PullHint(armed: _armed)),
            ),
          ),
        ),
      ],
    );
  }
}

class _PullHint extends StatelessWidget {
  const _PullHint({required this.armed});

  final bool armed;

  @override
  Widget build(BuildContext context) {
    final brand = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: brand.withValues(alpha: armed ? 0.92 : 0.82),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            armed ? Icons.keyboard_double_arrow_up : Icons.arrow_downward,
            size: 13,
            color: Theme.of(context).colorScheme.onPrimary,
          ),
          const SizedBox(width: 5),
          Text(
            armed ? '松开手指，记一笔' : '继续下拉，记一笔',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}
