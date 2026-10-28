import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/version.dart';
import 'common.dart';
import 'theme.dart';

/// 关于简记：版本、本地优先的说明、以及数据都去了哪里。
class AboutPage extends ConsumerWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('关于简记')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 28),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Palette.brand(context).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    Icons.receipt_long_outlined,
                    size: 26,
                    color: Palette.brand(context),
                  ),
                ),
                const SizedBox(height: 8),
                Text('简记',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Palette.ink(context),
                    )),
                const SizedBox(height: 4),
                Text('版本 $appVersion（$appBuild）',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkFaint(context))),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('一个本地优先的个人记账应用',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Palette.ink(context),
                    )),
                const SizedBox(height: 8),
                Text(
                  '不联网、不要账号，所有数据都留在你自己的手机里。'
                  '断网也能照常记账，换手机时用「数据管理」里的备份导出带走。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: Palette.inkSoft(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _row(context, Icons.wifi_off_outlined, '不联网', '没有服务器，也没有同步队列'),
                const Divider(height: 1, indent: 16),
                _row(context, Icons.lock_outline, '可选应用锁', '切后台回来要输 PIN'),
                const Divider(height: 1, indent: 16),
                _row(context, Icons.file_download_outlined, '备份在你手里',
                    'JSON / CSV 导出，想存哪存哪'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('数据存放在哪',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: Palette.ink(context),
                    )),
                const SizedBox(height: 6),
                Text(
                  '应用私有目录下的本地数据库，卸载应用会一并删除。'
                  '自动备份写在应用备份目录里，保留最近 5 份。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.6,
                    color: Palette.inkFaint(context),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Text('简记 · 本地优先',
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle, {
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, size: 18),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
