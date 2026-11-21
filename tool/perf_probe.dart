import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/main.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 帧耗时探针（非断言型，不进 CI）。
///
/// 目的：**在改之前先量**。flutter_tester 没有 GPU，测不出真实帧率，
/// 但它会把 build + layout + paint（Skia 软件光栅）都跑一遍 —— 首页卡顿
/// 九成来自这三步的 CPU 时间，不是显卡。所以这里量的是「相对值」：
/// 同一个探针在优化前后各跑一次，看毫秒数掉了多少。
///
/// 跑法：`./build_jianji.sh --check --test-file tool/perf_probe.dart`
/// （必须走这个脚本，它会临时给 pubspec 注入 winsqlite3 hook）
const _rootKey = ValueKey('perf-root');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> seed(int count) async {
    final dir = await databaseFactory.getDatabasesPath();
    try {
      await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
    } catch (_) {}
    final store = await LedgerStore.open();
    final book = (await store.books()).first;
    await store.addPocket(
      bookId: book.id,
      title: '支付宝',
      glyph: 'ic:acc_alipay',
      kind: PocketKind.bank,
      currency: 'CNY',
      openingCents: 500000,
    );
    final pid =
        (await store.allPockets()).firstWhere((p) => p.id > 0).id;
    final outs = await store.buckets(book.id, 'out');
    final ins = await store.buckets(book.id, 'in');
    final now = DateTime.now();
    for (var i = 0; i < count; i++) {
      final day = DateTime(now.year, now.month, 1 + (i % 28));
      final out = i % 4 != 0;
      await store.addEntry(
        bookId: book.id,
        pocketId: pid,
        bucketId: outs[i % outs.length].id,
        flow: out ? 'out' : 'in',
        amountCents: 1200 + (i * 137) % 9000,
        memo: '第 $i 笔 · 午饭',
        day: day,
        timeMinutes: 8 * 60 + (i % 700),
      );
    }
    // 顺手产生点 in 流水，让统计里有收入
    for (var i = 0; i < 3; i++) {
      await store.addEntry(
        bookId: book.id,
        pocketId: pid,
        bucketId: ins[i % ins.length].id,
        flow: 'in',
        amountCents: 800000,
        memo: '工资 $i',
        day: DateTime(now.year, now.month, 10 + i),
      );
    }
    await store.setBudget(book.id, DateTime(now.year, now.month), 800000);
    await store.close();
  }

  double ms(Stopwatch sw) => sw.elapsedMicroseconds / 1000.0;

  testWidgets('首页帧耗时', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});
    await tester.runAsync(() => seed(300));

    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      RepaintBoundary(
        key: _rootKey,
        child: UncontrolledProviderScope(
          container: container,
          child: const JianjiApp(),
        ),
      ),
    );

    // 冷启动：逐步 pump 到首屏稳定
    final boot = Stopwatch()..start();
    for (var i = 0; i < 14; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 40));
    }
    boot.stop();
    await settle(tester, rounds: 12);

    // ① 一次数据变更后的整页重建
    final rebuild = Stopwatch()..start();
    container.read(revisionProvider.notifier).state++;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    rebuild.stop();

    // ② 等查询回来（含 SQL）
    final refresh = Stopwatch()..start();
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    refresh.stop();

    // ③ 滚动 30 帧
    final scroll = Stopwatch()..start();
    for (var i = 0; i < 30; i++) {
      await tester.drag(
          find.byType(CustomScrollView).first, const Offset(0, -28),
          warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 16));
    }
    scroll.stop();

    // ④ 再回到顶部（日历/月份切换之类的整页重建）
    final back = Stopwatch()..start();
    for (var i = 0; i < 12; i++) {
      await tester.drag(
          find.byType(CustomScrollView).first, const Offset(0, 60),
          warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 16));
    }
    back.stop();

    // ignore: avoid_print
    print('PERF boot(14f)=${ms(boot).toStringAsFixed(1)}ms  '
        'rebuild=${ms(rebuild).toStringAsFixed(1)}ms  '
        'refresh(6f)=${ms(refresh).toStringAsFixed(1)}ms  '
        'scroll(30f)=${ms(scroll).toStringAsFixed(1)}ms '
        '(${(ms(scroll) / 30).toStringAsFixed(1)}ms/f)  '
        'scrollBack(12f)=${ms(back).toStringAsFixed(1)}ms');
    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
