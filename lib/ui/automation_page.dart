import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/ledger_state.dart';
import 'common.dart';
import 'motion.dart';
import 'recurring_page.dart';
import 'reminder_page.dart';
import 'theme.dart';

/// 自动化：把「会自己发生的事」收在一页。
///
/// 对齐原版 automation_page —— 原版把周期记账和提醒设置都收在这一层，
/// 「我的」页只留一个一级入口。
class AutomationPage extends ConsumerWidget {
  const AutomationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recurrings = ref.watch(recurringsProvider).valueOrNull ?? const [];
    final activeReccurring = recurrings.where((r) => r.enabled).length;

    return Scaffold(
      appBar: AppBar(title: const Text('自动化')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
        children: [
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const RecurringPage())),
                  child: ListTile(
                    leading: const Icon(Icons.repeat),
                    title: const Text('周期记账'),
                    subtitle: Text(
                      activeReccurring == 0
                          ? '房租、订阅、工资，到日子自动记一笔'
                          : '已启用 $activeReccurring 条规则',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                PressScale(
                  scale: 0.98,
                  onTap: () => Navigator.of(context)
                      .push(AppPageRoute(page: const ReminderPage())),
                  child: const ListTile(
                    leading: Icon(Icons.notifications_none),
                    title: Text('记账提醒'),
                    subtitle:
                        Text('每天固定时间提醒你记账', style: TextStyle(fontSize: 12)),
                    trailing: Icon(Icons.chevron_right, size: 18),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Panel(
            child: Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: Palette.inkFaint(context)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '自动化的动作只在本机执行，不联网、不推送服务端消息。',
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
}
