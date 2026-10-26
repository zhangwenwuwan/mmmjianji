import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 从一张图片里提取「能给全 App 换肤」的主色。
///
/// 为什么自己写而不是加 `palette_generator`：
/// 1. 那个包会拖进 `flutter_image` 之类的传递依赖，包体涨；
/// 2. 我们只需要一个主色 + 一个亮度判断，不需要整套色板；
/// 3. 纯 Dart 实现可以直接对「像素数组」做单测，不用真解一张图。
///
/// 算法（比想象的朴素，但结果够用）：
/// - 采样上限 [_sampleBudget] 个像素，避免大图把手机烤热；
/// - 丢掉半透明、接近纯白、接近纯黑的像素（背景、留白、UI 白边）；
/// - 按色相分 [_hueBins] 个桶，按「饱和度 × 明度」加权投票；
/// - 取票数最高的桶，桶内按权重求平均色 —— 这一步比取中位数稳，
///   因为同一色相下深浅不一的像素本来就该混成一个代表色。
///
/// 注意：这是**审美判断**，不是精确的量化。用户在设置里随时可以关掉
/// 「跟随封面换肤」，所以这里不需要追求科研级的准确度。
class CoverPalette {
  const CoverPalette({
    required this.seed,
    required this.average,
    required this.luminance,
  });

  /// 用于 `ColorScheme.fromSeed` 的主色。
  final Color seed;

  /// 全部有效像素的平均色，给渐变遮罩做同色调过渡用。
  final Color average;

  /// 有效像素的平均亮度（0 = 全黑，1 = 全白）。
  final double luminance;

  /// 封面偏亮时，压在上面的文字要用深色，否则糊成一片。
  bool get prefersDarkText => luminance > 0.58;

  /// 遮罩不透明度：图越亮压得越狠，保证白字可读。
  /// 亮图 0.42 / 暗图 0.16，中间线性过渡。
  double get scrimOpacity {
    final v = ((luminance - 0.25) / 0.55).clamp(0.0, 1.0);
    return 0.16 + 0.26 * v;
  }

  @override
  String toString() =>
      'CoverPalette(seed: ${seed.toARGB32().toRadixString(16)}, '
      'lum: ${luminance.toStringAsFixed(2)}, darkText: $prefersDarkText)';
}

const int _sampleBudget = 20000;
const int _hueBins = 24;

/// 像素门槛：低于它就当"没颜色"。
const int _alphaFloor = 200;

/// 纯 Dart 版本：喂 `rawRgba` 字节数组（`ui.ImageByteFormat.rawRgba` 的格式，
/// 每像素 4 字节 R/G/B/A）。
///
/// 返回 null 表示整张图没有可用颜色（比如纯白截图、纯黑图），
/// 调用方应该保留原来的配色，而不是给一个随机色。
CoverPalette? paletteFromPixels(
  Uint8List rgba,
  int width,
  int height,
) {
  final pixelCount = width * height;
  if (pixelCount <= 0 || rgba.length < pixelCount * 4) return null;

  // 等距采样：步长取整，保证覆盖全图而不是只盯左上角。
  final step = math.max(1, (pixelCount / _sampleBudget).ceil());

  final binWeight = Float64List(_hueBins);
  final binR = Float64List(_hueBins);
  final binG = Float64List(_hueBins);
  final binB = Float64List(_hueBins);

  double sumR = 0, sumG = 0, sumB = 0, sumLum = 0;
  int used = 0;

  for (int i = 0; i < pixelCount; i += step) {
    final o = i * 4;
    final a = rgba[o + 3];
    if (a < _alphaFloor) continue;
    final r = rgba[o];
    final g = rgba[o + 1];
    final b = rgba[o + 2];

    final maxC = math.max(r, math.max(g, b)).toDouble();
    final minC = math.min(r, math.min(g, b)).toDouble();
    final delta = maxC - minC;

    // 跳过近白（留白 / 白卡片）与近黑（纯黑背景）
    if (minC > 238 && delta < 14) continue;
    if (maxC < 30) continue;

    final v = maxC / 255.0;
    final s = maxC <= 0 ? 0.0 : delta / maxC;

    sumR += r;
    sumG += g;
    sumB += b;
    sumLum += _relativeLuminance(r, g, b);
    used++;

    // 加权：颜色越鲜艳、越「有存在感」票越重；同时压一压极暗的色，
    // 否则一张夜景照片会抽出个几乎看不见的墨色当主题。
    final weight = (s * 0.7 + 0.3) * math.pow(v, 0.6);
    if (weight <= 0) continue;

    final bin = _hueBin(r, g, b, maxC, minC, delta);
    binWeight[bin] += weight;
    binR[bin] += r * weight;
    binG[bin] += g * weight;
    binB[bin] += b * weight;
  }

  if (used == 0) return null;

  final average = Color.fromARGB(
    255,
    (sumR / used).round(),
    (sumG / used).round(),
    (sumB / used).round(),
  );

  int bestBin = 0;
  for (int i = 1; i < _hueBins; i++) {
    if (binWeight[i] > binWeight[bestBin]) bestBin = i;
  }

  final Color seed;
  if (binWeight[bestBin] <= 0) {
    seed = average;
  } else {
    final w = binWeight[bestBin];
    seed = Color.fromARGB(
      255,
      (binR[bestBin] / w).round().clamp(0, 255),
      (binG[bestBin] / w).round().clamp(0, 255),
      (binB[bestBin] / w).round().clamp(0, 255),
    );
  }

  return CoverPalette(
    seed: _tuneForTheme(seed),
    average: average,
    luminance: sumLum / used,
  );
}

/// 色相分桶。灰色（delta 很小）单独走"低饱和"桶，避免它们随机
/// 散到各个色相里污染投票。
int _hueBin(int r, int g, int b, double maxC, double minC, double delta) {
  if (delta < 8) return 0; // 低饱和集中到 0 号桶
  double h;
  if (maxC == r) {
    h = ((g - b) / delta) % 6;
  } else if (maxC == g) {
    h = (b - r) / delta + 2;
  } else {
    h = (r - g) / delta + 4;
  }
  final deg = (h * 60 + 360) % 360;
  // 0 号桶被灰色占了，色相映射到 1.._hueBins-1
  final idx = 1 + (deg / (360 / (_hueBins - 1))).floor();
  return idx.clamp(1, _hueBins - 1);
}

/// WCAG 相对亮度，比简单平均更接近人眼感受。
double _relativeLuminance(int r, int g, int b) {
  double ch(int c) {
    final v = c / 255.0;
    return v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b);
}

/// 把抽出来的颜色调成适合当主题种子的状态。
///
/// 两个动作：
/// 1. **提一点饱和**：照片主色往往偏灰，直接当种子会得到一片灰蒙蒙的
///    界面（和之前 `tonalSpot` 把松石绿洗淡是同一类问题）。
/// 2. **锁一个明度区间**：太亮会让浅色模式下的文字对比度不够，太暗
///    又和深色模式糊在一起；统一压到 0.35~0.62 这段"中等偏深"。
Color _tuneForTheme(Color c) {
  final hsv = HSVColor.fromColor(c);
  final s = hsv.saturation < 0.30 ? 0.30 : hsv.saturation;
  final v = hsv.value.clamp(0.35, 0.62);
  return hsv
      .withSaturation(s.clamp(0.0, 0.92))
      .withValue(v)
      .toColor();
}

/// 解码图片字节并取色。给 UI 层用的入口。
///
/// `targetWidth: 96` 是关键：取色不需要原图精度，先让解码器缩到 96px 宽，
/// 既省内存又快（大图直接解到 rawRgba 可能几十 MB）。
Future<CoverPalette?> paletteFromImageBytes(Uint8List bytes) async {
  ui.Codec? codec;
  ui.Image? image;
  try {
    codec = await ui.instantiateImageCodec(bytes, targetWidth: 96);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    return paletteFromPixels(
      data.buffer.asUint8List(),
      image.width,
      image.height,
    );
  } catch (e) {
    debugPrint('封面取色失败: $e');
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
  }
}
