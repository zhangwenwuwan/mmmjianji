import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/main.dart';
import 'package:jianji/ui/liquid_surface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 深色模式离屏快照工具（2026-11-08，非断言型用例）。
///
/// 为什么要它：真机是 OPPO ColorOS，`cmd uimode night yes` 直接返回
/// `Night mode: no`，系统夜间模式切不动 —— 1.4.64 的全 App 玻璃材质
/// **一次深色都没验过**。这里用 flutter_tester 软件渲染把每屏画成 PNG，
/// 至少能把「玻璃发灰 / 文字对比度 / 高光过曝」这三类问题先看出来。
///
/// ⚠️ 产物写到 `C:/builds/dark/`，只用于人眼检查，不做 golden 比对
/// （字体渲染与真机不同，比对会一直红）。验证完就删掉本文件。
const _rootKey = ValueKey('snap-root');
const _outDir = 'C:/builds/dark';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});
    final dir = await databaseFactory.getDatabasesPath();
    try {
      await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
    } catch (_) {
      // 删不掉就沿用旧库：快照只看视觉，多几笔流水无所谓。
    }
  });

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> drainAll(WidgetTester tester, {int rounds = 24}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> boot(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 80));
    }
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> snap(WidgetTester tester, String name) async {
    await tester.pump();
    final bytes = await tester.runAsync(() async {
      final b = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(_rootKey));
      final img = await b.toImage(pixelRatio: 2.75);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    final f = File('$_outDir/$name.png');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes!);
  }

  testWidgets('深色：首页 / 统计 / 我的 / 按压态', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    // 钉死深色。不要在 addTearDown 里清它 —— 和大字号测试同一个坑：
    // 清早了后续帧会掉回浅色，截出来的图会半深半浅。
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;

    await tester.pumpWidget(
      RepaintBoundary(
        key: _rootKey,
        child: const ProviderScope(child: JianjiApp()),
      ),
    );
    await tester.pump();
    await boot(tester);
    await drainAll(tester);
    await snap(tester, '01_home_dark');

    // 底栏按住「资产」：验证深色下的受光沿不糊成一团。
    // ⚠️ 别按中间的「+」：那是动作键，松手会直接弹出记账面板，
    // 后面的截图全变成面板（1.4.65 第一次跑就是这么废掉 03/04 的）。
    // 逻辑坐标：视口 392.7 × 850.9，底栏胶囊底边距屏底 8、高 54。
    final g = await tester.startGesture(const Offset(269, 816));
    await tester.pump(const Duration(milliseconds: 200));
    await snap(tester, '02_home_dark_press');
    await g.up();
    await settle(tester);
    await drainAll(tester, rounds: 12);

    // 切 tab 一律用坐标，不用 find.text：统计页的底栏文字会被语义合并，
    // find.text('我的') 在那里找不到（1.4.65 快照第一次跑就挂在这）。
    // 每格宽 = (392.7 - 28) / 5 ≈ 72.9，起点 14，中心 = 14 + 72.9 × (i + .5)。
    await tester.tapAt(const Offset(123, 816));
    await settle(tester);
    await drainAll(tester, rounds: 12);
    await snap(tester, '03_stats_dark');

    await tester.tapAt(const Offset(342, 816));
    await settle(tester);
    await drainAll(tester, rounds: 12);
    await snap(tester, '04_me_dark');

    expect(tester.takeException(), isNull);
  });

  testWidgets('浅色：按住资产的受光沿（对照 additive 改动的回归）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;

    await tester.pumpWidget(
      RepaintBoundary(
        key: _rootKey,
        child: const ProviderScope(child: JianjiApp()),
      ),
    );
    await tester.pump();
    await boot(tester);
    await drainAll(tester);
    await snap(tester, '06_home_light');

    // 「资产」是第 4 格：14 + 72.9 × 3.5 ≈ 269。松开即切页，无副作用。
    final g = await tester.startGesture(const Offset(269, 816));
    await tester.pump(const Duration(milliseconds: 250));
    await snap(tester, '07_home_light_press');
    await g.up();
    // 收尾必须排空：不解手势会留一帧回调，查询队列也有 10s 超时定时器，
    // 只 pump 假时钟会报 "A Timer is still pending"（第一次跑就挂在这）。
    await settle(tester);
    await drainAll(tester, rounds: 16);

    expect(tester.takeException(), isNull);
  });

  testWidgets('深色：LiquidSurface 包住的实色控件，按下不再被冲白', (tester) async {
    tester.view.physicalSize = const Size(1080, 1200);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;

    await tester.pumpWidget(
      RepaintBoundary(
        key: _rootKey,
        child: MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: Scaffold(
            backgroundColor: const Color(0xFF101413),
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 深绿：加色前后差别最明显的一种底色
                  LiquidSurface(
                    radius: 14,
                    child: Container(
                      width: 260,
                      height: 56,
                      alignment: Alignment.center,
                      color: const Color(0xFF1F6B45),
                      child: const Text('深绿控件',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  const SizedBox(height: 24),
                  LiquidSurface(
                    radius: 14,
                    child: Container(
                      width: 260,
                      height: 56,
                      alignment: Alignment.center,
                      color: const Color(0xFFEDEFF0),
                      child: const Text('浅色控件',
                          style: TextStyle(color: Colors.black87)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    // 逻辑坐标：视口 392.7 × 436.4，「深绿控件」在上半（中心约 y=178）
    final g = await tester.startGesture(const Offset(196, 178));
    await tester.pump(const Duration(milliseconds: 400));
    await snap(tester, '05_surface_dark_press');
    await g.up();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
  });
}
