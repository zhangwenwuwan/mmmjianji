import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/glyphs.dart';
import 'package:jianji/ui/account_edit_page.dart';
import 'package:jianji/ui/app_glyph.dart';
import 'package:jianji/ui/common.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 「新增账户」进来的那个页面，图标必须一开始就是插画。
///
/// 2026-11-18 实机踩到：换完图标后从资产页点「新增账户」，左上角大徽标
/// 还是旧 emoji 💵 —— `initState` 里写死 `_glyph = p?.glyph ?? '💵'`，
/// 只有手动去「选择类型」才会被 `_applyType` 覆盖成 `ic:`。
/// 连带的第二个症状：图标选择器里会多出一格 💵（`_pickGlyph` 会把
/// 「不在插画清单里」的当前值前置），等于新旧图标混排。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> pumpNewAccount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AccountEditPage()),
    ));
    await settle(tester);
  }

  testWidgets('新建账户：页面上的图标都是插画，没有旧 emoji', (tester) async {
    await pumpNewAccount(tester);

    final shown = tester
        .widgetList<AppGlyph>(find.byType(AppGlyph))
        .map((w) => w.glyph)
        .toList();
    expect(shown, isNotEmpty, reason: '大徽标 + 「账户图标」行各画一个');
    for (final g in shown) {
      expect(Glyphs.isIcon(g), isTrue,
          reason: '新建账户默认图标必须是 ic: 插画，实际是「$g」'
              '（旧 emoji 说明 initState 又写死了默认值）');
    }
    expect(find.text('💵'), findsNothing);
  });

  testWidgets('图标选择器只有 11 个插画，不给旧 emoji 留格子', (tester) async {
    await pumpNewAccount(tester);

    await tester.tap(find.text('账户图标'));
    await settle(tester);
    await tester.pumpAndSettle();

    final picker = tester.widget<GlyphPicker>(find.byType(GlyphPicker));
    expect(picker.glyphs.length, kAccountGlyphIds.length);
    for (final g in picker.glyphs) {
      expect(Glyphs.isIcon(g), isTrue, reason: '选择器里混进了「$g」');
    }
    // 当前值必须在清单里，否则进来是「一个都没选中」的样子
    expect(picker.glyphs, contains(picker.value));
  });
}
