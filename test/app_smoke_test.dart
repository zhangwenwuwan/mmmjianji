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

  setUp(() async {
    // 必须显式标记已引导：RootGate 读不到这个键就会停在欢迎页，
    // 那底下「找得到明细 tab」的断言必然失败。
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});

    // 2026-10-28 加：这里原来**不删库**，用的是 .dart_tool 里上一次跑测试残留的库。
    // 首页改成「首帧就建树」之后，残留的流水会让首页在启动那一帧就跑一批重查询
    // （月序列 / 排名 / 近 6 个月净值），settle 的轮数不够收尾 →
    // "A Timer is still pending even after the widget tree was disposed"。
    // 这个测试单独跑时库是空的，所以一直没暴露；串行全量才炸。
    final dir = await databaseFactory.getDatabasesPath();
    try {
      await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
    } catch (_) {
      // 删不掉就沿用旧库：断言只看「首帧能渲染 + 四个 tab 能建树」，
      // 有数据最多多花几轮查询。
    }
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

  /// 只推进**真实时间**、不推假时钟：让 sqflite 还在排队的查询真正跑完。
  ///
  /// `txnSynchronized` 给每个查询挂一个 10s 的 timeoutCompleter，只有查询
  /// 真正开始执行（拿到锁）时那个 Timer 才会被取消；pump 推的是假时钟，
  /// 推再多也替代不了真实 IO。和 large_text_test.dart 的 drainReal 同一套。
  /// 2026-11-06 踩：全量/单跑都稳定报 "A Timer is still pending"，
  /// 首页首帧垫在启动幕底下之后 provider 会一次性拉起 5 条查询排队。
  Future<void> drainReal(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
    await tester.pump();
  }

  /// 启动后完整排空：真实 IO 与假时钟**交替**推进。
  ///
  /// 只推假时钟 → sqflite 排队查询的 10s timer 永远等不到完成回调；
  /// 只推真实时间 → provider 加载完新挂的 Reveal(40ms) timer 没人触发。
  /// 两者会互相产生对方要处理的新工作，所以必须来回推，收尾再补一帧
  /// 把最后一轮新建的 Reveal 也跑掉。全量串行时机器更慢，轮数给足。
  /// 全量串行时开库要跑完 v1→v22 共 22 段迁移，后面所有 provider 查询
  /// 都排在这条锁后面；40 × 60ms ≈ 2.4s 真实时间才够把它们放出来。
  /// 假时钟总共推 40 × 100ms = 4s，仍低于 sqflite 的 10s 告警阈值，
  /// 不会把「还没跑完」伪装成「超时告警已触发」。
  Future<void> drainAll(WidgetTester tester, {int rounds = 40}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// 走完真实启动链路：读偏好 → 启动幕（呼吸 180ms + 张开 420ms）。
  ///
  /// 这段路径上有两类等待，混着处理会卡住：
  /// - SharedPreferences 是平台通道，假时钟推不动它 → 只能用 runAsync 真的等。
  /// - 幕的呼吸/张开是动画，得 pump(时长) 把假时钟推过去，
  ///   两段加起来 600ms（见 ui/splash_page.dart 的 kBootBreath / kBootOpen），
  ///   推不够就停在"幕还没开完"的半路。
  /// 所以这里两边都推：runAsync 走真实时间，pump(时长) 推进画。
  Future<void> boot(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 80));
    }
    // 幕：呼吸 180 + 张开 420，留足余量
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('首帧立刻渲染，不等任何插件', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: JianjiApp()));
    await tester.pump();

    expect(tester.takeException(), isNull, reason: '首帧 build 不应抛异常');
    // 首帧是启动幕——它本身就是「不 await 任何插件」的画面，
    // 所以这一帧能出来，就说明启动路径上没有任何 await 卡着。
    // 2026-10-28 起首页是**首帧就垫在幕底下**的（不再等幕张开才插），
    // 所以两个 key 这一帧都在。
    expect(find.byKey(const ValueKey('boot-curtain')), findsOneWidget);
    expect(find.byKey(const ValueKey('boot-target')), findsOneWidget);

    await boot(tester);
    // 再 settle 一轮：首页从「幕张开」那一刻起才真正开始建数据，
    // Reveal 的 Future.delayed（每块最多 360ms）和 sqflite 的事务定时器
    // 都还挂着，不收尾就会报 "A Timer is still pending"。
    // 这个用例是全文件第一个，冷库 + 首帧一次性拉起的 provider 查询最多。
    // 单独跑能过、全量串行就炸，是因为机器慢时查询排队更久，而查询完成后
    // 又会新建 Reveal 定时器 —— 必须用 drainAll 交替排空，不能只 settle。
    await drainAll(tester);
    expect(tester.takeException(), isNull, reason: '进主界面不应抛异常');
    expect(find.text('首页'), findsWidgets);
    // 幕只演一次，演完必须摘掉。
    // ⚠️ 这条是在钉 Stack 的 key：幕摘掉之后首页在 children 里从下标 1 变成 0，
    // 两个 child 没各自带 key 的话，Flutter 按下标配对会以为「下标 0 从幕变成了首页」，
    // 直接把首页的 State 扔掉重建 —— 滚动位置和已加载的数据全丢（等于白启动一次）。
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
    await drainReal(tester);
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
    await drainReal(tester);
  });

  testWidgets('语音记账入口是首页右下角的独立悬浮按钮', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: JianjiApp()));
    await tester.pump();
    await boot(tester);
    await settle(tester, rounds: 14);

    final fab = find.byKey(const ValueKey('voice-entry-fab'));
    expect(fab, findsOneWidget, reason: '首页要有语音记账悬浮按钮');
    // 顶栏不再重复放一个麦克风：整个首页只该有一颗。
    expect(find.byIcon(Icons.mic_none_outlined), findsOneWidget,
        reason: '麦克风图标只属于右下角悬浮按钮');

    // 右下角：中心落在右下半区，且底边在悬浮底栏胶囊（高 54）之上。
    final rect = tester.getRect(fab);
    final screen = MediaQuery.of(tester.element(fab)).size;
    expect(rect.center.dx, greaterThan(screen.width / 2),
        reason: '按钮要靠右');
    expect(rect.center.dy, greaterThan(screen.height / 2),
        reason: '按钮要靠下');
    expect(rect.bottom, lessThan(screen.height - 54),
        reason: '按钮不能被底栏胶囊盖住');

    // 这里不点：点击会走平台麦克风权限 + 82MB 离线模型加载，属于真机验证
    // 范畴（widget 测试没有录音通道，硬点只会留下一个 3 秒 SnackBar 定时器）。
    // 弹窗与落库链路另由 voice_entry_test 覆盖。
    expect(find.byIcon(Icons.mic_none_outlined), findsOneWidget);
    await drainReal(tester);
  });
}