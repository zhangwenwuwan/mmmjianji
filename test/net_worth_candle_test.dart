import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 净资产蜡烛图的口径测试。
///
/// 为什么值得单独测：K 线的开/高/低/收只要错一个，图上就是一根**假 K**，
/// 而页面看上去依然「有模有样」——靠肉眼发现不了，只能靠断言钉住。
///
/// 两条关键规则：
/// 1. 月开盘 = 上月末收盘（也就是当月第一笔流水**之前**的净值），不是第一天记完账之后的值；
/// 2. 影线 = 当月所有日净值（含月开盘那一个）的最高 / 最低。
void main() {
  group('monthlyCandles', () {
    test('开=上月收，高/低取当月极值（含开盘），收=月末', () {
      final daily = <({DateTime day, int netCents})>[
        (day: DateTime(2026, 1, 1), netCents: 100),
        (day: DateTime(2026, 1, 15), netCents: 300),
        (day: DateTime(2026, 1, 31), netCents: 200),
        (day: DateTime(2026, 2, 1), netCents: 250),
        (day: DateTime(2026, 2, 20), netCents: 50),
      ];

      final cs = monthlyCandles(daily, baselineCents: 80);
      expect(cs.length, 2);

      // 1 月：开盘用的是「区间开始前」的净值 80；最高 300、最低就是开盘 80
      expect(cs[0].openCents, 80);
      expect(cs[0].highCents, 300);
      expect(cs[0].lowCents, 80);
      expect(cs[0].closeCents, 200);

      // 2 月：开盘接上个月收盘 200，月中跌到 50
      expect(cs[1].openCents, 200);
      expect(cs[1].highCents, 250);
      expect(cs[1].lowCents, 50);
      expect(cs[1].closeCents, 50);
    });

    test('整月没有流水 → 一字线（开=高=低=收）', () {
      final daily = <({DateTime day, int netCents})>[
        (day: DateTime(2026, 1, 1), netCents: 500),
        (day: DateTime(2026, 2, 1), netCents: 500),
      ];
      final cs = monthlyCandles(daily, baselineCents: 500);
      expect(cs.length, 2);
      for (final c in cs) {
        expect(c.openCents, 500);
        expect(c.highCents, 500);
        expect(c.lowCents, 500);
        expect(c.closeCents, 500);
      }
    });
  });

  group('netWorthDaily', () {
    late Directory tmp;
    late LedgerStore store;
    late int bookId;

    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    });

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('jianji-candle-');
      store = await LedgerStore.open(path: '${tmp.path}/test.db');
      bookId = (await store.books()).first.id;
    });

    tearDown(() async {
      await store.close();
      await tmp.delete(recursive: true);
    });

    test('逐日净值按流水累加，baseline 是首笔之前的值', () async {
      await store.addPocket(
        bookId: bookId,
        title: '测试钱包',
        glyph: '💵',
        kind: PocketKind.cash,
        currency: 'CNY',
        openingCents: 100000, // ¥1000
      );
      final pocket =
          (await store.allPockets()).firstWhere((p) => p.title == '测试钱包');

      // 3 月 5 日支出 ¥300，3 月 10 日收入 ¥500
      await store.addEntry(
        bookId: bookId,
        pocketId: pocket.id,
        flow: 'out',
        amountCents: 30000,
        memo: '支出',
        day: DateTime(2026, 3, 5, 12),
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: pocket.id,
        flow: 'in',
        amountCents: 50000,
        memo: '收入',
        day: DateTime(2026, 3, 10, 12),
      );

      final series = await store.netWorthDaily(
        from: DateTime(2026, 3, 1),
        until: DateTime(2026, 3, 31),
        toBase: (cents, _) => cents,
      );

      expect(series.baselineCents, 100000, reason: '首笔之前还是 ¥1000');
      expect(series.days.length, 31);

      int at(int dayOfMonth) => series.days
          .firstWhere((d) =>
              d.day.year == 2026 && d.day.month == 3 && d.day.day == dayOfMonth)
          .netCents;

      expect(at(1), 100000);
      expect(at(4), 100000);
      expect(at(5), 70000); // 扣掉 ¥300
      expect(at(9), 70000);
      expect(at(10), 120000); // 加上 ¥500
      expect(at(31), 120000);

      // 再按月切一次，确认开高低收都对
      final cs =
          monthlyCandles(series.days, baselineCents: series.baselineCents);
      expect(cs.length, 1);
      expect(cs.single.openCents, 100000);
      expect(cs.single.highCents, 120000);
      expect(cs.single.lowCents, 70000);
      expect(cs.single.closeCents, 120000);
    });
  });
}
