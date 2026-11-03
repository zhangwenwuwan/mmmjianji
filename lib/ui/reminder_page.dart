import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/reminder_service.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 记账提醒设置：开关 + 每天几点 + 到期提醒 + 一次性讲清权限用途。
class ReminderPage extends ConsumerStatefulWidget {
  const ReminderPage({super.key});

  @override
  ConsumerState<ReminderPage> createState() => _ReminderPageState();
}

class _ReminderPageState extends ConsumerState<ReminderPage> {
  bool _loading = true;
  bool _enabled = false;
  int _hour = 21;
  int _minute = 0;

  /// 系统里**真实**的通知权限。null = 还没查到 / 平台不支持。
  bool? _granted;

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
    _refreshPermission();
  }

  Future<void> _refreshPermission() async {
    final g = await ReminderService.permissionGranted();
    if (!mounted) return;
    setState(() => _granted = g);
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
      ScaffoldMessenger.of(context)
          .toast('没有拿到通知权限，提醒已关闭（去系统设置里允许后再开）');
    }
    // 开关动过就重新查一次真实权限，页面上的徽标跟着变
    _refreshPermission();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _hour, minute: _minute),
    );
    if (picked == null) return;
    await _apply(enabled: true, hour: picked.hour, minute: picked.minute);
  }

  /// 提前提醒天数候选（天）。
  static const List<int> _leadOptions = [1, 2, 3, 5, 7, 14];

  /// 开关到期提醒。开的时候先申请通知权限（系统会弹一次）。
  Future<void> _setDueEnabled(bool v) async {
    if (v) {
      final ok = await ReminderService.requestPermission();
      if (!ok) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .toast('没有拿到通知权限，到期提醒已关闭（去系统设置里允许后再开）');
        // 权限没拿到就不写设置；强制重绘让开关回退到关闭态。
        if (mounted) setState(() {});
        return;
      }
    }
    // 写设置即可：Shell 的 ref.listen 会就地重排通知，无需这里再排一次。
    await ref.read(settingsProvider.notifier).setDueReminderEnabled(v);
  }

  /// 选「提前几天提醒」。
  Future<void> _pickLeadDays() async {
    final current = ref.read(settingsProvider).dueReminderLeadDays;
    final picked = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('提前几天提醒'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final d in _leadOptions)
              ListTile(
                leading: Icon(
                  d == current
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: d == current
                      ? Palette.brand(c)
                      : Palette.inkFaint(c),
                ),
                title: Text(d == 1 ? '提前 1 天' : '提前 $d 天'),
                onTap: () => Navigator.of(c).pop(d),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await ref.read(settingsProvider.notifier).setDueReminderLeadDays(picked);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final dueReminders = ref.watch(dueRemindersProvider).valueOrNull;
    final dueEnabled = settings.dueReminderEnabled;
    final leadDays = settings.dueReminderLeadDays;
    final dueSummary = !dueEnabled
        ? ''
        : (dueReminders == null
            ? '正在计算…'
            : (dueReminders.isEmpty
                ? '暂无可提醒的到期事项（没设信用卡还款日 / 借还款 / 目标日期，'
                    '或都还没进入提醒窗口）'
                : '已为你排了 ${dueReminders.length} 个到期事项，每件事会在到期前 '
                    '$leadDays 天和当天各提醒一次'));
    return Scaffold(
      appBar: AppBar(title: const Text('记账提醒')),
      body: _loading
          ? const SkeletonList(count: 4, height: 64)
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
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.event_repeat_outlined),
                        title: const Text('到期提醒'),
                        subtitle: Text(
                          dueEnabled
                              ? '还款日 / 账单日 / 借还款 / 目标到期，提前提醒'
                              : '信用卡还款、借还款、目标到期前本地提醒',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: JellySwitch(
                          value: dueEnabled,
                          onChanged: _setDueEnabled,
                        ),
                      ),
                      if (dueEnabled) ...[
                        const Divider(height: 1, indent: 16),
                        PressScale(
                          scale: 0.98,
                          onTap: _pickLeadDays,
                          child: ListTile(
                            leading: const Icon(Icons.schedule_outlined),
                            title: const Text('提前提醒天数'),
                            subtitle: Text('提前 $leadDays 天',
                                style: const TextStyle(fontSize: 12)),
                            trailing: const Icon(Icons.chevron_right, size: 18),
                          ),
                        ),
                        if (dueSummary.isNotEmpty) ...[
                          const Divider(height: 1, indent: 16),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                            child: Text(
                              dueSummary,
                              style: TextStyle(
                                  fontSize: 12,
                                  height: 1.5,
                                  color: Palette.inkSoft(context)),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('关于权限',
                              style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: Palette.ink(context))),
                          const Spacer(),
                          // 真实权限状态：被拒过的人去系统设置里打开了通知，
                          // 回到这一页也该能看出来，而不是只能盲着再开一次。
                          if (_granted != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: (_granted!
                                        ? Palette.brand(context)
                                        : Palette.expense)
                                    .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                _granted! ? '通知已允许' : '通知未允许',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: _granted!
                                        ? Palette.brand(context)
                                        : Palette.expense),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _granted == false
                            ? '系统里没有给通知权限：去「设置 → 应用 → 简记 → 通知」'
                                '打开，再回来开启上面的开关。\n'
                                '拒绝也不影响记账，只是不会弹提醒。'
                            : '提醒用的是系统通知，第一次开启时系统会问你要通知权限。'
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
