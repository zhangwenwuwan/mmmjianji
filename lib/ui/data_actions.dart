import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../data/store.dart';
import '../state/ledger_state.dart';
import '../services/app_log.dart';
import '../services/attachment_service.dart';
import '../state/settings.dart';
import 'theme.dart';
import 'common.dart';

/// 数据相关的共用动作：导出备份 / 导出 CSV / 从剪贴板导入 / 清空。
///
/// 抽出来是因为「我的」和「数据管理」两个页面都要用，
/// 复制两份迟早会不一致（导出格式一改就漏一个）。
Future<void> exportBackup(BuildContext context, WidgetRef ref) async {
  final store = await ref.read(storeProvider.future);
  if (!context.mounted) return;
  final json = await runWithProgress(
      context, '正在生成备份…', () => store.exportJson());
  try {
    final result = await Share.share(json, subject: '简记备份');
    // ⚠️ 必须看分享结果：用户在系统面板里点空白取消，以前照样记「已备份」，
    // 于是首页的备份提醒永久消失 —— 而实际上一份都没导出过。
    if (result.status == ShareResultStatus.dismissed) {
      if (context.mounted) _toast(context, '已取消，这次不算备份');
      return;
    }
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: json));
    if (!context.mounted) return;
    _toast(context, '分享不可用，已复制到剪贴板');
  }
  // 到了这里说明备份内容已经出了 App（分享面板或剪贴板），
  // 首页的「备份提醒」据此消失。
  await ref.read(settingsProvider.notifier).markBackedUp();
  if (context.mounted) {
    _toast(context, '已备份（${(json.length / 1024).toStringAsFixed(1)} KB）');
  }
}

Future<void> copyBackup(BuildContext context, WidgetRef ref) async {
  final store = await ref.read(storeProvider.future);
  if (!context.mounted) return;
  final json = await runWithProgress(
      context, '正在生成备份…', () => store.exportJson());
  await Clipboard.setData(ClipboardData(text: json));
  // ⚠️ 复制到剪贴板**不算备份完成**（2026-11-08 审计 P2-7）：
  // 剪贴板是易失的（重启就没了、能被输入法/其他 App 读到），
  // 以前在这里调 markBackedUp()，首页的「该备份了」提醒永久消失，
  // 用户以为有备份，实际上什么都没留下。
  // 现在提醒照旧，并在提示里说清楚"这只是临时中转"。
  if (!context.mounted) return;
  _toast(context,
      '已复制到剪贴板（${(json.length / 1024).toStringAsFixed(1)} KB）· 临时中转，建议用「导出备份」存成文件');
}

Future<void> exportCsv(BuildContext context, WidgetRef ref) async {
  final store = await ref.read(storeProvider.future);
  final book = await ref.read(activeBookProvider.future);
  final csv = await store.exportCsv(book.id);
  final rows = (csv.split('\r\n').length - 2).clamp(0, 1 << 30);
  try {
    await Share.share(csv, subject: '简记-${book.title}-账单.csv');
    if (context.mounted) _toast(context, '已导出 CSV（$rows 行）');
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: csv));
    if (!context.mounted) return;
    _toast(context, '分享不可用，已复制 CSV 到剪贴板（$rows 行）');
  }
}

/// 从剪贴板导入（覆盖式）。返回是否导入成功。
Future<bool> importFromClipboard(BuildContext context, WidgetRef ref) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final text = data?.text?.trim() ?? '';
  if (text.isEmpty) {
    if (context.mounted) _toast(context, '剪贴板里没有内容');
    return false;
  }
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('导入备份？'),
      content: const Text('当前所有数据会被覆盖，且无法撤销。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text('覆盖导入', style: TextStyle(color: Palette.expense)),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  final store = await ref.read(storeProvider.future);
  // 覆盖前先留一份快照：以前是「一个对话框 + 直接覆盖」，
  // 恢复错了没有任何退路（旧数据当场没了）。
  if (!context.mounted) return false;
  final snapshot = await runWithProgress(
      context, '正在备份旧数据…', () => store.exportJson());
  try {
    if (!context.mounted) return false;
    await runWithProgress(
        context, '正在导入备份…', () => store.importJson(text));
    // 备份不含凭证：把本机旧附件一起清掉，免得挂到恢复出来的新流水上。
    // ⚠️ 必须在导入**成功之后**再删 —— 放在事务前面的话，导入半途失败时
    // 旧数据已被覆盖、图也没了，两头空。
    await AttachmentService.deleteAll();
    bumpRevision(ref);
    if (context.mounted) {
      _toast(context, '导入完成（覆盖前的旧数据已存为 automatic 备份）');
    }
    return true;
  } on FormatException catch (e) {
    // 导入失败：用快照把数据救回来，别让用户发现"点了一下什么都变了"
    await _restoreSnapshotQuietly(store, snapshot);
    bumpRevision(ref);
    if (context.mounted) _toast(context, '导入失败：${e.message}（数据没变）');
    return false;
  } catch (e) {
    // 用新版备份恢复到旧版时，备份里会多一个当前表没有的列 →
    // insert 抛 DatabaseException（不是 FormatException）。
    // 原来没人接 → 事务回滚、界面毫无反应，用户以为按钮坏了。
    await _restoreSnapshotQuietly(store, snapshot);
    bumpRevision(ref);
    if (context.mounted) _toast(context, '导入失败：$e（数据没变）');
    return false;
  }
}

/// 静默回滚：导入失败时用覆盖前的快照把数据恢复回去。
///
/// 失败也只记日志 —— 这时候再弹一个错误框只会让人更慌，
/// 用户需要知道的是「你的数据还在」。
Future<void> _restoreSnapshotQuietly(LedgerStore store, String json) async {
  try {
    await store.importJson(json);
  } catch (e) {
    AppLog.error('data', '导入失败后回滚快照也失败了', e);
  }
}

/// 清空所有数据。
///
/// 两道防线（以前只有一道对话框，注释里却写着"双重确认"）：
/// 1. 进入前**自动导一份备份**（见 [requestWipe] 里的说明）；
/// 2. 页面里的确认对话框要求手输「清空」两字。
///
/// 凭证图会一起删 —— 这是"清空"该有的语义，但备份里不含图片，
/// 所以必须先把备份交出去，否则连翻图回忆的机会都没有。
Future<void> wipeAll(BuildContext context, WidgetRef ref) async {
  final store = await ref.read(storeProvider.future);
  await store.wipe();
  // 数据库清空了，磁盘上的附件图也要清，否则「存储管理」永远有占用
  await AttachmentService.deleteAll();
  ref.read(activeBookIdProvider.notifier).state = null;
  bumpRevision(ref);
  if (context.mounted) _toast(context, '已清空');
}

/// 清空前的**第二道确认**：必须手输「清空」两字才给过。
///
/// 为什么不用普通的是/否对话框：清空会连凭证图一起删、且没有回收站，
/// 手滑点一下就没了。打字这一步能把"顺手点了确认"挡掉。
Future<bool> confirmWipe(BuildContext context) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('清空所有数据'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('流水、账户、分类、账本、凭证图片会全部删除，无法撤销。'),
            const SizedBox(height: 10),
            Text('确认请输入「清空」两个字：',
                style: TextStyle(fontSize: 12, color: Palette.inkSoft(ctx))),
            const SizedBox(height: 6),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8)),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              onChanged: (_) => setLocal(() {}),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: ctrl.text.trim() == '清空'
                ? () => Navigator.pop(ctx, true)
                : null,
            child: Text('确认清空', style: TextStyle(color: Palette.expense)),
          ),
        ],
      ),
    ),
  );
  return ok == true;
}

void _toast(BuildContext context, String text) {
  ScaffoldMessenger.of(context).toast(text);
}

/// 跑一个「可能要几秒」的异步动作，期间盖一个不可点的进度框。
///
/// 大账本导出 / 导入整库 JSON 会明显卡一下（尤其导入要逐表插入几千行），
/// 以前只有结束后的 toast，中间界面一动不动，用户会以为按钮没反应。
Future<T> runWithProgress<T>(
    BuildContext context, String label, Future<T> Function() run) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: Dialog(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    return await run();
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}

/// 导出「配置」（不含流水）：偏好设置 + 分类结构 + 账户结构。
///
/// 对齐原版的配置导入导出：换手机时想把分类/账户搭好的结构搬过去，
/// 但又不想带上流水，就用这个。
Future<void> exportConfig(BuildContext context, WidgetRef ref) async {
  final store = await ref.read(storeProvider.future);
  final book = await ref.read(activeBookProvider.future);
  final settings = ref.read(settingsProvider);
  final bucketsOut = await store.buckets(book.id, 'out', includeArchived: true);
  final bucketsIn = await store.buckets(book.id, 'in', includeArchived: true);
  final pockets = await store.allPockets();

  Map<String, Object?> bucketJson(Bucket b) => {
        'title': b.title,
        'glyph': b.glyph,
        'archived': b.archived,
        // 用父分类的标题表示层级，导入时再按标题找回 id
        'parent': b.parentId == null
            ? null
            : (bucketsOut.where((x) => x.id == b.parentId).firstOrNull?.title ??
                bucketsIn.where((x) => x.id == b.parentId).firstOrNull?.title),
      };

  final payload = const JsonEncoder.withIndent('  ').convert({
    'app': 'jianji',
    'kind': 'config',
    'version': 1,
    'settings': {
      'palette': settings.paletteId,
      'fontScale': settings.fontScale,
      'symbol': settings.symbol,
      'themeMode': settings.themeMode.name,
      'compactAmounts': settings.compactAmounts,
      'noteDisplay': settings.noteDisplay,
    },
    'baseCurrency': book.baseCurrency,
    'book': {'title': book.title, 'glyph': book.glyph},
    'buckets': {
      'out': bucketsOut.map(bucketJson).toList(),
      'in': bucketsIn.map(bucketJson).toList(),
    },
    'pockets': [
      for (final p in pockets)
        {
          'title': p.title,
          'glyph': p.glyph,
          'kind': p.kind.name,
          'currency': p.currency,
        },
    ],
  });

  try {
    await Share.share(payload, subject: '简记配置');
  } catch (_) {
    await Clipboard.setData(ClipboardData(text: payload));
    if (!context.mounted) return;
    _toast(context, '分享不可用，已复制到剪贴板');
  }
}

/// 从剪贴板导入配置：只补分类 / 账户结构，不动流水。
Future<void> importConfig(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  if (!context.mounted) return;
  final text = data?.text?.trim() ?? '';
  if (text.isEmpty) {
    _toast(context, '剪贴板是空的');
    return;
  }
  Map<String, Object?> decoded;
  try {
    final raw = jsonDecode(text);
    if (raw is! Map<String, Object?> || raw['kind'] != 'config') {
      _toast(context, '不是简记的配置文件');
      return;
    }
    decoded = raw;
  } catch (_) {
    _toast(context, '配置内容解析失败');
    return;
  }

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('导入配置？'),
      content: const Text('会把配置里的分类和账户补进来（同名的会跳过），不影响已有流水。'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true), child: const Text('导入')),
      ],
    ),
  );
  if (ok != true) return;
  if (!context.mounted) return;

  final store = await ref.read(storeProvider.future);
  final book = await ref.read(activeBookProvider.future);

  var addedBuckets = 0;
  var addedPockets = 0;

  // 分类：先建一级（parent 为 null），再建二级（按 parent 标题找 id）
  final bucketsJson = decoded['buckets'];
  if (bucketsJson is Map) {
    for (final flow in const ['out', 'in']) {
      final list = bucketsJson[flow];
      if (list is! List) continue;
      final existing =
          await store.buckets(book.id, flow, includeArchived: true);
      final byTitle = {for (final b in existing) b.title: b.id};

      // 第一轮：一级分类
      for (final item in list) {
        if (item is! Map) continue;
        final title = (item['title'] as String?)?.trim() ?? '';
        if (title.isEmpty || byTitle.containsKey(title)) continue;
        if ((item['parent'] as String?) != null) continue;
        await store.addBucket(
          bookId: book.id,
          title: title,
          glyph: (item['glyph'] as String?) ?? '🧾',
          flow: flow,
        );
        addedBuckets++;
      }
      // 第二轮：二级分类
      final refreshed =
          await store.buckets(book.id, flow, includeArchived: true);
      final titlesNow = {for (final b in refreshed) b.title: b.id};
      for (final item in list) {
        if (item is! Map) continue;
        final title = (item['title'] as String?)?.trim() ?? '';
        final parent = item['parent'] as String?;
        if (title.isEmpty || parent == null) continue;
        if (titlesNow.containsKey(title)) continue;
        final parentId = titlesNow[parent];
        if (parentId == null) continue;
        await store.addBucket(
          bookId: book.id,
          title: title,
          glyph: (item['glyph'] as String?) ?? '🧾',
          flow: flow,
          parentId: parentId,
        );
        addedBuckets++;
      }
    }
  }

  // 账户
  final pocketsJson = decoded['pockets'];
  if (pocketsJson is List) {
    final existing = await store.allPockets();
    final titles = {for (final p in existing) p.title};
    for (final item in pocketsJson) {
      if (item is! Map) continue;
      final title = (item['title'] as String?)?.trim() ?? '';
      if (title.isEmpty || titles.contains(title)) continue;
      await store.addPocket(
        bookId: book.id,
        title: title,
        glyph: (item['glyph'] as String?) ?? '👛',
        kind: PocketKind.values.firstWhere(
          (k) => k.name == item['kind'],
          orElse: () => PocketKind.cash,
        ),
        currency: (item['currency'] as String?) ?? book.baseCurrency,
        openingCents: 0,
      );
      addedPockets++;
    }
  }

  bumpRevision(ref);
  messenger.toast('已导入：$addedBuckets 个分类、$addedPockets 个账户');
}
