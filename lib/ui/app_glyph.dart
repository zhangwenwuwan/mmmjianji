import 'dart:io';

import 'package:flutter/material.dart';

import '../core/glyphs.dart';
import '../services/icon_service.dart';

/// 分类 / 账户 / 愿望 / 账本的图标。
///
/// **全 App 统一用它渲染图标，不要再直接 `Text(x.glyph)`** ——
/// 2026-10-25 之后图标可以是「相册里选的自定义图片」，
/// 直接当文字画会显示成一串 "img:xxx.jpg"。
///
/// 三个分支：
/// - emoji（老数据）：照旧用 Text 画；
/// - 自定义图片：圆角方形图片；
/// - 图片读不到（文件被清、恢复备份没带 icons 目录）：回退 [fallback]，
///   **不留破图**。
class AppGlyph extends StatelessWidget {
  const AppGlyph(
    this.glyph, {
    super.key,
    this.size = 18,
    this.fallback = '🧾',
    this.fill = false,
    this.radius,
  });

  final String glyph;
  final double size;

  /// **铺满父容器**。
  ///
  /// 2026-10-26 用户反馈「自定义图标只占图标中间很小一部分」：
  /// emoji 是按 `fontSize: size` 画的，而自定义图片是按 `size × size`
  /// 画的正方形 —— 在 36~38pt 的图标格子里，一个 19pt 的图就是中间一小块。
  ///
  /// 打开 [fill] 后图片改用 `SizedBox.expand` 撑满格子（像 App 图标那样）。
  /// ⚠️ 只在**有固定尺寸的容器**里开（图标格、预览卡、分类头像），
  /// 放到 ListTile.leading 那种"高度有界、宽度无界"的位置会把图拉变形。
  final bool fill;
  final double? radius;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    // 内置图标（设计师画的 PNG）：保持原始宽高比，**不裁圆角**。
    //
    // 这些图是「物体插画」（碗、车、卡），内容只占画布 40%~100%，
    // 裁圆角会把接近满画布的卡类图标切掉四角；用 contain 让留白自然存在，
    // 视觉大小由设计时的构图决定（所有图都是居中构图，已核对过）。
    if (Glyphs.isIcon(glyph)) {
      final img = Image.asset(
        Glyphs.assetPath(glyph),
        width: fill ? null : size,
        height: fill ? null : size,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _fallbackText(),
      );
      return fill ? SizedBox.expand(child: img) : img;
    }
    if (!IconService.isImage(glyph)) {
      return Text(glyph, style: TextStyle(fontSize: size));
    }
    return FutureBuilder<String?>(
      future: IconService.resolve(glyph),
      builder: (context, snap) {
        final path = snap.data;
        if (path == null) {
          return SizedBox(width: size, height: size, child: _fallbackText());
        }
        final r = radius ?? size * 0.28;
        final img = Image.file(
          File(path),
          // fill：交给父容器的约束（BoxFit.cover 保证不变形）
          width: fill ? null : size,
          height: fill ? null : size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _fallbackText(),
        );
        return ClipRRect(
          borderRadius: BorderRadius.circular(r),
          child: fill ? SizedBox.expand(child: img) : img,
        );
      },
    );
  }

  Widget _fallbackText() => Text(fallback, style: TextStyle(fontSize: size));
}

/// 把图标字段转成**可以放进文字里**的短标签。
///
/// 有些地方只能放纯字符串（下拉项的 label、统计图的图例、桑基图标签）。
/// 内置 PNG 图标没法用文字表示，回退成对应的 emoji；自定义图片同理用 📷 占位。
/// **绝不能把 `ic:out_food` / `img:xxx.jpg` 这种内部标识漏到界面上。**
String glyphLabel(String glyph) {
  if (Glyphs.isIcon(glyph)) {
    return kGlyphEmoji[Glyphs.idOf(glyph)] ?? '•';
  }
  return IconService.isImage(glyph) ? '📷' : glyph;
}
