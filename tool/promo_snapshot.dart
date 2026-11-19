import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 小红书宣传图的**素材**生成器（非断言型用例）。
///
/// 为什么要它：真机截图里全是开发期的测试数据（finaltest / schemetest / -999），
/// 直接拿去宣传等于自曝。这里用 flutter_tester 软件渲染，先灌一本「像真人在用」
/// 的演示账本，再把首页 / 记账面板 / 统计 / 资产各屏画成 PNG。
///
/// ⚠️ 种子数据用 [LedgerStore] 直连写库，**不要**通过 provider 读 ——
/// 在 `tester.runAsync` 里 await `storeProvider.future` 等不到 pump，
/// 第一次就是这么卡满 10 分钟超时的。
///
/// 跑法（构建副本里，pubspec 已临时加 sqlite3 hook）：
///   flutter test tool/promo_snapshot.dart --no-pub
const _rootKey = ValueKey('promo-root');
const _outDir = 'C:/builds/promo_raw';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // flutter_tester 默认只有 Ahem（所有字都画成方框），不加载真字体
    // 截出来的图全是豆腐块。这里把系统黑体塞进 'Roboto'，把 App 自带的
    // 抖音体塞进 'DouyinSans' —— 两处都覆盖到，标题和正文才都是真字。
    Future<void> loadFont(String family, String path) async {
      final bytes = File(path).readAsBytesSync();
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.sublistView(bytes)));
      await loader.load();
    }

    // ⚠️ 同一 family 里**最后注册的那一个说了算**（不是逐字回退）：
    //   先 Noto 后 emoji → 中文全变方框；先 emoji 后 Noto → emoji 变方框。
    // 所以只能二选一。选 Noto：中文是主体，emoji 只出现在 glyphLabel()
    // 那几处（账本 chip、桑基图/图例），拼图时单独补。
    await loadFont('Roboto', 'C:/Windows/Fonts/NotoSansSC-VF.ttf');
    await loadFont('DouyinSans',
        'C:/Users/Administrator/WorkBuddy/记账软件/JianjiApp/assets/fonts/DouyinSans-Bold.otf');
    // Material 图标也要单独加载，否则顶栏的日历/搜索、底栏五个 tab
    // 全画成方框（Ahem 没有这些字形）。
    await loadFont('MaterialIcons',
        'C:/src/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
    // ignore: avoid_print
    print('fonts loaded');
  });

  Future<void> settle(WidgetTester tester, {int rounds = 10}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
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
      final b =
          tester.renderObject<RenderRepaintBoundary>(find.byKey(_rootKey));
      final img = await b.toImage(pixelRatio: 2.75);
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    final f = File('$_outDir/$name.png');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes!);
    // ignore: avoid_print
    print('snap $name');
  }

  testWidgets('灌演示数据并出宣传素材', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);

    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});

    // ---------- 先直连写库 ----------
    await tester.runAsync(() async {
      final dir = await databaseFactory.getDatabasesPath();
      try {
        await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
      } catch (_) {
        // 删不掉就沿用旧库
      }
      final store = await LedgerStore.open(withSamplePockets: true);
      final book = (await store.books()).first;
      final bid = book.id;

      final today = DateTime.now();
      final m = DateTime(today.year, today.month, 1);
      DateTime d(int day) => DateTime(m.year, m.month, day);

      Future<void> pocket(String title, String glyph, PocketKind kind,
              String type, int opening) =>
          store.addPocket(
            bookId: bid,
            title: title,
            glyph: glyph,
            kind: kind,
            currency: 'CNY',
            openingCents: opening,
            typeId: type,
          );

      await pocket('支付宝', 'ic:acc_alipay', PocketKind.bank, 'alipay', 482050);
      await pocket(
          '微信钱包', 'ic:acc_wechat', PocketKind.bank, 'wechatWallet', 126580);
      await pocket('工资卡', 'ic:acc_bank', PocketKind.bank, 'bankcard', 6214000);
      await pocket('信用卡', 'ic:acc_credit', PocketKind.credit, 'credit', 0);

      final pockets = await store.allPockets();
      int pid(String t) => pockets.firstWhere((p) => p.title == t).id;
      final ali = pid('支付宝');
      final wec = pid('微信钱包');
      final bank = pid('工资卡');
      final card = pid('信用卡');

      // 真实用户不会只有 9 个分类。补 7 个常用的，记账面板的 4 列网格
      // 才能铺满 4 行 —— 演示只有 9 个时下半屏是空的，图看着像没做完。
      const extra = [
        ('早餐', 'ic:obj_coffee'),
        ('外卖', 'ic:out_food'),
        ('打车', 'ic:obj_car'),
        ('房租', 'ic:obj_house'),
        ('水电', 'ic:obj_bulb'),
        ('超市', 'ic:obj_cart'),
        ('衣服', 'ic:obj_bag'),
      ];
      for (final b in extra) {
        await store.addBucket(
          bookId: bid,
          title: b.$1,
          glyph: b.$2,
          flow: 'out',
        );
      }

      final outs = await store.buckets(bid, 'out');
      final ins = await store.buckets(bid, 'in');
      int? outId(String t) {
        for (final b in outs) {
          if (b.title == t) return b.id;
        }
        return null;
      }

      int? inId(String t) {
        for (final b in ins) {
          if (b.title == t) return b.id;
        }
        return null;
      }

      Future<void> e(
        String flow,
        int pocketId,
        int? bucketId,
        int cents,
        int day,
        String memo, {
        int time = 12 * 60,
      }) =>
          store.addEntry(
            bookId: bid,
            pocketId: pocketId,
            bucketId: bucketId,
            flow: flow,
            amountCents: cents,
            memo: memo,
            day: d(day),
            timeMinutes: time,
          );

      await e('in', bank, inId('工资'), 1280000, 10, '11 月工资', time: 9 * 60);
      await e('in', wec, inId('红包'), 20000, 8, '朋友转账', time: 20 * 60);

      await e('out', ali, outId('食'), 1250, 19, '早饭 · 豆浆油条',
          time: 8 * 60 + 10);
      await e('out', ali, outId('行'), 500, 19, '地铁 2 号线', time: 8 * 60 + 40);
      await e('out', ali, outId('食'), 2800, 18, '午饭 · 公司楼下',
          time: 12 * 60 + 20);
      await e('out', wec, outId('食'), 1900, 18, '咖啡', time: 15 * 60);
      await e('out', card, outId('购'), 15680, 17, '超市囤货', time: 19 * 60);
      await e('out', bank, outId('住'), 320000, 16, '房租', time: 10 * 60);
      await e('out', wec, outId('玩'), 7800, 15, '电影票', time: 20 * 60 + 30);
      await e('out', ali, outId('医'), 3600, 14, '感冒药', time: 11 * 60);
      await e('out', ali, outId('学'), 5900, 13, '一本讲设计的书', time: 21 * 60);
      await e('out', wec, outId('礼'), 20000, 12, '同事生日', time: 18 * 60);
      await e('out', ali, outId('食'), 4200, 11, '外卖 · 麻辣烫',
          time: 19 * 60 + 20);

      await store.setBudget(bid, m, 800000);
      await store.close();
    });
    // ignore: avoid_print
    print('seeded');

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
    await tester.pump();
    await boot(tester);
    await drainAll(tester);
    // ignore: avoid_print
    print('booted');

    await snap(tester, '01_home');

    // 资产页（底栏第 4 格）
    await tester.tapAt(const Offset(269, 816));
    await settle(tester);
    await drainAll(tester, rounds: 16);
    await snap(tester, '02_assets');

    // 统计页（底栏第 2 格）
    await tester.tapAt(const Offset(123, 816));
    await settle(tester);
    await drainAll(tester, rounds: 16);
    await snap(tester, '03_stats');

    // 记账面板放最后：它是一整页（不是底部弹层），开了就只能靠顶栏按钮退出，
    // 后面的 tap 全落进它里面 —— 上一版就是这么把 02/03 拍成同一张的。
    await tester.tapAt(const Offset(196, 816));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester, rounds: 12);
    await drainAll(tester, rounds: 12);
    await snap(tester, '04_editor');

    expect(tester.takeException(), isNull);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
