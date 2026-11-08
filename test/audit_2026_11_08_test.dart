import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/update_config.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/state/ledger_state.dart';
import 'package:jianji/state/settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 2026-11-08 全面审计修掉的 P1/P2 的回归测试。
///
/// 这些坑的共同点：**界面上看不出来**，要么永远转圈、要么静默记错币种、
/// 要么设置重启就回默认。只能靠断言钉住。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tmp;
  late LedgerStore store;
  late int bookId;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-audit1108-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  Future<int> pocket(String currency) async {
    await store.addPocket(
      bookId: bookId,
      title: '$currency 账户',
      glyph: '👛',
      kind: PocketKind.cash,
      currency: currency,
      openingCents: 0,
    );
    return (await store.allPockets())
        .firstWhere((p) => p.currency == currency && p.title == '$currency 账户')
        .id;
  }

  // ---------------------------------------------------------------- P1-2

  test('更新清单地址永远不为空（空串不再覆盖默认值）', () {
    // build_jianji.sh 曾经无条件注入 --dart-define=UPDATE_URL=""，
    // 而 String.fromEnvironment「定义过就不看 defaultValue」→ 检查更新必然失效。
    expect(kUpdateManifestUrl.trim(), isNotEmpty);
    expect(kUpdateManifestUrl.startsWith('https://'), isTrue,
        reason: '清单必须走 HTTPS，否则 apkUrl 可被中间人替换');
    expect(kDefaultManifestUrl, kUpdateManifestUrl,
        reason: '测试里没注入 UPDATE_URL，应当落到写死的默认地址');
  });

  // ---------------------------------------------------------------- P1-1

  test('没点过账本胶囊时，模板 provider 仍取得到数据（不能永久 loading）', () async {
    final path = '${tmp.path}/tpl.db';
    final s = await LedgerStore.open(path: path, withSamplePockets: false);
    final book = (await s.books()).first;
    await s.addPocket(
      bookId: book.id,
      title: '现金',
      glyph: '👛',
      kind: PocketKind.cash,
      currency: 'CNY',
      openingCents: 0,
    );
    final p = (await s.allPockets()).first.id;
    await s.addTemplate(
      bookId: book.id,
      title: '午餐',
      glyph: '🍜',
      flow: 'out',
      pocketId: p,
      amountCents: 2000,
      memo: '',
      tags: '',
    );
    await s.close();

    final c = ProviderContainer(
      overrides: [databasePathProvider.overrideWithValue(path)],
    );
    addTearDown(c.dispose);

    // 前提：这正是真机上的初始状态（默认 null）
    expect(c.read(activeBookIdProvider), isNull);

    final templates = await c.read(activeTemplatesProvider.future);
    expect(templates.length, 1);
    expect(templates.first.title, '午餐');

    // 兜底后的账本 id 也必须是真的
    expect(c.read(currentBookIdProvider), book.id);
  });

  // ---------------------------------------------------------------- P1-3

  test('AA 回款不许跨币种：否则 100 USD 会被记成 ¥100', () async {
    final usd = await pocket('USD');
    final cny = await pocket('CNY');
    final id = await store.addEntry(
      bookId: bookId,
      pocketId: usd,
      flow: 'out',
      amountCents: 30000, // 300.00 USD
      splitCents: 20000, // 他人 200 USD
      memo: 'AA 垫付',
      day: DateTime(2026, 11, 8),
    );

    await expectLater(
      store.settleAa(id, cny),
      throwsA(isA<StateError>()),
      reason: '数据层必须自己拦，不能只靠界面过滤同币种账户',
    );

    // 同币种正常收回，并且币种被**冻结**成具体代码（不是 null）
    final settleId = await store.settleAa(id, usd, day: DateTime(2026, 11, 8));
    final rows = await store.entriesOfDay(bookId, DateTime(2026, 11, 8));
    final refund = rows.firstWhere((e) => e.id == settleId);
    expect(refund.currency, 'USD');
    expect(refund.amountCents, 20000);
    expect((await store.aaSettledByEntry(bookId))[id], 20000);
  });

  test('报销入账也不许跨币种', () async {
    final usd = await pocket('USD');
    final cny = await pocket('CNY');
    final id = await store.addEntry(
      bookId: bookId,
      pocketId: usd,
      flow: 'out',
      amountCents: 10000,
      reimburse: 1,
      memo: '差旅',
      day: DateTime(2026, 11, 8),
    );

    await expectLater(
      store.reimburseTo(id, cny),
      throwsA(isA<StateError>()),
    );
    final okId = await store.reimburseTo(id, usd);
    final rows = await store.entriesOfDay(bookId, DateTime.now());
    expect(rows.firstWhere((e) => e.id == okId).currency, 'USD');
  });

  test('部分收回后待收按同币种累计，收清不再多记', () async {
    final usd = await pocket('USD');
    final id = await store.addEntry(
      bookId: bookId,
      pocketId: usd,
      flow: 'out',
      amountCents: 30000,
      splitCents: 20000,
      memo: 'AA',
      day: DateTime(2026, 11, 8),
    );
    await store.settleAa(id, usd, amountCents: 5000, day: DateTime(2026, 11, 8));
    expect((await store.aaSettledByEntry(bookId))[id], 5000);
    // 再收剩下 15000（多传也要被 clamp 到待收）
    await store.settleAa(id, usd, amountCents: 99999, day: DateTime(2026, 11, 8));
    expect((await store.aaSettledByEntry(bookId))[id], 20000);
  });

  // ---------------------------------------------------------------- P2-14

  test('设置补水没完成时写偏好，不能静默丢盘', () async {
    SharedPreferences.setMockInitialValues({});
    final c = ProviderContainer();
    addTearDown(c.dispose);
    // 不要等补水：这就是竞态窗口里的那次写入
    await c.read(settingsProvider.notifier).setHideAmounts(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('hide_amounts'), isTrue,
        reason: '以前 _prefs 为 null 时这一行静默什么都不做，重启就变回去了');
    expect(c.read(settingsProvider).hideAmounts, isTrue);
  });
}
