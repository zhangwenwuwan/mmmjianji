import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 2026-10-28：根页面按返回键两段式退出。
///
/// 以前按一下就退出 App（Shell 是根路由，系统直接 finish 掉 Activity）。
/// 手势返回很容易误触，一滑就把 App 关了。现在：
/// - 不在首页 → 先回首页（不退出）；
/// - 已在首页 → 第一次只提示「再返回一次退出」，2 秒内再按一次才退出。
///
/// 这里直接调 `handlePopRoute()` 模拟系统返回键，并拦住 `SystemNavigator.pop`
/// 这个平台调用 —— 不然测试里真的会去 finish 宿主。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});
    // 每个用例一个空库：整套测试是串行跑同一个临时目录的，别的用例留下的流水
    // 会让首页多跑 monthSeries / insightRank 这些重查询，10 秒的 sqflite 事务
    // 定时器在用例结束时还挂着 → "Pending timers" 直接红。
    final dir = await databaseFactory.getDatabasesPath();
    for (final name in ['jianji_ledger.db', 'jianji_ledger.db-journal']) {
      final f = File('$dir/$name');
      if (f.existsSync()) f.deleteSync();
    }
  });

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
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
    await settle(tester, rounds: 14);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester, rounds: 6);
  }

  /// 拦住「真的退出 App」这一步，并记下有没有被调用。
  List<MethodCall> interceptExit(WidgetTester tester) {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    return calls;
  }

  bool exited(List<MethodCall> calls) =>
      calls.any((c) => c.method == 'SystemNavigator.pop');

  testWidgets('首页按一次返回只提示，再按一次才退出', (tester) async {
    final calls = interceptExit(tester);
    await boot(tester);

    // 第一次：提示，不退出
    await tester.binding.handlePopRoute();
    await settle(tester, rounds: 4);
    expect(find.text('再返回一次退出'), findsOneWidget,
        reason: '第一次返回要给一句人话，而不是直接关掉 App');
    expect(exited(calls), isFalse, reason: '第一次返回绝不能退出');

    // 第二次（2 秒窗口内）：真的退出
    await tester.binding.handlePopRoute();
    await settle(tester, rounds: 4);
    expect(exited(calls), isTrue, reason: '第二次要真的退出');
  });

  testWidgets('不在首页时返回先回首页，不提示也不退出', (tester) async {
    final calls = interceptExit(tester);
    await boot(tester);

    await tester.tap(find.text('统计').last);
    await settle(tester);
    expect(find.text('统计'), findsWidgets);

    await tester.binding.handlePopRoute();
    await settle(tester, rounds: 6);

    expect(find.text('再返回一次退出'), findsNothing,
        reason: '回首页这一步不该弹退出提示');
    expect(exited(calls), isFalse);
    // 回到首页：首页顶栏只有账本 chip，没有「统计」这个标题
    expect(find.text('首页'), findsWidgets, reason: '底栏选中态应回到首页');
    expect(find.text('统计'), findsWidgets, reason: '底栏那一格还在，但已经不再选中');
  });
}
