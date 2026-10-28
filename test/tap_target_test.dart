import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/main.dart';
import 'package:jianji/ui/budget_page.dart';
import 'package:jianji/ui/common.dart';
import 'package:jianji/ui/home_modules_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 2026-10-28 打磨两件事的回归测试：
///
/// 1. **点击区**：原来一批「管理 / 立即备份 / 查看 / 去设置」都是
///    `TextButton + minimumSize(0,0) + shrinkWrap`，实际只有 20dp 出头。
///    手指点不准不是"偶发 bug"，而是尺寸不达标 —— 这里把 48dp 钉死。
/// 2. **首页模块入口**：1.4.9 删了入口却留着页面，`settings.modulesOrder` /
///    `homeHidden` 一直在被首页消费，用户却没有地方改。入口接回来后
///    必须真的能走进去，否则又是"看着有线、点不进去"。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});
  });

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> boot(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(const ProviderScope(child: JianjiApp()));
    await settle(tester, rounds: 12);
    // 启动幕：呼吸 600 + 张开 700
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester, rounds: 6);
  }

  testWidgets('HeaderAction 的点击区不小于 48×48', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 160,
            child: SectionLabel(
              '目标',
              trailing: HeaderAction(label: '管理', onPressed: () {}),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    final size = tester.getSize(find.byType(HeaderAction));
    // Material 的最小可点尺寸是 48dp。低于它的按钮在真机上就是"点了没反应"。
    expect(size.width, greaterThanOrEqualTo(48.0),
        reason: '横向也要够 48：「管理」两个字只有 24dp 宽');
    expect(size.height, greaterThanOrEqualTo(48.0),
        reason: '纵向 48：原来 minimumSize(0,0) 只有 20dp 出头');
  });

  testWidgets('lib/ui 里不再有 minimumSize(0,0) 的零尺寸按钮', (tester) async {
    // 源码级防回归：这类"紧凑表头"最容易在下次改版时被重新复制一份。
    final dir = Directory('lib/ui');
    final offenders = <String>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final src = f.readAsStringSync();
      if (src.contains('minimumSize: const Size(0, 0)') ||
          src.contains('minimumSize: Size.zero')) {
        offenders.add(f.path);
      }
    }
    expect(offenders, isEmpty,
        reason: '这些文件里还有把按钮压到 0 尺寸的写法，改用 HeaderAction：$offenders');
  });

  testWidgets('外观与显示 → 首页模块，入口真的能进去', (tester) async {
    await boot(tester);

    // 我的 tab
    await tester.tap(find.text('我的').last);
    await settle(tester);

    // 常用网格里的「外观与显示」
    final appearance = find.text('外观与显示');
    expect(appearance, findsWidgets, reason: '「我的」页常用网格里应有外观入口');
    await tester.tap(appearance.first);
    await settle(tester, rounds: 10);

    expect(find.text('首页模块'), findsOneWidget, reason: '外观页里要有首页模块入口');
    await tester.tap(find.text('首页模块'));
    await settle(tester, rounds: 10);

    expect(find.byType(HomeModulesPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('首页提示卡整卡可点（点文字也能进预算页）', (tester) async {
    await boot(tester);

    final hint = find.text('设个月度预算，超支前会提醒你');
    expect(hint, findsOneWidget, reason: '全新库没设预算，这张卡应该在');

    // 点的是**文字**，不是原来那个 20dp 的小按钮 —— 整卡可点就是要让这里也生效
    await tester.tap(hint);
    await settle(tester, rounds: 10);
    expect(find.byType(BudgetPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
