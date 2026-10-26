import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/aggregate.dart';
import '../core/rules.dart';
import 'motion.dart';
import 'theme.dart';

/// 图表分类色板。唯一来源：之前 charts / 资产构成 / 洞察图例各抄一份，
/// 改一个颜色要改三处，容易漏。
const kSliceColors = <Color>[
  Color(0xFF0E7C66),
  Color(0xFF3E9DBF),
  Color(0xFFE0A458),
  Color(0xFFC94F45),
  Color(0xFF7B6BB5),
  Color(0xFF9AA19C),
];

/// 环形占比图（带动效）。
///
/// - 各扇区从顶部起顺时针依次「转」出来（错落 90ms/个）；
/// - 中心金额从 0 滚到总额；
/// - 点某个扇区，它会向外弹出、其它扇区变暗，再点一下收回。
/// 尊重系统「减少动态效果」。
class DonutChart extends StatefulWidget {
  const DonutChart({
    super.key,
    required this.slices,
    required this.totalCents,
    required this.symbol,
    this.hideAmounts = false,
    this.centerTitle = '本月支出',
    this.size = 148,
  });

  final List<Slice> slices;
  final int totalCents;
  final String symbol;
  final bool hideAmounts;
  final String centerTitle;
  final double size;

  @override
  State<DonutChart> createState() => _DonutChartState();
}

class _DonutChartState extends State<DonutChart>
    // ⚠️ 必须是 TickerProviderStateMixin（复数）。这个 State 有**两个**
    // AnimationController：_ctrl（扫过动画）+ _popCtrl（点击扇区弹一下）。
    // 用 Single 版本会抛：
    //   "SingleTickerProviderStateMixin but multiple tickers were created"
    // 而且只在**有数据**时才炸（空数据不构建环形图），所以空库测试永远发现不了。
    with TickerProviderStateMixin {
  // ⚠️ 这里只能写死时长，不能写 Motion.d(context, ...)：
  // late 字段初始化器是「首次访问时才求值」，而首次访问发生在 initState 里，
  // 那时读 MediaQuery（InheritedWidget）在 debug 下会直接抛异常（红屏）。
  // 「减少动态效果」统一放到下面的 didChangeDependencies 里处理。
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    // 不超过 700ms 上限；错落感由每个扇区自己的 stagger 提供
    duration: Motion.slow,
  );
  late final Animation<double> _progress =
      CurvedAnimation(parent: _ctrl, curve: XCurve.easeOut);
  late final AnimationController _popCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );
  late final Animation<double> _pop =
      CurvedAnimation(parent: _popCtrl, curve: XCurve.spring);

  int _selected = -1;
  int _popIndex = -1;
  bool _primed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_primed) return;
    _primed = true;
    _popCtrl.addStatusListener((s) {
      if (s == AnimationStatus.dismissed) {
        _popIndex = -1;
        if (mounted) setState(() {});
      }
    });
    if (MediaQuery.of(context).disableAnimations) {
      _ctrl.value = 1.0;
    } else {
      _ctrl.forward();
    }
  }

  @override
  void didUpdateWidget(covariant DonutChart old) {
    super.didUpdateWidget(old);
    if (old.totalCents != widget.totalCents ||
        old.slices.length != widget.slices.length) {
      // 数据切换时**不清空重画**：progress 保持 1，各扇区直接从旧占比变到新占比。
      // 只把「选中弹出」状态收掉，避免弹出块还挂在旧下标上。
      _selected = -1;
      _popIndex = -1;
      _popCtrl.value = 0;
    }
  }

  int get _displayCents => (_progress.value * widget.totalCents).round();

  void _onTap(Offset pos) {
    final hit = _hitSlice(pos);
    if (hit == -1) {
      if (_selected != -1) {
        _selected = -1;
        _popCtrl.reverse();
        setState(() {});
      }
      return;
    }
    if (hit == _selected) {
      _selected = -1;
      _popCtrl.reverse();
    } else {
      _popIndex = hit;
      _selected = hit;
      _popCtrl.forward(from: 0);
    }
    setState(() {});
  }

  int _hitSlice(Offset pos) {
    final center = Offset(widget.size / 2, widget.size / 2);
    final d = (pos - center).distance;
    const stroke = 16.0;
    final band = widget.size / 2 - stroke;
    if (d < band - stroke / 2 || d > band + stroke / 2) return -1;
    final total = widget.totalCents;
    if (total <= 0) return -1;
    var a = (pos - center).direction + math.pi / 2;
    if (a < 0) a += 2 * math.pi;
    if (a >= 2 * math.pi) a -= 2 * math.pi;
    var start = 0.0;
    for (var i = 0; i < widget.slices.length; i++) {
      final sweep = (widget.slices[i].cents / total) * 2 * math.pi;
      if (sweep <= 0) continue;
      if (a >= start && a < start + sweep) return i;
      start += sweep;
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    final colors = <Color>[
      for (var i = 0; i < widget.slices.length; i++)
        kSliceColors[i % kSliceColors.length],
    ];
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _onTap(d.localPosition),
            child: AnimatedBuilder(
              animation: Listenable.merge([_progress, _pop]),
              builder: (context, _) => CustomPaint(
                size: Size.square(widget.size),
                painter: _DonutPainter(
                  values: widget.slices.map((s) => s.cents).toList(),
                  total: widget.totalCents,
                  colors: colors,
                  track: Palette.hairline(context),
                  progress: _progress.value,
                  popIndex: _popIndex,
                  pop: _pop.value,
                  selected: _selected,
                ),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.hideAmounts
                    ? '****'
                    : '${widget.symbol}${centsToText(_displayCents)}',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Palette.ink(context),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(widget.centerTitle,
                  style: TextStyle(
                      fontSize: 11, color: Palette.inkFaint(context))),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _popCtrl.dispose();
    super.dispose();
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({
    required this.values,
    required this.total,
    required this.colors,
    required this.track,
    required this.progress,
    this.popIndex = -1,
    this.pop = 0.0,
    this.selected = -1,
  });

  final List<int> values;
  final int total;
  final List<Color> colors;
  final Color track;
  final double progress;
  final int popIndex;
  final double pop;
  final int selected;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final center = Offset(size.width / 2, size.height / 2);
    final baseR = size.width / 2 - stroke / 2;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawCircle(center, baseR, trackPaint);

    if (total <= 0) return;

    final n = values.length;
    final stagger = 0.09;
    final denom = (1 - (n - 1) * stagger).clamp(0.15, 1.0);
    var start = -math.pi / 2;
    for (var i = 0; i < n; i++) {
      final full = (values[i] / total) * 2 * math.pi;
      if (full <= 0) continue;
      final local = ((progress - i * stagger) / denom).clamp(0.0, 1.0);
      if (local <= 0) {
        start += full;
        continue;
      }
      final sweep = full * local;
      final isPop = i == popIndex;
      final offset = isPop ? pop * 6.0 : 0.0;
      final sW = isPop ? stroke + pop * 4.0 : stroke;
      final alpha = (selected >= 0 && i != selected) ? (1 - 0.5 * pop) : 1.0;
      final arcRect = Rect.fromCircle(
        center: center,
        radius: baseR + offset - sW / 2,
      );
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = sW
        ..strokeCap = StrokeCap.butt
        ..color = colors[i].withValues(alpha: alpha);
      canvas.drawArc(arcRect, start, sweep, false, paint);
      start += full;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.total != total ||
      old.track != track ||
      old.progress != progress ||
      old.pop != pop ||
      old.selected != selected ||
      old.popIndex != popIndex ||
      !_sameList(old.values, values) ||
      !_sameList(old.colors, colors);

  static bool _sameList<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// 每日支出柱图（当月）。
class DailyBars extends StatelessWidget {
  const DailyBars({
    super.key,
    required this.month,
    required this.daily,
    this.height = 120,
  });

  final DateTime month;
  final Map<String, int> daily;
  final double height;

  @override
  Widget build(BuildContext context) {
    final days = daysInMonth(month);
    final values = List<int>.generate(days, (i) {
      final key = dayKey(DateTime(month.year, month.month, i + 1));
      return daily[key] ?? 0;
    });
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _BarsPainter(
          values: values,
          bar: Theme.of(context).colorScheme.primary,
          empty: Palette.hairline(context),
          todayIndex: (month.year == DateTime.now().year &&
                  month.month == DateTime.now().month)
              ? DateTime.now().day - 1
              : -1,
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.values,
    required this.bar,
    required this.empty,
    required this.todayIndex,
  });

  final List<int> values;
  final Color bar;
  final Color empty;
  final int todayIndex;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final maxValue = values.fold<int>(0, math.max);
    final slot = size.width / values.length;
    final barWidth = math.max(2.0, slot * 0.62);
    for (var i = 0; i < values.length; i++) {
      final cx = slot * (i + 0.5);
      // 没记录的日子画一条极矮的底色，让节奏感一致
      final ratio = maxValue == 0 ? 0.0 : values[i] / maxValue;
      final h = maxValue == 0
          ? 2.0
          : (ratio * (size.height - 4)).clamp(2.0, size.height);
      final rect = Rect.fromLTWH(
        cx - barWidth / 2,
        size.height - h,
        barWidth,
        h,
      );
      final paint = Paint()
        ..color = values[i] == 0
            ? empty
            : bar.withValues(alpha: i == todayIndex ? 1 : 0.75);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(3)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) =>
      old.todayIndex != todayIndex ||
      old.bar != bar ||
      !_same(old.values, values);

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
