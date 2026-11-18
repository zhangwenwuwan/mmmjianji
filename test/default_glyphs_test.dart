import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jianji/core/glyphs.dart';
import 'package:jianji/ui/account_edit_page.dart';
import 'package:jianji/ui/app_glyph.dart';

/// 图标清单的护栏。
///
/// 1.4.73 起不再用 emoji，而是设计师画的 PNG（`ic:` 前缀，见 core/glyphs.dart）。
/// 这里钉住三件事：
///   1. 清单不重复（重复了等于白占一格）；
///   2. **每个 id 都真有一个能加载的 PNG**（漏打包 / 拼错文件名在 UI 上只表现为
///      一个空白格，肉眼很容易滑过去，所以放到测试里挡）；
///   3. 账户图标栏确实覆盖了「新增账户」里能建的全部类型。
void main() {
  const allIds = [
    ...kOutGlyphIds,
    ...kInGlyphIds,
    ...kAccountGlyphIds,
  ];

  group('图标清单', () {
    test('支出 9 / 收入 5 / 账户 11，且同一组内不重复', () {
      expect(kOutGlyphIds.length, 9, reason: '4 列网格刚好两行 + 一个「其他」');
      expect(kInGlyphIds.length, 5);
      expect(kAccountGlyphIds.length, 11);
      for (final list in [kOutGlyphIds, kInGlyphIds, kAccountGlyphIds]) {
        expect(list.toSet().length, list.length, reason: '别放重复的图标');
      }
    });

    test('账户图标栏就是那 11 个 id（顺序跟类型选择器一致）', () {
      expect(AccountEditPage.glyphs,
          [for (final id in kAccountGlyphIds) Glyphs.of(id)]);
    });

    test('每个 id 都有对应的 emoji 兜底（桑基图/图例只能放文字）', () {
      for (final id in allIds) {
        expect(kGlyphEmoji[id], isNotNull, reason: '$id 缺文字替代');
        expect(kGlyphEmoji[id]!.trim(), isNotEmpty);
      }
    });
  });

  group('图标资源', () {
    testWidgets('每个图标 id 都能从包内加载出来', (tester) async {
      for (final id in allIds) {
        final data = await rootBundle.load('assets/icons/$id.png');
        // 小于 1KB 基本等于图被压没了 / 换成了占位图
        expect(data.lengthInBytes, greaterThan(1000),
            reason: 'assets/icons/$id.png 太小，可能不是有效图');
      }
    });

    testWidgets('渲染成 36 的方框不报错（含老 emoji 数据的兼容）', (tester) async {
      for (final glyph in [
        Glyphs.of('out_food'),
        Glyphs.of('acc_custom_credit'),
        '🍜', // 老数据：升级后必须还能画
      ]) {
        await tester.pumpWidget(MaterialApp(
          home: Center(child: AppGlyph(glyph, size: 36)),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$glyph 渲染抛异常');
      }
    });
  });
}
