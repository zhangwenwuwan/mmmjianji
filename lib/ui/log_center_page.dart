import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/app_log.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 日志中心：出问题时能翻到「刚才发生了什么」。
///
/// 对齐原版的日志中心页。日志存在内存环形缓冲 + 限流落盘，
/// 崩溃重开之后还能看到上一次的记录。
class LogCenterPage extends ConsumerStatefulWidget {
  const LogCenterPage({super.key});

  @override
  ConsumerState<LogCenterPage> createState() => _LogCenterPageState();
}

class _LogCenterPageState extends ConsumerState<LogCenterPage> {
  String _level = 'all';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志中心'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: AppLog.dump()));
              messenger.showSnackBar(
                const SnackBar(content: Text('已复制全部日志')),
              );
            },
            icon: const Icon(Icons.copy_all_outlined),
          ),
          IconButton(
            tooltip: '清空',
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('清空日志？'),
                  content: const Text('只清掉这份记录，不影响账目数据。'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('清空')),
                  ],
                ),
              );
              if (ok == true) await AppLog.clear();
            },
            icon: const Icon(Icons.delete_sweep_outlined),
          ),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: AppLog.revision,
        builder: (context, _, __) {
          final all = AppLog.entries;
          final list = _level == 'all'
              ? all
              : all.where((e) => e.level == _level).toList();
          final errCount = all.where((e) => e.level == 'E').length;

          return Column(
            children: [
              SizedBox(
                height: 46,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    _filter('全部', 'all', all.length),
                    _filter('错误', 'E', errCount),
                    _filter('警告', 'W', all.where((e) => e.level == 'W').length),
                    _filter('信息', 'I', all.where((e) => e.level == 'I').length),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: list.isEmpty
                    ? EmptyView(
                        icon: Icons.receipt_long_outlined,
                        title: '还没有日志',
                        hint: errCount == 0 ? '运行正常时这里是空的' : null,
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
                        itemCount: list.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => _card(context, list[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _filter(String label, String value, int count) {
    final selected = _level == value;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 3),
      child: PressScale(
        scale: 0.94,
        onTap: () => setState(() => _level = value),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? Palette.brand(context).withValues(alpha: 0.14)
                : Palette.card(context),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color:
                  selected ? Palette.brand(context) : Palette.hairline(context),
            ),
          ),
          child: Text(
            '$label $count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color:
                  selected ? Palette.brand(context) : Palette.inkSoft(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, AppLogEntry e) {
    final color = switch (e.level) {
      'E' => Palette.expense,
      'W' => const Color(0xFFB4830E),
      _ => Palette.inkSoft(context),
    };
    return Panel(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(e.level,
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: color)),
              ),
              const SizedBox(width: 6),
              Text(e.tag,
                  style: TextStyle(
                      fontSize: 10.5, color: Palette.inkFaint(context))),
              const Spacer(),
              Text(
                '${e.at.month}-${e.at.day} '
                '${e.at.hour.toString().padLeft(2, '0')}:'
                '${e.at.minute.toString().padLeft(2, '0')}:'
                '${e.at.second.toString().padLeft(2, '0')}',
                style:
                    TextStyle(fontSize: 10.5, color: Palette.inkFaint(context)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            e.message,
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              fontFamily: 'monospace',
              color: Palette.ink(context),
            ),
          ),
        ],
      ),
    );
  }
}
