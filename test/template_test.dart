import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory tmp;
  late LedgerStore store;
  late int bookId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-template-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
    bookId = (await store.books()).first.id;
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  group('模板 CRUD', () {
    test('新增后按 rank 升序返回，ID 自增', () async {
      final p = (await store.allPockets(includeArchived: false)).first;
      final id1 = await store.addTemplate(
        bookId: bookId,
        title: '午餐',
        glyph: '🍜',
        flow: 'out',
        pocketId: p.id,
        bucketId: (await store.buckets(bookId, 'out')).first.id,
        amountCents: 3500,
        memo: '公司楼下',
        tags: '餐',
      );
      final id2 = await store.addTemplate(
        bookId: bookId,
        title: '打车',
        glyph: '🚌',
        flow: 'out',
        pocketId: p.id,
        amountCents: 1800,
        memo: '',
        tags: '',
      );
      expect(id2, greaterThan(id1));

      final list = await store.templates(bookId);
      expect(list.length, 2);
      // rank 顺序：先加的 lunch 在前
      expect(list[0].title, '午餐');
      expect(list[0].rank, 0);
      expect(list[1].title, '打车');
    });

    test('编辑与删除', () async {
      final p = (await store.allPockets(includeArchived: false)).first;
      final id = await store.addTemplate(
        bookId: bookId,
        title: '旧名',
        glyph: '📋',
        flow: 'in',
        pocketId: p.id,
        amountCents: 100,
        memo: '',
        tags: '',
      );
      var t = (await store.templates(bookId)).first;
      await store.updateTemplate(t.copyWith(title: '新名', amountCents: 200));
      t = (await store.templates(bookId)).first;
      expect(t.title, '新名');
      expect(t.amountCents, 200);

      await store.deleteTemplate(id);
      expect(await store.templates(bookId), isEmpty);
    });
  });

  group('模板一键落库', () {
    test('支出模板落一笔，字段正确', () async {
      final p = (await store.allPockets(includeArchived: false)).first;
      final bucket = (await store.buckets(bookId, 'out')).first;
      final id = await store.addTemplate(
        bookId: bookId,
        title: '午餐',
        glyph: '🍜',
        flow: 'out',
        pocketId: p.id,
        bucketId: bucket.id,
        amountCents: 3500,
        memo: '公司楼下',
        tags: '餐',
      );
      final t = (await store.templates(bookId)).firstWhere((x) => x.id == id);
      final entryId = await store.addEntryFromTemplate(t, bookId);
      expect(entryId, greaterThan(0));

      final day = await store.entriesOfDay(bookId, DateTime.now());
      expect(day.length, 1);
      expect(day.first.amountCents, 3500);
      expect(day.first.flow, 'out');
      expect(day.first.bucketId, bucket.id);
      expect(day.first.pocketId, p.id);
      expect(day.first.memo, '公司楼下');
      expect(day.first.tags, '餐');
    });

    test('模板账户已不存在 → 抛 StateError', () async {
      final id = await store.addTemplate(
        bookId: bookId,
        title: '坏模板',
        glyph: '📋',
        flow: 'out',
        pocketId: 999999,
        amountCents: 100,
        memo: '',
        tags: '',
      );
      final t = (await store.templates(bookId)).firstWhere((x) => x.id == id);
      expect(() => store.addEntryFromTemplate(t, bookId),
          throwsA(isA<StateError>()));
    });

    test('转账模板缺转入账户 → 抛 StateError', () async {
      final p = (await store.allPockets(includeArchived: false)).first;
      final id = await store.addTemplate(
        bookId: bookId,
        title: '转账坏',
        glyph: '🔁',
        flow: 'transfer',
        pocketId: p.id,
        toPocketId: null,
        amountCents: 100,
        memo: '',
        tags: '',
      );
      final t = (await store.templates(bookId)).firstWhere((x) => x.id == id);
      expect(() => store.addEntryFromTemplate(t, bookId),
          throwsA(isA<StateError>()));
    });

    test('转账模板正常落两笔账户', () async {
      final pockets = await store.allPockets(includeArchived: false);
      final from = pockets[0];
      final to = pockets[1];
      final id = await store.addTemplate(
        bookId: bookId,
        title: '还信用卡',
        glyph: '🔁',
        flow: 'transfer',
        pocketId: from.id,
        toPocketId: to.id,
        amountCents: 5000,
        memo: '还款',
        tags: '',
      );
      final t = (await store.templates(bookId)).firstWhere((x) => x.id == id);
      await store.addEntryFromTemplate(t, bookId);
      final day = await store.entriesOfDay(bookId, DateTime.now());
      expect(day.length, 1);
      expect(day.first.flow, 'transfer');
      expect(day.first.pocketId, from.id);
      expect(day.first.toPocketId, to.id);
      expect(day.first.amountCents, 5000);
    });
  });

  group('导出导入', () {
    test('模板随备份往返', () async {
      final p = (await store.allPockets(includeArchived: false)).first;
      await store.addTemplate(
        bookId: bookId,
        title: '午餐',
        glyph: '🍜',
        flow: 'out',
        pocketId: p.id,
        bucketId: (await store.buckets(bookId, 'out')).first.id,
        amountCents: 3500,
        memo: '公司楼下',
        tags: '餐',
      );
      final json = await store.exportJson();
      expect(json.contains('"templates"'), isTrue);

      // 新库导入后模板还在
      final tmp2 = await Directory.systemTemp.createTemp('jianji-tpl-imp-');
      final store2 = await LedgerStore.open(path: '${tmp2.path}/imp.db');
      await store2.importJson(json);
      final imported = await store2.templates(bookId);
      expect(imported.length, 1);
      expect(imported.first.title, '午餐');
      expect(imported.first.amountCents, 3500);
      await store2.close();
      await tmp2.delete(recursive: true);
    });
  });
}
