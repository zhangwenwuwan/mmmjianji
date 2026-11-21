import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/ui/loans_page.dart';
import 'package:jianji/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 借贷关联账户的**界面**部分（1.4.79）。
///
/// 数据层的口径在 `debt_pocket_test.dart` 里钉死了，这里只管三件事：
///   1. 借贷详情能进「记一笔还款」，且还款表单里有「资金账户」这一行；
///   2. 默认跟随借贷本身关联的账户（不是每次都要重选）；
///   3. 选择器第一格是「不关联账户」—— 借贷本来就允许只记台账。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<void> settle(WidgetTester tester, {int rounds = 12}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> seed() async {
    final dir = await databaseFactory.getDatabasesPath();
    try {
      await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
    } catch (_) {
      // 删不掉就沿用旧库，本用例只关心界面
    }
    final store = await LedgerStore.open();
    final book = (await store.books()).first;
    await store.addPocket(
      bookId: book.id,
      title: '工资卡',
      glyph: 'ic:acc_bank',
      kind: PocketKind.bank,
      currency: 'CNY',
      openingCents: 0,
    );
    final pid = (await store.allPockets())
        .firstWhere((p) => p.title == '工资卡')
        .id;
    await store.addDebt(Debt(
      id: 0,
      bookId: book.id,
      direction: 'borrow',
      counterparty: '老王',
      channel: 'personal',
      principalCents: 100000,
      currency: 'CNY',
      borrowedOn: DateTime(2026, 11, 1),
      dueOn: null,
      note: '',
      interestRate: null,
      closed: false,
      pocketId: pid,
    ));
    await store.close();
  }

  testWidgets('借贷详情 → 还款表单：资金账户默认跟随借贷，第一格是「不关联」', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.runAsync(seed);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const LoansPage(),
      ),
    ));
    await settle(tester);

    // 列表里能看到这笔借贷，且副标题标了关联账户
    expect(find.text('老王'), findsOneWidget);
    expect(find.textContaining('工资卡'), findsWidgets);
    expect(find.textContaining('我欠别人'), findsWidgets);

    await tester.tap(find.text('老王'));
    await settle(tester);
    expect(find.text('借贷详情'), findsOneWidget);

    await tester.tap(find.textContaining('记一笔还款'));
    await settle(tester);

    // 还款表单：金额 + 资金账户
    expect(find.text('资金账户'), findsOneWidget);
    expect(find.text('工资卡'), findsWidgets, reason: '默认跟随借贷关联的账户');

    // 打开账户选择器：第一格必须是「不关联账户」
    await tester.tap(find.text('资金账户'));
    await settle(tester);
    expect(find.text('不关联账户'), findsOneWidget);
    expect(find.text('只记台账，不动余额'), findsOneWidget);

    await tester.tap(find.text('不关联账户'));
    await settle(tester);
    expect(tester.takeException(), isNull);
  });
}
