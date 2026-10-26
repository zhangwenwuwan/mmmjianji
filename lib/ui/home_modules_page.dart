import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/home_modules.dart';
import '../state/settings.dart';
import 'common.dart';
import 'theme.dart';

/// 首页模块：拖拽排序 + 逐个显隐。
///
/// 交互取舍：用「拖手柄」而不是「长按整行拖动」。整行长按会和 ListTile 的
/// 点击冲突（用户想开关某个模块，结果把顺序拖乱了），手柄能避免误触。
class HomeModulesPage extends ConsumerStatefulWidget {
  const HomeModulesPage({super.key});

  @override
  ConsumerState<HomeModulesPage> createState() => _HomeModulesPageState();
}

class _HomeModulesPageState extends ConsumerState<HomeModulesPage> {
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    // 直接用 provider 里的顺序：SettingsNotifier 在 await 落盘之前就同步改了
    // state，所以重建是即时的，不需要本地副本（有副本反而会和外部改动打架）。
    final order = settings.modulesOrder;
    final hidden = parseHidden(settings.homeHidden);

    return Scaffold(
      appBar: AppBar(
        title: const Text('首页模块'),
        actions: [
          TextButton(
            onPressed: () =>
                ref.read(settingsProvider.notifier).resetHomeModules(),
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
            child: Row(
              children: [
                Icon(Icons.drag_indicator,
                    size: 15, color: Palette.inkFaint(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '按住右侧手柄拖动排序；关掉的模块不会出现在首页',
                    style: TextStyle(
                        fontSize: 11.5, color: Palette.inkFaint(context)),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
              itemCount: order.length,
              buildDefaultDragHandles: false,
              // onReorderItem 已经把"移除旧项后"的索引算好了，
              // 所以这里**不能再手动 to -= 1**（老的 onReorder 才需要）。
              onReorderItem: (from, to) {
                final list = [...order];
                final moved = list.removeAt(from);
                list.insert(to, moved);
                ref.read(settingsProvider.notifier).setHomeOrder(list);
              },
              itemBuilder: (context, i) {
                final m = order[i];
                final on = !hidden.contains(m) || !m.canHide;
                return Padding(
                  key: ValueKey(m.id),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Panel(
                    padding: EdgeInsets.zero,
                    child: ListTile(
                      leading: Icon(_iconOf(m),
                          size: 20,
                          color: on
                              ? Palette.brand(context)
                              : Palette.inkFaint(context)),
                      title: Text(m.label,
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: on
                                ? Palette.ink(context)
                                : Palette.inkFaint(context),
                          )),
                      subtitle: Text(
                        m.canHide ? m.hint : '${m.hint} · 固定显示',
                        style: TextStyle(
                            fontSize: 11.5, color: Palette.inkFaint(context)),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 「记一笔」不允许隐藏：它是唯一的记账入口
                          if (m.canHide)
                            Switch(
                              value: on,
                              onChanged: (v) => ref
                                  .read(settingsProvider.notifier)
                                  .setHomeModuleHidden(m, !v),
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Icon(Icons.lock_outline,
                                  size: 16,
                                  color: Palette.inkFaint(context)),
                            ),
                          // 固定项不给拖动手柄：它在首页永远排第一，
                          // 允许拖只会让用户以为拖动无效是 bug。
                          if (!m.fixed)
                            ReorderableDragStartListener(
                              index: i,
                              child: Padding(
                                padding:
                                    const EdgeInsets.only(left: 2, right: 4),
                                child: Icon(Icons.drag_handle,
                                    size: 22, color: Palette.inkFaint(context)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconOf(HomeModule m) => switch (m) {
        HomeModule.hero => Icons.insights_outlined,
        HomeModule.addEntry => Icons.add_circle_outline,
        HomeModule.safeToSpend => Icons.today_outlined,
        HomeModule.budgetHint => Icons.notifications_active_outlined,
        HomeModule.backupHint => Icons.backup_outlined,
        HomeModule.lastMonth => Icons.compare_arrows,
        HomeModule.annualReport => Icons.calendar_view_month_outlined,
      };
}
