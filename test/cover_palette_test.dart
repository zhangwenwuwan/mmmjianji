import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/cover_palette.dart';

/// 取色器是「用户第一眼看到的东西」，不能靠肉眼看图判断对错。
/// 这里全部用合成像素跑：给定输入像素，主色必须落在预期色相区间内。
Uint8List rgba(List<List<int>> pixels) {
  final out = Uint8List(pixels.length * 4);
  for (var i = 0; i < pixels.length; i++) {
    final px = pixels[i];
    out[i * 4] = px[0];
    out[i * 4 + 1] = px[1];
    out[i * 4 + 2] = px[2];
    out[i * 4 + 3] = px.length > 3 ? px[3] : 255;
  }
  return out;
}

Uint8List solid(int r, int g, int b, {int count = 400, int alpha = 255}) =>
    rgba(List.generate(count, (_) => [r, g, b, alpha]));

void main() {
  group('主色提取', () {
    test('纯橙色图 → 抽出的主色是暖色（红>绿>蓝）', () {
      final p = paletteFromPixels(solid(230, 130, 40), 20, 20);
      expect(p, isNotNull);
      expect(p!.seed.r, greaterThan(p.seed.b));
      expect(p.seed.g, greaterThan(p.seed.b));
    });

    test('纯蓝图 → 主色是冷色（蓝最大）', () {
      final p = paletteFromPixels(solid(40, 90, 210), 20, 20);
      expect(p, isNotNull);
      expect(p!.seed.b, greaterThan(p.seed.r));
    });

    test('纯白图 → 返回 null（不能把整屏洗成白主题）', () {
      expect(paletteFromPixels(solid(255, 255, 255), 20, 20), isNull);
    });

    test('纯黑图 → 返回 null', () {
      expect(paletteFromPixels(solid(0, 0, 0), 20, 20), isNull);
    });

    test('全透明图 → 返回 null', () {
      expect(paletteFromPixels(solid(200, 60, 60, alpha: 0), 20, 20), isNull);
    });

    test('白底 + 少量蓝块 → 抽到蓝而不是白', () {
      final white = List.generate(360, (_) => [255, 255, 255, 255]);
      final blue = List.generate(40, (_) => [30, 80, 200, 255]);
      final p = paletteFromPixels(rgba([...white, ...blue]), 20, 20);
      expect(p, isNotNull);
      expect(p!.seed.b, greaterThan(p.seed.r));
    });

    test('主色明度被夹在 0.35~0.62（否则浅色模式对比度崩）', () {
      // 很浅的米黄：明度高，必须被压下来
      final p = paletteFromPixels(solid(245, 235, 215), 20, 20);
      expect(p, isNotNull);
      final v = HSVColor.fromColor(p!.seed).value;
      expect(v, lessThanOrEqualTo(0.63));
      expect(v, greaterThanOrEqualTo(0.34));
    });

    test('灰度图不会抽出离谱的色相（饱和度有下限，保持中性）', () {
      final p = paletteFromPixels(solid(120, 120, 120), 20, 20);
      // 120 灰能过白/黑门槛，会被采纳；但调色后饱和度为 0（灰）
      expect(p, isNotNull);
      expect(HSVColor.fromColor(p!.seed).saturation, lessThan(0.35));
    });
  });

  group('亮度判断（决定文字黑白与遮罩强度）', () {
    test('亮图 → 想要深色字，遮罩更重', () {
      final bright = paletteFromPixels(solid(215, 205, 195), 20, 20);
      expect(bright, isNotNull);
      expect(bright!.luminance, greaterThan(0.5));
      expect(bright.prefersDarkText, isTrue);
      expect(bright.scrimOpacity, greaterThan(0.25));
    });

    test('暗图 → 想要浅色字，遮罩更轻', () {
      final dark = paletteFromPixels(solid(40, 45, 55), 20, 20);
      expect(dark, isNotNull);
      expect(dark!.luminance, lessThan(0.35));
      expect(dark.prefersDarkText, isFalse);
      expect(dark.scrimOpacity, lessThan(0.30));
    });

    test('遮罩不透明度始终落在 0.16~0.42（太狠会把图压死）', () {
      for (final rgb in [
        [40, 45, 55],
        [120, 110, 100],
        [215, 205, 195],
      ]) {
        final p = paletteFromPixels(solid(rgb[0], rgb[1], rgb[2]), 10, 10);
        expect(p, isNotNull);
        expect(p!.scrimOpacity, greaterThanOrEqualTo(0.16));
        expect(p.scrimOpacity, lessThanOrEqualTo(0.42));
      }
    });
  });

  group('边界', () {
    test('空数组 / 尺寸为 0 → null，不抛异常', () {
      expect(paletteFromPixels(Uint8List(0), 0, 0), isNull);
      expect(paletteFromPixels(Uint8List(16), 2, 2), isNull);
    });

    test('大图按预算采样，不会因为像素多就变慢到不可用', () {
      // 4 万个像素，步长应大于 1；只需保证能出结果
      final p = paletteFromPixels(solid(200, 100, 60, count: 40000), 200, 200);
      expect(p, isNotNull);
    });
  });
}
