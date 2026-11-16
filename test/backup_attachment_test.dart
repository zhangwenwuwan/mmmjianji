import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 备份恢复的凭证关联回归。
///
/// 旧行为：importJson 无条件 `delete('attachments')` —— 同一台手机导出再恢复，
/// 凭证图片文件还在磁盘上，但「哪张图属于哪笔账」的关联全丢了。
/// 新行为：关联行随备份导出/恢复，且只恢复文件还在本机的那些行
/// （跨设备时 path 指向另一台机器的私有目录，硬插只会得到点不开的坏图）。

void main() {
  late Directory tmp;
  late LedgerStore store;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji-attach-');
    store = await LedgerStore.open(path: '${tmp.path}/test.db');
  });

  tearDown(() async {
    await store.close();
    await tmp.delete(recursive: true);
  });

  Future<int> seedOneEntryWithAttachment() async {
    final book = await store.addBook('测试账本', 'wallet', 'CNY');
    await store.addPocket(
      bookId: book,
      title: '现金',
      glyph: 'wallet',
      kind: PocketKind.cash,
      currency: 'CNY',
      openingCents: 10000,
    );
    final pocket = (await store.allPockets()).firstWhere((p) => p.bookId == book);
    final entryId = await store.addEntry(
      bookId: book,
      pocketId: pocket.id,
      bucketId: null,
      flow: 'out',
      amountCents: 1234,
      memo: '凭证测试',
      day: DateTime(2026, 11, 16),
      tags: '',
      reimburse: 0,
    );
    final image = File('${tmp.path}/receipt.jpg');
    await image.writeAsString('fake-image-bytes');
    await store.addAttachment(
        bookId: book, entryId: entryId, path: image.path, name: '小票');
    return entryId;
  }

  test('导出再导入：凭证关联保留', () async {
    final entryId = await seedOneEntryWithAttachment();
    final raw = await store.exportJson();

    final decoded = jsonDecode(raw) as Map;
    expect(decoded['attachments'], isNotNull, reason: '备份必须带附件关联行');

    await store.importJson(raw);
    final restored = await store.attachmentsOf(entryId);
    expect(restored.length, 1);
    expect(restored.single.name, '小票');
    expect(File(restored.single.path).existsSync(), isTrue);
  });

  test('文件已不存在的凭证行不会恢复成坏图', () async {
    final entryId = await seedOneEntryWithAttachment();
    final raw = await store.exportJson();

    await File('${tmp.path}/receipt.jpg').delete();
    await store.importJson(raw);

    expect(await store.attachmentsOf(entryId), isEmpty);
  });

  test('旧备份（没有 attachments 字段）仍能导入，不报错', () async {
    final raw = await store.exportJson();
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    decoded.remove('attachments');

    await store.importJson(jsonEncode(decoded));
    expect(await store.books(), isNotEmpty);
  });
}
