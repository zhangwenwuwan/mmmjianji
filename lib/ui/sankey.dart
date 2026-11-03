import 'app_glyph.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 三列桑基图：**钱从哪来 → 本月水池 → 钱到哪去**。
///
/// 为什么自己做而不是找库：桑基要的是「带子粗细 = 金额比例」这一件事，
/// 第三方包动辄几百 KB，还没法跟着 App 的配色/暗色模式走。这里 300 行
/// 自绘，靠的是两个初中的几何事实：
/// - 每列的节点高度按金额比例分配（带最小高度，否则 1% 的分类看不见）；
/// - 带子的两端高度相等，用两段三次贝塞尔连起来，视觉上就是「流量守恒」。
///
/// 两处刻意的取舍：
/// 1. **只画三列**，不画「来源×去向」全连接。全连接 n×m 条带子在小屏上
///    是毛线团，看不出任何比例；三列能一眼读出「进来多少、出去多少、剩多少」。
/// 2. **点节点高亮**。分类多的时候带子重叠，靠颜色区分不够，点一下其余变淡
///    比加图例有效。
class SankeyChart extends StatefulWidget {
  const SankeyChart({
    super.key,
    required this.sources,
    required this.sinks,
    required this.symbol,
    this.hideAmounts = false,
  });

  /// 左列：收入来源（含「存款补足」兜底）
  final List<SankeyFlow> sources;

  /// 右列：支出去向 + 结余
  final List<SankeyFlow> sinks;
  final String symbol;
  final bool hideAmounts;

  @override
  State<SankeyChart> createState() => _SankeyChartState();
}

class _SankeyChartState extends State<SankeyChart>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  /// 选中的节点：side 0 = 左（来源），1 = 右（去向）
  int? _selSide;
  int? _selIndex;

  _SankeyLayout? _layout;

  @override
  void initState() {
    super.initState();
    _c.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 尊重系统「减少动态效果」：直接画完，不做生长动画
    if (MediaQuery.of(context).disableAnimations) _c.value = 1;
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _toggle(_SNode? n) {
    setState(() {
      if (n == null || (_selSide == n.side && _selIndex == n.index)) {
        _selSide = null;
        _selIndex = null;
      } else {
        _selSide = n.side;
        _selIndex = n.index;
      }
    });
  }

  _SNode? _hit(Offset p) {
    final layout = _layout;
    if (layout == null) return null;
    for (final n in layout.nodes) {
      // 标签也算命中区：节点只有 9dp 宽，手指点不中；
      // 左边节点把左边整块（含标签）都算上，右边同理。
      final r = n.side == 0
          ? Rect.fromLTRB(0, n.rect.top, n.rect.right, n.rect.bottom)
          : Rect.fromLTRB(n.rect.left, n.rect.top, double.infinity,
              n.rect.bottom);
      if (r.contains(p)) return n;
    }
    return null;
  }

  /// 当前选中的节点（sources / sinks 里的那一项）
  SankeyFlow? get _selectedFlow {
    if (_selSide == null || _selIndex == null) return null;
    final list = _selSide == 0 ? widget.sources : widget.sinks;
    if (_selIndex! < 0 || _selIndex! >= list.length) return null;
    return list[_selIndex!];
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        final layout = _buildLayout(
          width: cons.maxWidth,
          sources: widget.sources,
          sinks: widget.sinks,
        );
        _layout = layout;
        final sel = _selectedFlow;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _toggle(_hit(d.localPosition)),
              child: AnimatedBuilder(
                animation: _c,
                builder: (context, _) => CustomPaint(
                  size: Size(cons.maxWidth, layout.height),
                  painter: _SankeyPainter(
                    layout: layout,
                    t: Curves.easeOutCubic.transform(_c.value),
                    selSide: _selSide,
                    selIndex: _selIndex,
                    symbol: widget.symbol,
                    hideAmounts: widget.hideAmounts,
                    ink: Palette.ink(context),
                    faint: Palette.inkFaint(context),
                    poolColor: Palette.brand(context),
                  ),
                ),
              ),
            ),
            // 卡片右上角写着「点节点看流向」，但以前点了只是把别的节点变淡，
            // 既不出数值也不出占比。这里补一条读数。
            if (sel != null) ...[
              const SizedBox(height: 6),
              _readout(context, sel),
            ],
          ],
        );
      },
    );
  }

  Widget _readout(BuildContext context, SankeyFlow flow) {
    final list = _selSide == 0 ? widget.sources : widget.sinks;
    final sideTotal = list.fold<int>(0, (s, f) => s + f.cents);
    final pct =
        sideTotal <= 0 ? 0 : (flow.cents / sideTotal * 100).round();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Palette.paper(context),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text('${glyphLabel(flow.glyph)} ${flow.label}',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Palette.ink(context))),
          const SizedBox(width: 8),
          Text(
            '${widget.hideAmounts ? '****' : '${widget.symbol}${centsToText(flow.cents)}'}'
            ' · 占${_selSide == 0 ? '流入' : '流出'} $pct%',
            style: TextStyle(fontSize: 12, color: Palette.inkSoft(context)),
          ),
          const Spacer(),
          Text('再点一次收起',
              style: TextStyle(fontSize: 10.5, color: Palette.inkFaint(context))),
        ],
      ),
    );
  }

  _SankeyLayout _buildLayout({
    required double width,
    required List<SankeyFlow> sources,
    required List<SankeyFlow> sinks,
  }) {
    final rows = math.max(sources.length, sinks.length);
    final height = (rows * 34.0 + 26).clamp(180.0, 320.0).toDouble();
    final labelW = math.min(width * 0.27, 86.0);
    const nodeW = 9.0;
    const gap = 8.0;
    final leftX = labelW + 4;
    final midX = (width - nodeW) / 2;
    final rightX = width - labelW - 4 - nodeW;

    final lh = _stack([for (final s in sources) s.cents], height, gap);
    final rh = _stack([for (final s in sinks) s.cents], height, gap);

    final nodes = <_SNode>[];

    // 左列
    var y = 0.0;
    final leftNodes = <_SNode>[];
    for (var i = 0; i < sources.length; i++) {
      final r = Rect.fromLTWH(leftX, y, nodeW, lh[i]);
      final n = _SNode(
        flow: sources[i],
        // 2026-10-28：跟分类名取固定色（原来按 i 取 kSliceColors，
        // 排名一变颜色就变，和流水行/环形图对不上）。
        color: Palette.categoryColor(context, sources[i].label),
        side: 0,
        index: i,
        rect: r,
      );
      leftNodes.add(n);
      nodes.add(n);
      y += lh[i] + gap;
    }
    final leftSum = sources.isEmpty
        ? 0.0
        : lh.fold<double>(0, (s, v) => s + v);

    // 右列
    y = 0.0;
    final rightNodes = <_SNode>[];
    for (var i = 0; i < sinks.length; i++) {
      final r = Rect.fromLTWH(rightX, y, nodeW, rh[i]);
      final n = _SNode(
        flow: sinks[i],
        color: Palette.categoryColor(context, sinks[i].label),
        side: 1,
        index: i,
        rect: r,
      );
      rightNodes.add(n);
      nodes.add(n);
      y += rh[i] + gap;
    }
    final rightSum =
        sinks.isEmpty ? 0.0 : rh.fold<double>(0, (s, v) => s + v);

    final poolH = math.max(leftSum, rightSum);
    final pool = Rect.fromLTWH(midX, 0, nodeW, math.max(poolH, 1));

    final links = <_SLink>[];
    // 左 → 水池
    var acc = 0.0;
    for (var i = 0; i < leftNodes.length; i++) {
      final h = leftNodes[i].rect.height;
      links.add(_SLink(
        a: _Seg(leftX + nodeW, leftNodes[i].rect.top, leftNodes[i].rect.bottom),
        b: _Seg(midX, acc, acc + h),
        color: leftNodes[i].color,
        side: 0,
        index: i,
      ));
      acc += h;
    }
    // 水池 → 右
    acc = 0.0;
    for (var i = 0; i < rightNodes.length; i++) {
      final h = rightNodes[i].rect.height;
      links.add(_SLink(
        a: _Seg(midX + nodeW, acc, acc + h),
        b: _Seg(rightNodes[i].rect.left, rightNodes[i].rect.top,
            rightNodes[i].rect.bottom),
        color: rightNodes[i].color,
        side: 1,
        index: i,
      ));
      acc += h;
    }

    return _SankeyLayout(
      nodes: nodes,
      links: links,
      pool: pool,
      height: height,
      labelWidth: labelW,
    );
  }
}

// ---------------------------------------------------------------- 布局模型

class _Seg {
  const _Seg(this.x, this.y0, this.y1);
  final double x;
  final double y0;
  final double y1;
  double get h => y1 - y0;
  double get cy => (y0 + y1) / 2;

  /// 按动画进度 t 缩放厚度（以中线为基准），做出「带子从中间长出来」的效果。
  _Seg scaled(double t) {
    final hh = h * t;
    return _Seg(x, cy - hh / 2, cy + hh / 2);
  }
}

class _SNode {
  _SNode({
    required this.flow,
    required this.color,
    required this.side,
    required this.index,
    required this.rect,
  });
  final SankeyFlow flow;
  final Color color;
  final int side;
  final int index;
  final Rect rect;
}

class _SLink {
  const _SLink({
    required this.a,
    required this.b,
    required this.color,
    required this.side,
    required this.index,
  });
  final _Seg a;
  final _Seg b;
  final Color color;
  final int side;
  final int index;
}

class _SankeyLayout {
  const _SankeyLayout({
    required this.nodes,
    required this.links,
    required this.pool,
    required this.height,
    required this.labelWidth,
  });
  final List<_SNode> nodes;
  final List<_SLink> links;
  final Rect pool;
  final double height;
  final double labelWidth;
}

/// 按金额比例分配高度，并保证：
/// - 总和不超过可用高度（留给节点间空隙）；
/// - 再小的分类也有 [minH] 的可点高度，否则占比 1% 的分类在屏幕上不存在。
List<double> _stack(List<int> values, double h, double gap) {
  final n = values.length;
  if (n == 0) return const [];
  final avail = math.max(h - gap * (n - 1), n * 6.0);
  final total = values.fold<int>(0, (s, v) => s + v);
  if (total <= 0) return List.filled(n, avail / n);

  const minH = 10.0;
  var heights = [for (final v in values) avail * v / total];
  for (var pass = 0; pass < 4; pass++) {
    final clamped = [for (final v in heights) v < minH ? minH : v];
    final sum = clamped.fold<double>(0, (s, v) => s + v);
    if ((sum - avail).abs() < 0.6) return clamped;
    if (sum > avail) {
      // 超了：从「没被抬到底线」的节点里按比例扣
      final free = clamped.fold<double>(0, (s, v) => v > minH ? s + v : s);
      if (free <= minH) return clamped;
      final over = sum - avail;
      heights = [
        for (var i = 0; i < n; i++)
          clamped[i] > minH ? clamped[i] - over * clamped[i] / free : clamped[i]
      ];
    } else {
      // 还有富余：整体按比例放大
      final grow = (avail - sum) / sum;
      heights = [for (final v in clamped) v * (1 + grow)];
      return heights;
    }
  }
  return heights;
}

// ---------------------------------------------------------------- 绘制

class _SankeyPainter extends CustomPainter {
  _SankeyPainter({
    required this.layout,
    required this.t,
    required this.selSide,
    required this.selIndex,
    required this.symbol,
    required this.hideAmounts,
    required this.ink,
    required this.faint,
    required this.poolColor,
  });

  final _SankeyLayout layout;
  final double t;
  final int? selSide;
  final int? selIndex;
  final String symbol;
  final bool hideAmounts;
  final Color ink;
  final Color faint;
  final Color poolColor;

  bool _hot(int side, int index) =>
      selSide == null || (selSide == side && selIndex == index);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    // 1) 带子
    for (final l in layout.links) {
      final a = l.a.scaled(t);
      final b = l.b.scaled(t);
      if (a.h <= 0.2) continue;
      final alpha = selSide == null ? 0.34 : (_hot(l.side, l.index) ? 0.62 : 0.07);
      paint.color = l.color.withValues(alpha: alpha);
      canvas.drawPath(_ribbon(a, b), paint);
    }

    // 2) 水池
    paint.color = poolColor.withValues(alpha: selSide == null ? 0.9 : 0.35);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(layout.pool.left, 0, layout.pool.width,
            layout.pool.height * t),
        const Radius.circular(3),
      ),
      paint,
    );

    // 3) 节点 + 标签
    // 标签避让：上一行标签的底部。小节点挨得近，不做避让会糊成一团。
    var lastLeftBottom = double.negativeInfinity;
    var lastRightBottom = double.negativeInfinity;
    for (final n in layout.nodes) {
      final dim = selSide != null && !(n.side == selSide && n.index == selIndex);
      paint.color = n.color.withValues(alpha: dim ? 0.35 : 1);
      final r = Rect.fromLTWH(n.rect.left, n.rect.top, n.rect.width,
          math.max(2, n.rect.height * t));
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(3)),
        paint,
      );
      final bottom = _label(
          canvas, n, dim, n.side == 0 ? lastLeftBottom : lastRightBottom);
      if (n.side == 0) {
        if (bottom > lastLeftBottom) lastLeftBottom = bottom;
      } else {
        if (bottom > lastRightBottom) lastRightBottom = bottom;
      }
    }
  }

  /// 一条带子：两端各一段竖边，用两段三次贝塞尔连起来。
  Path _ribbon(_Seg a, _Seg b) {
    final cx = (a.x + b.x) / 2;
    return Path()
      ..moveTo(a.x, a.y0)
      ..cubicTo(cx, a.y0, cx, b.y0, b.x, b.y0)
      ..lineTo(b.x, b.y1)
      ..cubicTo(cx, b.y1, cx, a.y1, a.x, a.y1)
      ..close();
  }

  /// 画节点标签，返回这条标签的底部 y（给下一条做避让）。
  ///
  /// 以前 `h * t < 7` 直接 return —— 高度不足 7dp 的节点**连名字都不画**，
  /// 用户看到一排无名彩色方块（「结余」和小额分类特别容易中招）。
  /// 现在只要节点有 1dp 就画名字（金额仍然要 ≥30dp 才画，两行塞不下），
  /// 挨得太近的标签跳过而不是叠在一起。
  double _label(Canvas canvas, _SNode n, bool dim, double minTop) {
    final h = n.rect.height;
    if (h * t < 1) return double.negativeInfinity;
    final two = h >= 30 && h * t >= 26;
    final color = dim ? faint.withValues(alpha: 0.5) : ink;

    final name = TextPainter(
      text: TextSpan(
        text: '${glyphLabel(n.flow.glyph)} ${n.flow.label}',
        style: TextStyle(
          fontSize: 10.5,
          height: 1.25,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: layout.labelWidth - 2);

    final money = TextPainter(
      text: TextSpan(
        text: hideAmounts
            ? '$symbol***'
            : '$symbol${centsToText(n.flow.cents)}',
        style: TextStyle(fontSize: 10.5, height: 1.3, color: faint),
      ),
      maxLines: 1,
      ellipsis: '…',
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: layout.labelWidth - 2);

    final blockH = two ? name.height + money.height : name.height;
    final cy = n.rect.top + h / 2;
    final top = cy - blockH / 2;
    // 会和上一条标签叠在一起就不画（宁可少一个名字，也不要糊成一片）
    if (top < minTop) return minTop;

    if (n.side == 0) {
      // 左列：右对齐贴着节点
      final x = n.rect.left - 6;
      name.paint(canvas, Offset(x - name.width, top));
      if (two) money.paint(canvas, Offset(x - money.width, top + name.height));
    } else {
      final x = n.rect.right + 6;
      name.paint(canvas, Offset(x, top));
      if (two) money.paint(canvas, Offset(x, top + name.height));
    }
    return top + blockH;
  }

  @override
  bool shouldRepaint(_SankeyPainter old) =>
      old.t != t ||
      old.selSide != selSide ||
      old.selIndex != selIndex ||
      old.layout != layout ||
      old.symbol != symbol ||
      old.hideAmounts != hideAmounts;
}

/// 统计页里的「钱从哪来，到哪去」卡。数据口在 [sankeyProvider]。
class SankeyPanel extends ConsumerWidget {
  const SankeyPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sankeyProvider);
    final settings = ref.watch(settingsProvider);

    return Panel(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('钱从哪来，到哪去',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Palette.ink(context))),
              const Spacer(),
              Text('点节点看流向',
                  style: TextStyle(
                      fontSize: 10.5, color: Palette.inkFaint(context))),
            ],
          ),
          const SizedBox(height: 10),
          async.when(
            skipLoadingOnReload: true,
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Skeleton(height: 180, radius: 10),
            ),
            error: (e, _) => ErrorRetryView(
              message: '流向图算不出来',
              detail: '$e',
              onRetry: () async => ref.invalidate(sankeyProvider),
            ),
            data: (d) {
              if (d.sources.isEmpty && d.sinks.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 34),
                  child: Center(
                    child: Text('这个区间还没有收支，画不出流向',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SankeyChart(
                    sources: d.sources,
                    sinks: d.sinks,
                    symbol: settings.symbol,
                    hideAmounts: settings.hideAmounts,
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        '流入 ${settings.symbol}${centsToText(d.income)}'
                        ' · 流出 ${settings.symbol}${centsToText(d.expense)}',
                        style: TextStyle(
                            fontSize: 10.5, color: Palette.inkFaint(context)),
                      ),
                      const Spacer(),
                      Text(
                        d.income == d.expense
                            ? '刚好花光'
                            : (d.income > d.expense ? '存下' : '超支'),
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: d.income > d.expense
                              ? Palette.income
                              : (d.income == d.expense
                                  ? Palette.inkSoft(context)
                                  : Palette.expense),
                        ),
                      ),
                      if (d.income != d.expense)
                        Text(
                          ' ${settings.symbol}${centsToText((d.income - d.expense).abs())}',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: d.income > d.expense
                                ? Palette.income
                                : Palette.expense,
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}
