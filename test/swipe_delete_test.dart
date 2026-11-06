import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/main.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 首页左滑删除 → 「已移入回收站 [撤销]」必须**自己走掉**。
///
/// 用户反馈：这条提示一直挂在屏幕下方不消失，只有再删一笔才会被换掉。
/// 原来完全依赖 `SnackBar.duration`（框架内部的 Timer），一旦那个计时器
/// 没起来（无障碍模式对带 action 的 SnackBar 刻意不设超时、动画没跑完
/// 就不会挂计时器），提示就永久留在树上。这里钉死「到点必走」。
void main() {
  const memo = '左滑删除测试';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await databaseFactory.getDatabasesPath();
    final path = '$dir/jianji_ledger.db';
    await databaseFactory.deleteDatabase(path);
    final seed = await LedgerStore.open(path: path);
    final book = (await seed.books()).first;
    // 预置账户里挑一个现金账户（不新建，避免默认账户为空时到处判空）。
    final pockets = await seed.allPockets();
    final pocketId = pockets.first.id;
    final buckets = await seed.buckets(book.id, 'out');
    await seed.addEntry(
      bookId: book.id,
      pocketId: pocketId,
      bucketId: buckets.isEmpty ? null : buckets.first.id,
      flow: 'out',
      amountCents: 5000,
      memo: memo,
      day: DateTime.now(),
    );
    await seed.close();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});
  });

  Future<void> drainAll(WidgetTester tester, {int rounds = 30}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('左滑删除后「已移入回收站」5 秒内自己消失', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: JianjiApp()));
    await tester.pump();
    // 启动幕：呼吸 180 + 张开 420，外加首页首帧的一批查询。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await drainAll(tester);

    expect(find.text(memo), findsOneWidget, reason: '种子流水应出现在首页');

    // 左滑过半 → Dismissible 判定删除
    await tester.drag(find.text(memo), const Offset(-600, 0));
    await drainAll(tester, rounds: 10);

    expect(find.text('已移入回收站'), findsOneWidget, reason: '删除后应有提示');
    expect(find.text(memo), findsNothing, reason: '被删的行应立刻消失');

    // 从弹出那一刻起算，6 秒后必须收掉（duration 5s + 进出场动画）。
    // 必须小步 pump：一次跳 6 秒没有中间帧，widget 会一直留在树上。
    var elapsed = 0;
    while (elapsed < 6000 && find.text('已移入回收站').evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 100));
      elapsed += 100;
    }
    expect(find.text('已移入回收站'), findsNothing,
        reason: '提示必须自己走掉，不能永久挂在下边');
  });
}
