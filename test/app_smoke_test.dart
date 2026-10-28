import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 启动链路冒烟：首帧必须能渲染，四个 tab 都要能建树。
///
/// 专门钉住「装上去卡在启动页」那类问题：只要 build 阶段抛异常、
/// 或者启动路径上死等某个插件，这里就会失败，不用等用户来报。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    // 必须显式标记已引导：RootGate 读不到这个键就会停在欢迎页，
    // 那底下「找得到明细 tab」的断言必然失败。
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});
  });

  /// 让真实的文件/数据库异步跑完（pump 的假时钟推不动这些）。
  ///
  /// 每轮同时推进假时钟：列表进场用的 Reveal 会 Future.delayed 排队（最多 240ms），
  /// 假时钟不往前走的话这些定时器一直悬着，测试结束时会断言
  /// "A Timer is still pending even after the widget tree was disposed"。
  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  /// 走完真实启动链路：读偏好 → 启动幕（呼吸 600ms + 张开 700ms）。
  ///
  /// 这段路径上有两类等待，混着处理会卡住：
  /// - SharedPreferences 是平台通道，假时钟推不动它 → 只能用 runAsync 真的等。
  /// - 幕的呼吸/张开是动画，得 pump(时长) 把假时钟推过去，
  ///   两段加起来 1300ms（见 ui/splash_page.dart 的 kBootBreath / kBootOpen），
  ///   推不够就停在"幕还没开、首页还没插进来"的半路。
  /// 所以这里两边都推：runAsync 走真实时间，pump(时长) 推进画。
  Future<void> boot(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 80));
    }
    // 幕：呼吸 600 + 张开 700，留足余量
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('首帧立刻渲染，不等任何插件', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: JianjiApp()));
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '首帧 build 不应抛异常');
    // 首帧是启动幕——它本身就是「不 await 任何插件」的画面，
    // 所以这一帧能出来，就说明启动路径上没有任何 await 卡着。
    // 首页要等幕开始张开才插进来（Key 见 main.dart 的 boot-curtain）。
    expect(find.byKey(const ValueKey('boot-curtain')), findsOneWidget);
    expect(find.byKey(const ValueKey('boot-target')), findsNothing);

    await boot(tester);
    expect(tester.takeException(), isNull, reason: '进主界面不应抛异常');
    expect(find.text('首页'), findsWidgets);
    // 幕只演一次，演完必须摘掉。
    // ⚠️ 这条是在钉 Stack 的 key：首页是幕开始张开时才插进来的，
    // 两个 child 没各自带 key 的话，Flutter 按下标配对会把幕的 State 顶掉重建，
    // 呼吸从头再来一轮 —— 表现是启动动画永远差一拍、总时长翻倍。
    expect(find.byKey(const ValueKey('boot-curtain')), findsNothing);
  });

  testWidgets('四个 tab 都能建树且不抛异常（日历已移到首页右上角）', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: JianjiApp()));
    await tester.pump();
    await boot(tester);
    await settle(tester);

    expect(tester.takeException(), isNull, reason: '首页异步加载不应抛异常');

    // 日历不再是 tab：首页右上角的小日历图标才是入口（见下一条用例）
    for (final label in ['统计', '资产', '我的']) {
      await tester.tap(find.text(label).last);
      await tester.pump();
      // ⚠️ 轮数要给够：资产页首帧会把「近 6 个月净值（netWorthDaily，循环 6 次
      // 全表聚合）」和「月序列（entriesOfMonth）」一起拉起来，sqflite 每个查询
      // 挂着 10s 事务定时器。只等 4 轮时这两条常常跑不完 → 测试结束时断言
      // "A Timer is still pending"（不是崩溃，是等待不够）。
      await settle(tester, rounds: 10);
      expect(tester.takeException(), isNull, reason: '切到 $label 不应抛异常');
    }

    // 回到首页，确认导航状态没坏
    await tester.tap(find.text('首页').last);
    await tester.pump();
    await settle(tester, rounds: 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('导航改版：日历从首页右上角进，底栏中间 + 直接记账',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(child: JianjiApp()));
    await tester.pump();
    await boot(tester);
    // ⚠️ 轮数要给够：日历页/记账页都会读库（预算、账户、当日流水），
    // 这些 sqflite 查询挂着 10s 定时器，测试结束时没跑完就会报
    // "A Timer is still pending"。本项目所有 App 级用例都有这个坑。
    await settle(tester, rounds: 14);

    // ① 底栏现在是 首页/统计/资产/我的 —— 「统计」进了底栏
    expect(find.text('统计'), findsWidgets, reason: '统计应该在底栏');

    // ② 首页右上角的日历入口
    final entry = find.byTooltip('日历');
    expect(entry, findsWidgets, reason: '首页右上角要有日历入口');
    await tester.tap(entry.first);
    await tester.pump();
    await settle(tester, rounds: 14);
    expect(tester.takeException(), isNull, reason: '打开日历页不应抛异常');
    // 1.4.5 起日历页不再用 AppBar（年月直接做大标题，照一木的版式），
    // 页面里已经没有「日历」两个字，改用右上角常驻的「回到今天」判定。
    expect(find.byTooltip('回到今天'), findsWidgets, reason: '应打开日历页');
    expect(find.byTooltip('上个月'), findsWidgets, reason: '日历页要有翻月');

    // ③ 返回首页，点底栏中间的 + 直接开记账页
    // ⚠️ 不能用 tester.pageBack()：它只认 Cupertino/Material 的标准返回按钮，
    // 本项目的 AppBar 用的是自定义 leading，找不到就报
    // "Found 0 widgets with type CupertinoNavigationBarBackButton"。
    tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    await tester.pump();
    await settle(tester, rounds: 10);

    final plus = find.byIcon(Icons.add);
    expect(plus, findsWidgets, reason: '底栏中间要有 + 记账键');
    await tester.tap(plus.last);
    await tester.pump();
    await settle(tester, rounds: 14);
    expect(tester.takeException(), isNull);
    expect(find.text('保存'), findsWidgets, reason: '点 + 应该打开记账页');
  });
}