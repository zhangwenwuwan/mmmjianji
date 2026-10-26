import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/bill_csv.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late LedgerStore store;
  late int bookId;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jj-b1-');
    store = await LedgerStore.open(path: '${tmp.path}/t.db');
    bookId = (await store.books()).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  group('借贷', () {
    test('我借出：本金 - 还款 = 待收，还清自动结清', () async {
      final id = await store.addDebt(Debt(
        id: 0,
        bookId: bookId,
        direction: 'lend',
        counterparty: '小王',
        channel: 'personal',
        principalCents: 200000,
        currency: 'CNY',
        borrowedOn: DateTime(2026, 10, 1),
        dueOn: DateTime(2026, 12, 1),
        note: '垫付',
        interestRate: null,
        closed: false,
      ));

      var list = await store.debts(bookId);
      expect(list.length, 1);
      expect(list.first.isLend, isTrue);
      expect(list.first.counterparty, '小王');

      await store.addDebtPayment(
          bookId: bookId,
          debtId: id,
          amountCents: 50000,
          paidOn: DateTime(2026, 10, 20));
      var paid = await store.debtPaidMap(bookId);
      expect(paid[id], 50000);
      // 还差 1500 元
      expect(list.first.principalCents - paid[id]!, 150000);

      // 再还剩下的
      await store.addDebtPayment(
          bookId: bookId,
          debtId: id,
          amountCents: 150000,
          paidOn: DateTime(2026, 11, 1));
      paid = await store.debtPaidMap(bookId);
      expect(paid[id], 200000);

      await store.setDebtClosed(id, true);
      expect((await store.debts(bookId)).isEmpty, isTrue);
      expect((await store.debts(bookId, includeClosed: true)).length, 1);
    });

    test('删除借贷会连带删掉还款记录', () async {
      final id = await store.addDebt(Debt(
        id: 0,
        bookId: bookId,
        direction: 'borrow',
        counterparty: '银行',
        channel: 'bank',
        principalCents: 500000,
        currency: 'CNY',
        borrowedOn: DateTime(2026, 9, 1),
        dueOn: null,
        note: '',
        interestRate: 4.5,
        closed: false,
      ));
      await store.addDebtPayment(
          bookId: bookId, debtId: id, amountCents: 100000, paidOn: DateTime(2026, 9, 5));
      expect((await store.debtPayments(id)).length, 1);

      await store.deleteDebt(id);
      expect((await store.debtPayments(id)).isEmpty, isTrue);
      expect((await store.debts(bookId)).isEmpty, isTrue);
    });

    test('编辑借贷可以切换借入/借出方向', () async {
      final id = await store.addDebt(Debt(
        id: 0,
        bookId: bookId,
        direction: 'lend',
        counterparty: '小李',
        channel: 'personal',
        principalCents: 10000,
        currency: 'CNY',
        borrowedOn: DateTime(2026, 10, 1),
        dueOn: null,
        note: '',
        interestRate: null,
        closed: false,
      ));
      final debt = (await store.debts(bookId)).first;
      await store.updateDebt(debt.copyWith(direction: 'borrow'));
      expect((await store.debts(bookId)).first.direction, 'borrow');
      expect((await store.debts(bookId)).first.id, id);
    });
  });

  group('愿望清单', () {
    test('冷静期剩余天数', () {
      final w = Wish(
        id: 1,
        bookId: 1,
        title: '耳机',
        glyph: '🎧',
        priceCents: 99900,
        note: '',
        coolDays: 7,
        createdOn: DateTime(2026, 10, 1),
        status: 'waiting',
      );
      expect(w.coolLeft(DateTime(2026, 10, 1)), 7);
      expect(w.coolLeft(DateTime(2026, 10, 4)), 4);
      expect(w.coolLeft(DateTime(2026, 10, 8)), 0); // 到期
      expect(w.coolLeft(DateTime(2026, 10, 10)), -2); // 过期
    });

    test('状态流转与删除', () async {
      await store.addWish(Wish(
        id: 0,
        bookId: bookId,
        title: '相机',
        glyph: '📷',
        priceCents: 500000,
        note: '',
        coolDays: 7,
        createdOn: DateTime(2026, 10, 1),
        status: 'waiting',
      ));
      var list = await store.wishes(bookId);
      expect(list.length, 1);
      expect(list.first.isWaiting, isTrue);

      await store.setWishStatus(list.first.id, 'bought');
      list = await store.wishes(bookId);
      expect(list.first.isWaiting, isFalse);
      expect(list.first.status, 'bought');
      expect((await store.wishes(bookId, status: 'waiting')).isEmpty, isTrue);

      await store.deleteWish(list.first.id);
      expect((await store.wishes(bookId)).isEmpty, isTrue);
    });
  });

  group('标签', () {
    test('统计 / 改名 / 删除 / 按标签查流水', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      Future<void> add(String tags) => store.addEntry(
            bookId: bookId,
            pocketId: cash.id,
            flow: 'out',
            amountCents: 100,
            memo: 't',
            day: DateTime(2026, 10, 5),
            tags: tags,
          );
      await add('聚餐,报销');
      await add('聚餐');
      await add('');

      var stats = await store.tagStats(bookId);
      expect(stats.length, 2);
      final dining = stats.firstWhere((s) => s.tag == '聚餐');
      expect(dining.count, 2);

      // 改名：两条「聚餐」都要变
      final changed = await store.renameTag(bookId, '聚餐', '吃饭');
      expect(changed, 2);
      stats = await store.tagStats(bookId);
      expect(stats.any((s) => s.tag == '聚餐'), isFalse);
      expect(stats.firstWhere((s) => s.tag == '吃饭').count, 2);

      // 按标签查
      expect((await store.entriesOfTag(bookId, '吃饭')).length, 2);
      expect((await store.entriesOfTag(bookId, '报销')).length, 1);
      // 不能误匹配（「报」不该命中「报销」以外的）
      expect((await store.entriesOfTag(bookId, '报')).isEmpty, isTrue);

      // 删除标签：只摘标签，流水还在
      final removed = await store.deleteTag(bookId, '报销');
      expect(removed, 1);
      expect((await store.tagStats(bookId)).any((s) => s.tag == '报销'), isFalse);
      expect((await store.entriesOfMonth(bookId, DateTime(2026, 10))).length, 3);
    });
  });

  group('分类走势 / 净资产走势', () {
    test('分类按月合计', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      final food = (await store.buckets(bookId, 'out')).first;
      for (final d in [
        DateTime(2026, 9, 3),
        DateTime(2026, 9, 20),
        DateTime(2026, 10, 2),
      ]) {
        await store.addEntry(
          bookId: bookId,
          pocketId: cash.id,
          bucketId: food.id,
          flow: 'out',
          amountCents: 1000,
          memo: 'x',
          day: d,
        );
      }
      // bucketMonthly 现在收「自身 + 子分类」的 id 列表
      final rows = await store.bucketMonthly(bookId, [food.id], months: 12);
      final sep = rows.firstWhere((r) => r.month == '2026-09');
      final oct = rows.firstWhere((r) => r.month == '2026-10');
      expect(sep.cents, 2000);
      expect(oct.cents, 1000);
    });

    test('月末余额口径：期初 + 流水，负债记负', () async {
      final pockets = await store.allPockets(includeArchived: false);
      final cash = pockets.first;
      await store.addPocket(
        bookId: bookId,
        title: '信用卡',
        glyph: '💳',
        kind: PocketKind.credit,
        currency: 'CNY',
        openingCents: 0,
      );
      final cc = (await store.allPockets(includeArchived: false)).firstWhere((p) => p.title == '信用卡');
      final now = DateTime.now();

      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        flow: 'in',
        amountCents: 100000,
        memo: '收入',
        day: now,
      );
      await store.addEntry(
        bookId: bookId,
        pocketId: cc.id,
        flow: 'out',
        amountCents: 30000,
        memo: '刷卡',
        day: now,
      );

      final rows = await store.monthEndBalances(months: 1);
      final cashRow = rows.firstWhere((r) => r.pocketId == cash.id);
      final ccRow = rows.firstWhere((r) => r.pocketId == cc.id);
      expect(cashRow.balanceCents, 100000); // 现金 +1000
      expect(ccRow.balanceCents, -30000); // 信用卡欠 300，记为负
    });
  });

  group('CSV 导出', () {
    test('表头、BOM、逗号转义、类型文字', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      final food = (await store.buckets(bookId, 'out')).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        bucketId: food.id,
        flow: 'out',
        amountCents: 1234,
        memo: '早餐,豆浆', // 含逗号，必须被引号包起来
        day: DateTime(2026, 10, 8),
        tags: 'a,b',
        reimburse: 1,
      );
      final csv = await store.exportCsv(bookId);
      expect(csv.startsWith('\uFEFF'), isTrue, reason: '必须带 BOM，否则 Excel 乱码');
      final lines = csv.split('\r\n');
      expect(lines.first.replaceFirst('\uFEFF', ''),
          '日期,类型,金额,币种,分类,账户,转入账户,备注,标签,报销');
      final row = lines[1];
      expect(row.contains('2026-10-08'), isTrue);
      expect(row.contains('支出'), isTrue);
      expect(row.contains('12.34'), isTrue);
      expect(row.contains('"早餐,豆浆"'), isTrue);
      expect(row.contains('待报销'), isTrue);
    });
  });

  group('账单 CSV 解析', () {
    test('微信格式', () {
      const text = '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态\n'
          '2026-10-01 12:30:00,商户消费,某某餐厅,午饭,支出,¥35.00,零钱,支付成功\n'
          '2026-10-02 09:00:00,转账,张三,还款,收入,100.00,零钱,已存入零钱\n'
          '2026-10-03 10:00:00,其他,系统,红包退款,不计收支,¥5.00,零钱,已全额退款\n';
      final r = parseBillCsv(text);
      expect(r.source, 'wechat');
      expect(r.rows.length, 2, reason: '不计收支的行要跳过');
      expect(r.skipped, 1);
      expect(r.rows.first.cents, 3500);
      expect(r.rows.first.flow, 'out');
      expect(r.rows.first.day, DateTime(2026, 10, 1));
      expect(r.rows[1].flow, 'in');
      expect(r.totalIn, 10000);
      expect(r.totalOut, 3500);
    });

    test('支付宝格式 + 分类列', () {
      const text = '交易时间,交易分类,交易对方,商品说明,收/支,金额,收/付款方式,交易状态\n'
          '2026/9/5 08:15,餐饮美食,某面馆,牛肉面,支出,28.00,余额宝,交易成功\n'
          '2026/9/6 20:00,转账红包,李四,还钱,收入,200.00,余额,交易成功\n';
      final r = parseBillCsv(text);
      expect(r.source, 'alipay');
      expect(r.rows.length, 2);
      expect(r.rows.first.category, '餐饮美食');
      expect(r.rows.first.day, DateTime(2026, 9, 5));
      expect(r.rows[1].cents, 20000);
    });

    test('简记自身导出的 CSV 也能读回来（含转账行跳过）', () async {
      final cash = (await store.allPockets(includeArchived: false)).first;
      await store.addEntry(
        bookId: bookId,
        pocketId: cash.id,
        flow: 'out',
        amountCents: 5000,
        memo: '导出测试',
        day: DateTime(2026, 10, 9),
      );
      final csv = await store.exportCsv(bookId);
      final r = parseBillCsv(csv);
      expect(r.rows.length, 1);
      expect(r.rows.first.cents, 5000);
      expect(r.rows.first.flow, 'out');
    });

    test('找不到表头要给出明确提示，而不是静默返回 0 条', () {
      final r = parseBillCsv('随便一段文字\n没有表头');
      expect(r.rows.isEmpty, isTrue);
      expect(r.warnings.first.contains('表头'), isTrue);
    });

    test('金额里的千分位和货币符号要能处理', () {
      const text = '日期,金额,收/支,备注\n2026-10-01,"¥1,234.56",支出,大额\n';
      final r = parseBillCsv(text);
      expect(r.rows.length, 1);
      expect(r.rows.first.cents, 123456);
    });

    test('去重指纹：同天同金额同备注视为同一条', () {
      final a = billFingerprint(DateTime(2026, 10, 1), 100, 'x');
      final b = billFingerprint(DateTime(2026, 10, 1), 100, 'x');
      final c = billFingerprint(DateTime(2026, 10, 1), 100, 'y');
      expect(a, b);
      expect(a == c, isFalse);
    });
  });

  group('高级搜索', () {
    test('类型 / 分类 / 金额区间 / 日期都能组合', () async {
      final pockets = await store.allPockets(includeArchived: false);
      final cash = pockets.first;
      final food = (await store.buckets(bookId, 'out')).first;
      final traffic = (await store.buckets(bookId, 'out'))[1];
      await store.addEntry(
          bookId: bookId,
          pocketId: cash.id,
          bucketId: food.id,
          flow: 'out',
          amountCents: 3000,
          memo: '午饭',
          day: DateTime(2026, 10, 1));
      await store.addEntry(
          bookId: bookId,
          pocketId: cash.id,
          bucketId: traffic.id,
          flow: 'out',
          amountCents: 300,
          memo: '地铁',
          day: DateTime(2026, 10, 2));
      await store.addEntry(
          bookId: bookId,
          pocketId: cash.id,
          flow: 'in',
          amountCents: 800000,
          memo: '工资',
          day: DateTime(2026, 10, 5));

      expect((await store.searchEntriesEx(bookId, flow: 'out')).length, 2);
      expect((await store.searchEntriesEx(bookId, flow: 'in')).length, 1);
      expect(
          (await store.searchEntriesEx(bookId, flow: 'out', bucketId: food.id))
              .length,
          1);
      // 金额 >= 100 元：只有工资（3000 分 = 30 元，不够）
      expect((await store.searchEntriesEx(bookId, minCents: 10000)).length, 1);
      // 金额 1~10 元：只剩地铁（午饭 30 元被排除）
      final small =
          await store.searchEntriesEx(bookId, minCents: 100, maxCents: 1000);
      expect(small.length, 1);
      expect(small.first.memo, '地铁');
      // 日期 10/1~10/2：只有前两笔
      expect(
          (await store.searchEntriesEx(bookId,
                  from: DateTime(2026, 10, 1), to: DateTime(2026, 10, 2)))
              .length,
          2);
      // 组合：10 月 + 支出 + 关键词「午饭」
      expect(
          (await store.searchEntriesEx(bookId,
                  keyword: '午饭', flow: 'out', from: DateTime(2026, 10, 1)))
              .length,
          1);
    });
  });
}
