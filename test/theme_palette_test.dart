import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jianji/ui/theme.dart';

/// 配色方案的底线：**渐变上的字必须读得出来**。
///
/// 四套渐变里只有「极光油膜」是深底，其余三套（薄荷 / 薰衣草 / 蜜桃）
/// 都是浅色治愈渐变。之前首页大卡和资产页头部把前景色写死成白色，
/// 换成浅渐变后金额会直接消失 —— 这种 bug 只能靠测试钉住，
/// 因为它在薄荷主题下完全看不出来。
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('配色方案', () {
    test('四套方案 id 固定（老用户已存的 paletteId 不能失联）', () {
      expect(kPalettes.keys.toList(), ['teal', 'indigo', 'rose', 'ochre']);
      expect(kPalettes['teal']!.name, '草木薄荷', reason: '默认主题');
      for (final e in kPalettes.entries) {
        expect(e.value.gradient.length, greaterThanOrEqualTo(2),
            reason: '${e.key} 至少两段渐变');
        expect(e.value.name.isNotEmpty, isTrue);
      }
    });

    test('未知 paletteId 回落到默认主题，不崩', () {
      final t = buildTheme(Brightness.light, paletteId: 'not-exist');
      final pt = t.extension<AppPaletteTheme>();
      expect(pt, isNotNull);
      expect(pt!.gradient.colors.length, greaterThanOrEqualTo(2));
    });

    test('每套渐变的每一段，前景色对比度都 ≥ 4.5:1', () {
      for (final brightness in Brightness.values) {
        for (final id in kPalettes.keys) {
          final t = buildTheme(brightness, paletteId: id);
          final pt = t.extension<AppPaletteTheme>()!;
          for (final stop in pt.gradient.colors) {
            final ratio = _contrast(pt.onGradient, stop);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason: '$id / $brightness / $stop 上只有 '
                  '${ratio.toStringAsFixed(2)}:1',
            );
          }
        }
      }
    });

    test('深色模式会把渐变压暗，并换成白字', () {
      final light = buildTheme(Brightness.light, paletteId: 'teal')
          .extension<AppPaletteTheme>()!;
      final dark = buildTheme(Brightness.dark, paletteId: 'teal')
          .extension<AppPaletteTheme>()!;

      // 浅色下是深墨字（薄荷渐变太亮，白字会糊）
      expect(light.onGradient, const Color(0xFF14201B));
      // 深色下压暗成中深绿，字换成白的
      expect(dark.onGradient, Colors.white);
      for (var i = 0; i < light.gradient.colors.length; i++) {
        final l = light.gradient.colors[i].computeLuminance();
        final d = dark.gradient.colors[i].computeLuminance();
        expect(d, lessThan(l), reason: '深色模式必须更暗');
      }
    });

    test('主按钮走渐变：透明底 + backgroundBuilder', () {
      final style = buildTheme(Brightness.light, paletteId: 'rose')
          .filledButtonTheme
          .style!;
      expect(style.backgroundBuilder, isNotNull,
          reason: '没有 backgroundBuilder 就只是纯色按钮');
      expect(
        style.backgroundColor?.resolve(const <WidgetState>{}),
        Colors.transparent,
        reason: '不透明底会把渐变盖住',
      );
      expect(style.foregroundColor?.resolve(const <WidgetState>{}),
          const Color(0xFF14201B),
          reason: '薰衣草是浅渐变，按钮上的字必须是深墨');
    });
  });
}
