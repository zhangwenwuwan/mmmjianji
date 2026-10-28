import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/ledger_state.dart';
import 'common.dart';
import 'data_actions.dart'
    show copyBackup, exportBackup, exportConfig, exportCsv;
import 'theme.dart';

/// 数据导出：想带走数据时，先弄清「导什么」。
///
/// 对齐原版 export_page：把三种导出的区别讲明白，而不是丢一排按钮。
class ExportPage extends ConsumerWidget {
  const ExportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final counts = ref.watch(tableCountsProvider).valueOrNull ?? const {};
    final entries = counts['entries'] ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('导出数据')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          Text(
            '三种导出用途不同，按需要选：',
            style: TextStyle(fontSize: 12, color: Palette.inkSoft(context)),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            icon: Icons.backup_outlined,
            title: '完整备份（JSON）',
            desc: '包含全部账目、账户、分类、标签、预算、借贷、愿望。'
                '换手机恢复用这个，能原样还原。',
            badge: '$entries 条流水',
            actionLabel: '导出备份',
            onAction: () => exportBackup(context, ref),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            icon: Icons.table_view_outlined,
            title: '流水表格（CSV）',
            desc: '只导流水明细，Excel / WPS 直接打开。'
                '适合自己再做统计，不能用来恢复。',
            actionLabel: '导出 CSV',
            onAction: () => exportCsv(context, ref),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            icon: Icons.settings_backup_restore,
            title: '配置（JSON，不含流水）',
            desc: '只带分类结构、账户结构和外观设置。'
                '把搭好的分类体系搬到另一台手机，但不要账目时用。',
            actionLabel: '导出配置',
            onAction: () => exportConfig(context, ref),
          ),
          const SizedBox(height: 12),
          _card(
            context,
            icon: Icons.copy_all_outlined,
            title: '复制备份到剪贴板',
            desc: '数据量小的时候的备用通道，直接粘贴到聊天窗口存着。',
            actionLabel: '复制备份',
            onAction: () => copyBackup(context, ref),
          ),
          const SizedBox(height: 18),
          Panel(
            child: Row(
              children: [
                Icon(Icons.lock_outline,
                    size: 16, color: Palette.inkFaint(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '导出全程在本机完成，文件由你自己决定发给谁。',
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: Palette.inkFaint(context)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String desc,
    required String actionLabel,
    required VoidCallback onAction,
    String? badge,
  }) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: Palette.brand(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Palette.ink(context))),
              ),
              if (badge != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Palette.brand(context).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(badge,
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: Palette.brand(context))),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(desc,
              style: TextStyle(
                  fontSize: 12, height: 1.55, color: Palette.inkSoft(context))),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 40,
            child: OutlinedButton(
              onPressed: onAction,
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(actionLabel, style: const TextStyle(fontSize: 13)),
            ),
          ),
        ],
      ),
    );
  }
}
