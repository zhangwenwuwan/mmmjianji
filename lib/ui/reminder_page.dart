import 'package:flutter/material.dart';

import '../services/reminder_service.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 记账提醒设置：开关 + 每天几点 + 一次性讲清权限用途。
class ReminderPage extends StatefulWidget {
  const ReminderPage({super.key});

  @override
  State<ReminderPage> createState() => _ReminderPageState();
}

class _ReminderPageState extends State<ReminderPage> {
  bool _loading = true;
  bool _enabled = false;
  int _hour = 21;
  int _minute = 0;

  @override
  void initState() {
    super.initState();
    ReminderService.read().then((s) {
      if (!mounted) return;
      setState(() {
        _enabled = s.enabled;
        _hour = s.hour;
        _minute = s.minute;
        _loading = false;
      });
    });
  }

  String get _timeText =>
      '${_hour.toString().padLeft(2, '0')}:${_minute.toString().padLeft(2, '0')}';

  Future<void> _apply({bool? enabled, int? hour, int? minute}) async {
    final nextEnabled = enabled ?? _enabled;
    final nextHour = hour ?? _hour;
    final nextMinute = minute ?? _minute;
    setState(() {
      _enabled = nextEnabled;
      _hour = nextHour;
      _minute = nextMinute;
    });
    final ok = await ReminderService.setDaily(
      enabled: nextEnabled,
      hour: nextHour,
      minute: nextMinute,
    );
    if (!mounted) return;
    if (nextEnabled && !ok) {
      setState(() => _enabled = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有拿到通知权限，提醒已关闭')),
      );
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _hour, minute: _minute),
    );
    if (picked == null) return;
    await _apply(enabled: true, hour: picked.hour, minute: picked.minute);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('记账提醒')),
      body: _loading
          ? const SkeletonList(count: 3, height: 64)
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
              children: [
                Panel(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.notifications_none),
                        title: const Text('每天提醒我记账'),
                        subtitle: Text(
                          _enabled ? '每天 $_timeText 提醒一次' : '当前未开启',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: JellySwitch(
                          value: _enabled,
                          onChanged: (v) => _apply(enabled: v),
                        ),
                      ),
                      if (_enabled) ...[
                        const Divider(height: 1, indent: 16),
                        PressScale(
                          scale: 0.98,
                          onTap: _pickTime,
                          child: ListTile(
                            leading: const Icon(Icons.schedule_outlined),
                            title: const Text('提醒时间'),
                            subtitle: Text(_timeText,
                                style: const TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('关于权限',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: Palette.ink(context))),
                      const SizedBox(height: 6),
                      Text(
                        '提醒用的是系统通知，第一次开启时系统会问你要通知权限。'
                        '拒绝也不影响记账，只是不会弹提醒。'
                        '通知内容只在本机生成，不经过任何服务器。',
                        style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: Palette.inkSoft(context)),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                Panel(
                  child: Row(
                    children: [
                      Icon(Icons.battery_saver_outlined,
                          size: 16, color: Palette.inkFaint(context)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '部分手机的省电策略会清掉定时通知，建议把简记加入「不受限制」名单。',
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
