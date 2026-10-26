import 'package:flutter/material.dart';

import 'theme.dart';

/// 极淡的山水 / 植物线描插画，用作卡片背景或空状态。
///
/// 参考版的设计语言是「大面积留白 + 一抹克制的线描」，所以这里全部用
/// 主色低透明度描边，不抢内容。

/// 远山 + 近坡 + 一株小植物：画在卡片右下角，作为「汇总大卡」的氛围背景。
class MountainPainter extends CustomPainter {
  const MountainPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final w = size.width;
    final h = size.height;

    // 远山（两段柔和的弧）
    final far = Path()
      ..moveTo(w * 0.42, h)
      ..quadraticBezierTo(w * 0.62, h * 0.46, w * 0.86, h * 0.72)
      ..quadraticBezierTo(w * 0.96, h * 0.82, w, h * 0.78);
    canvas.drawPath(far, paint);

    final near = Path()
      ..moveTo(w * 0.30, h)
      ..quadraticBezierTo(w * 0.52, h * 0.66, w * 0.74, h * 0.9)
      ..quadraticBezierTo(w * 0.86, h, w, h);
    canvas.drawPath(near, paint);

    // 一轮淡日
    canvas.drawCircle(Offset(w * 0.80, h * 0.30), h * 0.10, paint);

    // 一株小植物（茎 + 两片叶），落在左下
    final stem = Path()
      ..moveTo(w * 0.16, h * 0.98)
      ..quadraticBezierTo(w * 0.13, h * 0.74, w * 0.17, h * 0.58);
    canvas.drawPath(stem, paint);
    final leafL = Path()
      ..moveTo(w * 0.17, h * 0.66)
      ..quadraticBezierTo(w * 0.04, h * 0.60, w * 0.06, h * 0.50)
      ..quadraticBezierTo(w * 0.13, h * 0.56, w * 0.17, h * 0.66);
    canvas.drawPath(leafL, paint);
    final leafR = Path()
      ..moveTo(w * 0.17, h * 0.70)
      ..quadraticBezierTo(w * 0.30, h * 0.66, w * 0.30, h * 0.55)
      ..quadraticBezierTo(w * 0.23, h * 0.62, w * 0.17, h * 0.70);
    canvas.drawPath(leafR, paint);
  }

  @override
  bool shouldRepaint(covariant MountainPainter old) => old.color != color;
}

/// 把 [MountainPainter] 铺到卡片右下角（不挡文字）。
class HillCardBackground extends StatelessWidget {
  const HillCardBackground({super.key, required this.child, this.opacity = 0.16});

  final Widget child;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    final color = Palette.brand(context).withValues(alpha: opacity);
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CustomPaint(
              painter: MountainPainter(color: color),
              size: Size.infinite,
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// 线描空状态插画。
///
/// 三种：手持纸张（记一笔）、手托日历（看日历）、小盆栽（通用）。
class EmptyIllustration extends StatelessWidget {
  const EmptyIllustration({
    super.key,
    required this.kind,
    this.size = 96,
  });

  final EmptyKind kind;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = Palette.inkFaint(context);
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _EmptyPainter(kind: kind, color: color),
        size: Size(size, size),
      ),
    );
  }
}

enum EmptyKind { paper, calendar, plant }

class _EmptyPainter extends CustomPainter {
  const _EmptyPainter({required this.kind, required this.color});

  final EmptyKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final cx = s.width / 2;
    final cy = s.height / 2;

    if (kind == EmptyKind.calendar) {
      final w = s.width * 0.5;
      final h = s.height * 0.56;
      final x = cx - w / 2;
      final y = cy - h / 2;
      // 日历主体
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, w, h),
          const Radius.circular(8),
        ),
        paint,
      );
      // 顶部装订条
      canvas.drawLine(
        Offset(x, y + h * 0.22), Offset(x + w, y + h * 0.22), paint);
      // 两个装订环
      canvas.drawCircle(Offset(cx - w * 0.18, y), 4, paint);
      canvas.drawCircle(Offset(cx + w * 0.18, y), 4, paint);
      // 网格点（代表日期）
      for (var r = 0; r < 3; r++) {
        for (var c = 0; c < 4; c++) {
          final px = x + w * (0.18 + c * 0.21);
          final py = y + h * (0.42 + r * 0.18);
          canvas.drawCircle(Offset(px, py), 1.4, paint);
        }
      }
      return;
    }

    if (kind == EmptyKind.plant) {
      // 花盆
      final potW = s.width * 0.36;
      final potH = s.height * 0.22;
      final px = cx - potW / 2;
      final py = cy + s.height * 0.12;
      canvas.drawLine(
        Offset(px, py), Offset(px + potW, py), paint);
      canvas.drawLine(
        Offset(px + potW * 0.12, py),
        Offset(px + potW * 0.24, py + potH),
        paint);
      canvas.drawLine(
        Offset(px + potW * 0.88, py),
        Offset(px + potW * 0.76, py + potH),
        paint);
      // 茎
      final stemTop = Offset(cx, cy - s.height * 0.26);
      canvas.drawLine(Offset(cx, py), stemTop, paint);
      // 两片叶子
      final leafL = Path()
        ..moveTo(cx, cy - s.height * 0.04)
        ..quadraticBezierTo(cx - s.width * 0.22, cy - s.height * 0.10,
            cx - s.width * 0.20, cy - s.height * 0.22)
        ..quadraticBezierTo(cx - s.width * 0.06, cy - s.height * 0.10, cx,
            cy - s.height * 0.04);
      canvas.drawPath(leafL, paint);
      final leafR = Path()
        ..moveTo(cx, cy - s.height * 0.12)
        ..quadraticBezierTo(cx + s.width * 0.22, cy - s.height * 0.18,
            cx + s.width * 0.20, cy - s.height * 0.30)
        ..quadraticBezierTo(cx + s.width * 0.06, cy - s.height * 0.18, cx,
            cy - s.height * 0.12);
      canvas.drawPath(leafR, paint);
      return;
    }

    // paper：一张带横线的纸 + 一只手托着
    final w = s.width * 0.42;
    final h = s.height * 0.52;
    final x = cx - w / 2;
    final y = cy - h * 0.7;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, w, h),
        const Radius.circular(6),
      ),
      paint,
    );
    for (var i = 1; i <= 3; i++) {
      final ly = y + h * (i / 4);
      canvas.drawLine(
        Offset(x + w * 0.18, ly), Offset(x + w * 0.82, ly), paint);
    }
    // 手（简单的托举曲线）
    final hand = Path()
      ..moveTo(cx - w * 0.7, cy + h * 0.34)
      ..quadraticBezierTo(cx, cy + h * 0.74, cx + w * 0.7, cy + h * 0.34);
    canvas.drawPath(hand, paint);
  }

  @override
  bool shouldRepaint(covariant _EmptyPainter old) =>
      old.kind != kind || old.color != color;
}
