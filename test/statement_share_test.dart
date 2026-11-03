import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/ui/statement_share_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 账单分享页（给家人看的那张图）。
///
/// 盯三件事：
/// 1. 明细真的画出来了（备注能搜到）；
/// 2. 「不计入收支」的流水**不能**出现在账单里 —— 否则家人会看到一笔对不上账的支出；
/// 3. 笔数统计和实际行数一致。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late String dbPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jj-stmt-');
    dbPath = '${tmp.path}/s.db';
    SharedPreferences.setMockInitialValues({});
    final store = await LedgerStore.open(path: dbPath);
    final book = (await store.books()).first;
    final pocket = (await store.allPockets(includeArchived: false)).first;
    final bucket = (await store.buckets(book.id, 'out')).first;
    final today = DateTime.now();

    await store.addEntry(
      bookId: book.id,
      pocketId: pocket.id,
      bucketId: bucket.id,
      flow: 'out',
      amountCents: 3550,
      memo: '家里买菜',
      day: today,
    );
    await store.addEntry(
      bookId: book.id,
      pocketId: pocket.id,
      flow: 'in',
      amountCents: 10000,
      memo: '工资入账',
      day: today,
    );
    // 这笔标了「不计入收支」——账单里不该出现
    await store.addEntry(
      bookId: book.id,
      pocketId: pocket.id,
      bucketId: bucket.id,
      flow: 'out',
      amountCents: 9999,
      memo: '内部调账别外传',
      day: today,
      excludeFromStats: true,
    );
    await store.close();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  /// 交替推进真实时间与假时钟，等 FutureBuilder 的加载跑完。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  testWidgets('列出明细，并排除「不计入收支」的流水', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [databasePathProvider.overrideWithValue(dbPath)],
      child: MaterialApp(home: StatementSharePage(month: DateTime.now())),
    ));
    await settle(tester);

    expect(find.text('账单分享'), findsOneWidget);
    expect(find.textContaining('家里买菜'), findsOneWidget);
    expect(find.textContaining('工资入账'), findsOneWidget);
    // 关键的排除逻辑
    expect(find.textContaining('内部调账别外传'), findsNothing);
    // 汇总只算这两笔
    expect(find.textContaining('共 2 笔'), findsOneWidget);
  });
}
