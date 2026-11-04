import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/rules.dart';
import '../data/store.dart';
import '../services/app_log.dart';
import '../services/auto_backup.dart';
import '../state/ledger_state.dart';
import 'bill_import_page.dart';
import 'book_manage_page.dart';
import 'bucket_manage_page.dart';
import 'common.dart';
import 'category_migration_page.dart';
import 'export_page.dart';
import 'log_center_page.dart';
import 'statement_share_page.dart';
import 'data_actions.dart'
    show
        copyBackup,
        exportBackup,
        exportCsv,
        exportConfig,
        importConfig,
        importFromClipboard,
        confirmWipe,
        wipeAll,
        runWithProgress;
import 'motion.dart';
import 'pocket_manage_page.dart';
import 'recycle_bin_page.dart';
import 'storage_page.dart';
import 'tag_manage_page.dart';
import 'template_manage_page.dart';
import 'theme.dart';

/// 数据管理：概况、自动备份、孤儿清理、导入导出集中在这一页。
class DataManagePage extends ConsumerStatefulWidget {
  const DataManagePage({super.key});

  @override
  ConsumerState<DataManagePage> createState() => _DataManagePageState();
}

class _DataManagePageState extends ConsumerState<DataManagePage> {
  List<({String name, int bytes, DateTime at, String path})> _backups =
      const [];
  bool _loadingBackups = true;

  @override
  void initState() {
    super.initState();
    _loadBackups();
  }

  Future<void> _loadBackups() async {
    final files = await AutoBackup.list();
    final items = <({String name, int bytes, DateTime at, String path})>[];
    for (final f in files) {
      try {
        final stat = await f.stat();
        items.add((
          name: f.path.split(RegExp(r'[\\/]')).last,
          bytes: stat.size,
          at: stat.modified,
          path: f.path,
        ));
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _backups = items;
      _loadingBackups = false;
    });
  }

  Future<void> _backupNow() async {
    final store = await ref.read(storeProvider.future);
    final run = await AutoBackup.run(store);
    await _loadBackups();
    if (!mounted) return;
    // ⚠️ 不能再把「今天已备份」和「写盘失败」说成同一句话：
    // 磁盘满/序列化异常时用户看到"今天已经备份过了"，于是不再手动导出，
    // 而实际上一份都没存下来。
    ScaffoldMessenger.of(context).toast(switch (run.result) {
      AutoBackupResult.written => '已备份一份',
      AutoBackupResult.skipped => '今天已经备份过了',
      AutoBackupResult.failed => '备份失败：磁盘可能满了，请改用「导出备份」',
    });
  }

  Future<void> _restore(String path) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('用这份备份覆盖当前数据？'),
        content: const Text('当前所有记录会被替换，无法撤销。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('覆盖恢复', style: TextStyle(color: Palette.expense)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(storeProvider.future);
    // 覆盖前先留一份快照：恢复错了（选错文件）也得有退路。
    // 以前是「一个对话框 + 直接覆盖」，选错那份就是最后一份，就真没了。
    if (!mounted) return;
    final snapshot = await runWithProgress(
        context, '正在备份旧数据…', () => store.exportJson());
    try {
      final text = await AutoBackup.read(_fileOf(path));
      if (!mounted) return;
      await runWithProgress(
          context, '正在恢复备份…', () => store.importJson(text));
      if (!mounted) return;
      bumpRevision(ref);
      ScaffoldMessenger.of(context)
          .toast('已恢复（恢复前的数据已存为 automatic 备份）');
    } catch (e) {
      await _restoreSnapshotQuietly(store, snapshot);
      bumpRevision(ref);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .toast('恢复失败，详情见日志中心');
    }
  }

  static File _fileOf(String path) => File(path);

  /// 恢复失败时用覆盖前的快照把数据放回去（静默，只记日志）。
  Future<void> _restoreSnapshotQuietly(LedgerStore store, String json) async {
    try {
      await store.importJson(json);
    } catch (e) {
      AppLog.error('data', '恢复失败后回滚快照也失败了', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final countsAsync = ref.watch(tableCountsProvider);
    final bytesAsync = ref.watch(databaseBytesProvider);
    final orphanAsync = ref.watch(orphanStatsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('数据管理')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: [
          SectionLabel('管理'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const PocketManagePage())),
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: const Text('账户管理'),
                    subtitle: const Text('增改账户、信用卡、期初余额'),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const BucketManagePage())),
                  child: ListTile(
                    leading: const Icon(Icons.sell_outlined),
                    title: const Text('分类管理'),
                    subtitle: const Text('支出 / 收入分类自定义'),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const BookManagePage())),
                  child: ListTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: const Text('账本与汇率'),
                    subtitle: const Text('多账本、主币种、外币折算'),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const TagManagePage())),
                  child: ListTile(
                    leading: const Icon(Icons.sell_outlined),
                    title: const Text('标签'),
                    subtitle: const Text('改名 / 删除 / 按标签看账'),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const CategoryMigrationPage())),
                  child: ListTile(
                    leading: const Icon(Icons.swap_horiz),
                    title: const Text('分类迁移'),
                    subtitle: const Text('把这类的流水整批改到另一类'),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context).push(AppPageRoute(
                      page: StatementSharePage(month: DateTime.now()))),
                  child: const ListTile(
                    leading: Icon(Icons.ios_share),
                    title: Text('账单分享'),
                    subtitle: Text('把一个月的账发成图片，家人不用装 App'),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const RecycleBinPage())),
                  child: ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined),
                    title: const Text('回收站'),
                    subtitle: const Text('已删除的流水，可恢复或永久删除'),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const TemplateManagePage())),
                  child: const ListTile(
                    leading: Icon(Icons.bookmark_outlined),
                    title: Text('记账模板'),
                    subtitle: Text('把常用的账户/分类/金额存成快捷项'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('概况'),
          Panel(
            child: Column(
              children: [
                Row(
                  children: [
                    _stat(context, '流水',
                        countsAsync.valueOrNull?['entries'] ?? 0),
                    _stat(context, '账户',
                        countsAsync.valueOrNull?['pockets'] ?? 0),
                    _stat(context, '分类',
                        countsAsync.valueOrNull?['buckets'] ?? 0),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _stat(
                        context, '账本', countsAsync.valueOrNull?['books'] ?? 0),
                    _stat(
                        context, '借贷', countsAsync.valueOrNull?['debts'] ?? 0),
                    _stat(
                        context, '愿望', countsAsync.valueOrNull?['wishes'] ?? 0),
                  ],
                ),
                const Divider(height: 22),
                Row(
                  children: [
                    Icon(Icons.storage_outlined,
                        size: 16, color: Palette.inkSoft(context)),
                    const SizedBox(width: 6),
                    Text('数据库占用',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkSoft(context))),
                    const Spacer(),
                    Text(formatBytes(bytesAsync.valueOrNull ?? 0),
                        style: const TextStyle(
                            fontSize: 12, fontWeight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('自动备份',
              trailing: HeaderAction(
                label: '立即备份',
                onPressed: _backupNow,
              )),
          Panel(
            padding: EdgeInsets.zero,
            child: _loadingBackups
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: Column(
                      children: [
                        Skeleton(height: 44, radius: 10),
                        SizedBox(height: 8),
                        Skeleton(height: 44, radius: 10),
                      ],
                    ),
                  )
                : _backups.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text('还没有自动备份。每次打开 App 会自动备份一份，保留最近 5 份。',
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: Palette.inkFaint(context))),
                      )
                    : Column(
                        children: [
                          for (var i = 0; i < _backups.length; i++) ...[
                            if (i > 0) const Divider(height: 1, indent: 16),
                            ListTile(
                              dense: true,
                              leading: Icon(Icons.history,
                                  size: 18, color: Palette.inkSoft(context)),
                              title: Text(_backups[i].name,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(
                                '${_dt(_backups[i].at)} · ${formatBytes(_backups[i].bytes)}',
                                style: const TextStyle(fontSize: 10.5),
                              ),
                              trailing: PopupMenuButton<String>(
                                icon: const Icon(Icons.more_horiz, size: 18),
                                onSelected: (v) async {
                                  if (v == 'restore') {
                                    await _restore(_backups[i].path);
                                  } else if (v == 'share') {
                                    final text = await AutoBackup.read(
                                        _fileOf(_backups[i].path));
                                    await Share.share(text, subject: '简记备份');
                                  } else if (v == 'delete') {
                                    // 删除要确认：它删掉的很可能是唯一一份能救回数据的文件，
                                    // 而旁边的「恢复」「分享」都有二次确认。
                                    final yes = await showDialog<bool>(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        title: const Text('删除这份备份？'),
                                        content: const Text(
                                            '删除后这份备份无法找回。确定要删吗？'),
                                        actions: [
                                          TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(ctx, false),
                                              child: const Text('取消')),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(ctx, true),
                                            child: Text('删除',
                                                style: TextStyle(
                                                    color: Palette.expense)),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (yes != true) return;
                                    await AutoBackup.delete(
                                        _fileOf(_backups[i].path));
                                    await _loadBackups();
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'restore', child: Text('恢复')),
                                  PopupMenuItem(
                                      value: 'share', child: Text('分享出去')),
                                  PopupMenuItem(
                                      value: 'delete', child: Text('删除')),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
          ),
          const SizedBox(height: 18),
          SectionLabel('数据检查'),
          Panel(
            child: orphanAsync.when(
              skipLoadingOnReload: true,
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    Skeleton(height: 18, expand: true, radius: 6),
                    SizedBox(height: 8),
                    Skeleton(height: 18, expand: true, radius: 6),
                  ],
                ),
              ),
              error: (e, _) => LoadError(error: e, compact: true),
              data: (s) {
                final total = s.badPocket + s.badBucket;
                if (total == 0) {
                  return Row(
                    children: [
                      Icon(Icons.check_circle_outline,
                          size: 18, color: Palette.income),
                      const SizedBox(width: 8),
                      Text('没有发现孤儿数据',
                          style: TextStyle(
                              fontSize: 13, color: Palette.ink(context))),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('发现 $total 条流水指向了不存在的账户或分类',
                        style:
                            TextStyle(fontSize: 13, color: Palette.expense)),
                    const SizedBox(height: 4),
                    Text('账户缺失 ${s.badPocket} 条 · 分类缺失 ${s.badBucket} 条',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () async {
                          // 先取 messenger：await 之后再用 context 会踩 lint（也不安全）
                          final messenger = ScaffoldMessenger.of(context);
                          final store = await ref.read(storeProvider.future);
                          final book =
                              await ref.read(activeBookProvider.future);
                          final n = await store.fixOrphans(book.id);
                          bumpRevision(ref);
                          messenger.toast('已修复 $n 条');
                        },
                        child: const Text('一键修复'),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text('修复方式：账户缺失的归到第一个账户，分类缺失的记为「未分类」。',
                        style: TextStyle(
                            fontSize: 10.5,
                            height: 1.5,
                            color: Palette.inkFaint(context))),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('导入导出'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.upload_outlined),
                  title: const Text('导出备份'),
                  // 备份是"数据"的备份，不含凭证图片（图片走本机目录，
                  // 换了手机路径也无效）。不写明的话，换机后以为票据会跟着回来。
                  subtitle: const Text('通过系统分享发出去 · 不含凭证图片'),
                  onTap: () => exportBackup(context, ref),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.copy_all_outlined),
                  title: const Text('复制备份到剪贴板'),
                  subtitle: const Text('数据量小时的备用通道'),
                  onTap: () => copyBackup(context, ref),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.table_view_outlined),
                  title: const Text('导出 CSV'),
                  subtitle: const Text('Excel / WPS 可直接打开'),
                  onTap: () => exportCsv(context, ref),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const Text('从剪贴板导入'),
                  subtitle: const Text('会覆盖当前所有数据'),
                  onTap: () => importFromClipboard(context, ref),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: const Text('导出数据'),
                  subtitle: const Text('备份 / CSV / 配置，三种用途'),
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const ExportPage())),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.article_outlined),
                  title: const Text('日志中心'),
                  subtitle: const Text('出问题时看看发生了什么'),
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const LogCenterPage())),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore),
                  title: const Text('导出配置'),
                  subtitle: const Text('只带分类和账户结构，不带流水'),
                  onTap: () => exportConfig(context, ref),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore_outlined),
                  title: const Text('从剪贴板导入配置'),
                  subtitle: const Text('同名的分类/账户会跳过'),
                  onTap: () => importConfig(context, ref),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.sd_storage_outlined),
                  title: const Text('存储管理'),
                  subtitle: const Text('看数据库和备份占了多少'),
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const StoragePage())),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading: const Icon(Icons.download_for_offline_outlined),
                  title: const Text('账单导入'),
                  subtitle: const Text('微信 / 支付宝账单 CSV'),
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const BillImportPage())),
                ),
                const Divider(height: 1, indent: 16),
                ListTile(
                  leading:
                      Icon(Icons.delete_sweep_outlined, color: Palette.expense),
                  title:
                      Text('清空所有数据', style: TextStyle(color: Palette.expense)),
                  onTap: () async {
                    // 清空会连凭证图一起删、且没有回收站 ——
                    // 光一句「建议先导出备份」拦不住顺手一点。
                    // 这里改成两步：① 先自动存一份快照 ② 手输「清空」才给过。
                    final store = await ref.read(storeProvider.future);
                    final snap = await AutoBackup.run(store);
                    if (!context.mounted) return;
                    final ok = await confirmWipe(context);
                    if (ok == true && context.mounted) {
                      // 走 data_actions 里的统一实现：它还会清掉磁盘上的
                      // 凭证图片（只删库里的行会留下永远删不掉的占用）。
                      // 原来这里自己写了一遍，漏了附件那一步。
                      await wipeAll(context, ref);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).toast(snap.result ==
                              AutoBackupResult.failed
                          ? '已清空（清空前没能存下快照，磁盘可能已满）'
                          : '已清空（清空前的数据存在「自动备份」里）');
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(BuildContext context, String label, int value) {
    return Expanded(
      child: Column(
        children: [
          Text('$value',
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text(label,
              style:
                  TextStyle(fontSize: 10.5, color: Palette.inkFaint(context))),
        ],
      ),
    );
  }

  static String _dt(DateTime t) =>
      '${t.year}-${pad2(t.month)}-${pad2(t.day)} ${pad2(t.hour)}:${pad2(t.minute)}';
}
