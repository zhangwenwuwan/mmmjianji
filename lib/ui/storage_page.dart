import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../services/attachment_service.dart';
import '../services/auto_backup.dart';
import '../state/ledger_state.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 存储管理：数据库 / 自动备份 / 各类数据各占多少。
///
/// 对齐原版的存储管理页。数据全在本地，用户需要知道"我的数据有多大、
/// 备份堆了几份、能不能清"，所以这一页只做只读统计 + 清理备份。
class StoragePage extends ConsumerStatefulWidget {
  const StoragePage({super.key});

  @override
  ConsumerState<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends ConsumerState<StoragePage> {
  List<({String name, int bytes, DateTime at})> _backups = const [];
  int _dbBytes = 0;

  /// null = 读不到（不要假装是 0，那会让人以为没有附件占用）
  int? _attachBytes = 0;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    try {
      await _loadInner();
    } catch (e) {
      // 原来这里没有 try：AutoBackup.list() 一抛，_loading 永远停在 true，
      // 页面就是一块永远不消失的骨架屏。
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadInner() async {
    final files = await AutoBackup.list();
    final items = <({String name, int bytes, DateTime at})>[];
    for (final f in files) {
      try {
        final stat = await f.stat();
        items.add((
          name: f.path.split(RegExp(r'[\\/]')).last,
          bytes: stat.size,
          at: stat.modified,
        ));
      } catch (_) {}
    }
    items.sort((a, b) => b.at.compareTo(a.at));
    final dbBytes = ref.read(databaseBytesProvider).valueOrNull ?? 0;
    int? attachBytes = 0;
    try {
      final book = await ref.read(activeBookProvider.future);
      // 直接量磁盘目录，而不是按 attachments 表里的路径求和：
      // 表里没有的孤儿图（旧版本清空数据时漏删的）也是真实占用，
      // 按表求和的写法会把它算成 0，用户永远清不掉也看不见。
      attachBytes = await AttachmentService.totalBytes(book.id);
    } catch (_) {
      attachBytes = null; // 读不到就显示「—」，不要谎报 0
    }
    if (!mounted) return;
    setState(() {
      _backups = items;
      _dbBytes = dbBytes;
      _attachBytes = attachBytes;
      _error = null;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final backupBytes = _backups.fold<int>(0, (s, b) => s + b.bytes);
    final counts = ref.watch(tableCountsProvider).valueOrNull ?? const {};

    return Scaffold(
      appBar: AppBar(
        title: const Text('存储管理'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading
          ? const SkeletonList()
          : _error != null
              ? ErrorRetryView(
                  message: '存储信息读取失败',
                  detail: '$_error',
                  onRetry: _load,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
                  children: [
                    SectionLabel('占用'),
                    Panel(
                      child: Column(
                        children: [
                          _row(
                              context, '数据库', _dbBytes, Icons.storage_outlined),
                          const SizedBox(height: 12),
                          _rowMaybe(context, '凭证附件', _attachBytes,
                              Icons.photo_library_outlined),
                          const SizedBox(height: 12),
                          _row(context, '自动备份（${_backups.length} 份）',
                              backupBytes, Icons.backup_outlined),
                          const Divider(height: 22),
                          _row(
                              context,
                              '合计',
                              _dbBytes + backupBytes + (_attachBytes ?? 0),
                              Icons.data_usage_outlined,
                              strong: true),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    SectionLabel('数据量'),
                    Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 20,
                            runSpacing: 12,
                            children: [
                              _stat(context, '流水', counts['entries'] ?? 0),
                              _stat(context, '账户', counts['pockets'] ?? 0),
                              _stat(context, '分类', counts['buckets'] ?? 0),
                              _stat(context, '账本', counts['books'] ?? 0),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '数据存在应用私有目录，卸载应用会一并删除。换手机请先导出备份。',
                            style: TextStyle(
                                fontSize: 12,
                                height: 1.5,
                                color: Palette.inkFaint(context)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    SectionLabel('自动备份'),
                    Panel(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < _backups.length; i++) ...[
                            if (i > 0) const Divider(height: 1, indent: 16),
                            ListTile(
                              dense: true,
                              leading: Icon(Icons.description_outlined,
                                  size: 18, color: Palette.inkSoft(context)),
                              title: Text(_backups[i].name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13)),
                              subtitle: Text(
                                '${_dt(_backups[i].at)} · ${formatBytes(_backups[i].bytes)}',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: Palette.inkFaint(context)),
                              ),
                            ),
                          ],
                          if (_backups.isEmpty)
                            Padding(
                              padding: const EdgeInsets.all(18),
                              child: Text('还没有自动备份',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Palette.inkFaint(context))),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '每次打开 App 会自动备份一份，只保留最近 5 份，旧备份会被自动清掉。',
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: Palette.inkFaint(context)),
                    ),
                  ],
                ),
    );
  }

  /// [bytes] 为 null 表示读不到，显示「—」而不是 0
  Widget _rowMaybe(
          BuildContext context, String label, int? bytes, IconData icon,
          {bool strong = false}) =>
      bytes == null
          ? _rowText(context, label, '—', icon, strong: strong)
          : _row(context, label, bytes, icon, strong: strong);

  Widget _rowText(
      BuildContext context, String label, String value, IconData icon,
      {bool strong = false}) {
    return Row(
      children: [
        Icon(icon,
            size: 18,
            color: strong ? Palette.brand(context) : Palette.inkSoft(context)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: strong ? 14 : 13,
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
                  color: strong
                      ? Palette.ink(context)
                      : Palette.inkSoft(context))),
        ),
        Text(value,
            style: TextStyle(
                fontSize: strong ? 14 : 13,
                fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
                color: strong ? Palette.brand(context) : Palette.ink(context))),
      ],
    );
  }

  Widget _row(BuildContext context, String label, int bytes, IconData icon,
      {bool strong = false}) {
    return Row(
      children: [
        Icon(icon,
            size: 18,
            color: strong ? Palette.brand(context) : Palette.inkSoft(context)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: strong ? 14 : 13,
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w400,
                  color: strong
                      ? Palette.ink(context)
                      : Palette.inkSoft(context))),
        ),
        Text(
          formatBytes(bytes),
          style: TextStyle(
              fontSize: strong ? 14 : 13,
              fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
              color: strong ? Palette.brand(context) : Palette.ink(context),
              fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }

  Widget _stat(BuildContext context, String label, int value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        Text(label,
            style: TextStyle(fontSize: 10.5, color: Palette.inkFaint(context))),
      ],
    );
  }

  static String _dt(DateTime t) =>
      '${t.year}-${pad2(t.month)}-${pad2(t.day)} ${pad2(t.hour)}:${pad2(t.minute)}';
}
