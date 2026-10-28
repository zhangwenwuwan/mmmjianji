import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/assets_page.dart';
import 'package:jianji/ui/goals_page.dart';
import 'package:jianji/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 2026-10-28：资产页原来有**两个入口指向同一个 GoalsPage** ——
/// 上面三宫格里的「理财」和页面底部整块「储蓄目标」。
/// 现在只留上面的，并且改名叫「目标」（页面标题也一起改）。
///
/// 这条测试钉两件事：底部那块不能再回来；上面那个入口的名字就是「目标」。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  testWidgets('资产页只有「目标」一个入口，底部「储蓄目标」那块已删', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const AssetsPage(),
      ),
    ));
    await settle(tester);

    // 三宫格第三张卡：报销 / 债务 / 目标
    expect(find.text('目标'), findsWidgets, reason: '三宫格里的目标卡要在');
    expect(find.text('理财'), findsNothing, reason: '不能还留着一个叫「理财」的重复入口');

    // 底部那块整块删掉：既没有标题，也没有「管理」按钮对应的 SectionLabel
    expect(find.text('储蓄目标'), findsNothing, reason: '底部「储蓄目标」区块已删，别加回来');
    expect(tester.takeException(), isNull);
  });

  testWidgets('目标页的标题也叫「目标」，和入口一致', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const GoalsPage(),
      ),
    ));
    await settle(tester, rounds: 6);

    expect(find.text('目标'), findsWidgets,
        reason: '点「目标」进来，标题不该还写着「储蓄目标」');
    expect(find.text('储蓄目标'), findsNothing);
  });
}
