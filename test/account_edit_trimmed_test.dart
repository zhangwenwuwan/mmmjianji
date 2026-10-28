import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/account_edit_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 2026-10-27：账户编辑页摘掉了 5 个「只存不用」的开关。
///
/// 这些开关把值写进库，但没有任何计算或渲染读它们（没有账单子系统）。
/// 留着就是骗用户"我设好了"。这条测试是防回归：谁再把它们加回来，
/// 要么同时把消费方写出来，要么这里会红。
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

  testWidgets('「其他账户」分支不再出现夜间模式图标 / 收益同步', (tester) async {
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

    // 页面确实渲染出来了（默认是现金/其他账户分支）
    expect(find.text('所属分组'), findsOneWidget);
    expect(find.text('名称'), findsOneWidget);

    // 三个没实现的选项必须不在
    expect(find.text('夜间模式图标'), findsNothing);
    expect(find.text('收益同步'), findsNothing);
    // 保留的开关还在（它们是真生效的）
    expect(find.text('计入总资产'), findsOneWidget);
    expect(find.text('记账可被选择'), findsOneWidget);
  });
}
