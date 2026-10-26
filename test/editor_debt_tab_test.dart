import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/editor_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 记账页第 4 个 tab「债务」。
///
/// 它和另外三个 tab 不是一回事：**不产生流水**（借出去的钱还没回来，
/// 不能算支出也不能算收入），所以重点是验证「切过去时金额面板必须让位」——
/// 面板浮在债务页上是这个 tab 最容易出的样子故障。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('债务 tab：给借贷入口，且不让一屏金额面板压在上面', (tester) async {
    // 记账页的高度预算是按真机（1080×2340）算的：默认 800×600 的假屏幕
    // 装不下「分类网格 + 金额面板」，会报 1px 溢出 —— 那是测试环境太小，不是页面坏了。
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: EntryEditorPage()),
    ));

    Future<void> waitForPanel() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 60));
        if (find.byKey(const Key('amount-display')).evaluate().isNotEmpty) {
          return;
        }
      }
      fail('一屏金额面板没有出现');
    }

    await waitForPanel();

    // 四个 tab 都在
    for (final label in const ['支出', '收入', '转账', '债务']) {
      expect(find.text(label), findsOneWidget, reason: '缺少 tab：$label');
    }

    await tester.tap(find.text('债务'));
    await tester.pumpAndSettle();
    expect(find.text('记一笔借贷'), findsOneWidget);
    expect(find.byKey(const Key('amount-display')), findsNothing,
        reason: '债务页上不该还挂着金额面板');

    // 回到支出：面板要回来，否则用户以为「一笔都记不了」
    await tester.tap(find.text('支出'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('amount-display')), findsOneWidget);
  });

  testWidgets('转账 → 债务 → 支出：金额面板该收就收、该回就回', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: EntryEditorPage()),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      if (find.byKey(const Key('amount-display')).evaluate().isNotEmpty) break;
    }

    await tester.tap(find.text('转账'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('amount-display')), findsNothing);

    await tester.tap(find.text('债务'));
    await tester.pumpAndSettle();
    expect(find.text('记一笔借贷'), findsOneWidget);
    expect(find.byKey(const Key('amount-display')), findsNothing);

    // 从债务绕回支出：分类要重新自动选中，面板必须重新出现
    await tester.tap(find.text('支出'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      if (find.byKey(const Key('amount-display')).evaluate().isNotEmpty) break;
    }
    expect(find.byKey(const Key('amount-display')), findsOneWidget);
  });
}
