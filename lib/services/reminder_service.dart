import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'app_log.dart';
import '../core/due_reminders.dart';
import '../core/rules.dart';

/// 每日记账提醒。
///
/// 用 flutter_local_notifications 的定时通知，每天固定时间弹一条。
/// 时区处理：设备时区名需要额外插件才能拿，这里用「本地时间 → UTC 时刻」换算，
/// 中国无夏令时所以每天同一时刻是准的（跨时区旅行时按新时区重设即可）。
class ReminderService {
  ReminderService._();

  static const _kEnabled = 'reminder_enabled';
  static const _kHour = 'reminder_hour';
  static const _kMinute = 'reminder_minute';
  static const int _id = 1001;

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static Future<void> _ensureInit() async {
    if (_inited) return;
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, iOS: ios),
    );
    _inited = true;
  }

  /// 读当前设置
  static Future<({bool enabled, int hour, int minute})> read() async {
    try {
      final p = await SharedPreferences.getInstance();
      return (
        enabled: p.getBool(_kEnabled) ?? false,
        hour: p.getInt(_kHour) ?? 21,
        minute: p.getInt(_kMinute) ?? 0,
      );
    } catch (_) {
      return (enabled: false, hour: 21, minute: 0);
    }
  }

  /// 申请通知权限（Android 13+ / iOS）
  static Future<bool> requestPermission() async {
    await _ensureInit();
    if (kIsWeb) return false;
    try {
      if (Platform.isAndroid) {
        final impl = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        final ok = await impl?.requestNotificationsPermission();
        return ok ?? true;
      }
      final impl = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final ok =
          await impl?.requestPermissions(alert: true, badge: true, sound: true);
      return ok ?? true;
    } catch (e) {
      AppLog.warn('reminder', '申请通知权限失败: $e');
      return false;
    }
  }

  /// 查**真实**通知权限（不申请、不弹窗）。
  ///
  /// 为什么不复用本地 prefs：用户被拒之后去系统设置里打开了通知，
  /// 回到这一页以前看不出任何变化，只能盲着再开一次开关。
  /// 返回 null = 平台不支持查询。
  static Future<bool?> permissionGranted() async {
    await _ensureInit();
    if (kIsWeb) return null;
    try {
      if (Platform.isAndroid) {
        final impl = _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        return await impl?.areNotificationsEnabled();
      }
      final impl = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      final opts = await impl?.checkPermissions();
      return opts?.isEnabled;
    } catch (e) {
      AppLog.warn('reminder', '查询通知权限失败: $e');
      return null;
    }
  }

  /// 设置并安排每日提醒；[enabled] 为 false 时取消
  static Future<bool> setDaily({
    required bool enabled,
    required int hour,
    required int minute,
  }) async {
    await _ensureInit();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, enabled);
    await prefs.setInt(_kHour, hour);
    await prefs.setInt(_kMinute, minute);

    await _plugin.cancel(id: _id);
    if (!enabled) return true;

    final granted = await requestPermission();
    if (!granted) {
      AppLog.warn('reminder', '通知权限未授予，提醒不会弹出');
      return false;
    }

    // 本地时间 → 下一次触发 → 转 UTC 交给插件
    final now = DateTime.now();
    var next = DateTime(now.year, now.month, now.day, hour, minute);
    if (!next.isAfter(now)) next = next.add(const Duration(days: 1));
    final scheduled = tz.TZDateTime.from(next.toUtc(), tz.UTC);

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'jianji_daily_reminder',
        '每日记账提醒',
        channelDescription: '每天固定时间提醒记账',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        styleInformation: BigTextStyleInformation(''),
      ),
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.zonedSchedule(
      id: _id,
      title: '今天记了吗？',
      body: '花一分钟把今天的账补上吧',
      scheduledDate: scheduled,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
    AppLog.info(
        'reminder', '已设置每日提醒 $hour:${minute.toString().padLeft(2, '0')}');
    return true;
  }

  /// 启动时按已保存的设置补排一次（重装/重启后通知队列会丢）
  static Future<void> resync() async {
    final s = await read();
    if (!s.enabled) return;
    try {
      await setDaily(enabled: true, hour: s.hour, minute: s.minute);
    } catch (e) {
      AppLog.warn('reminder', '恢复提醒失败: $e');
    }
  }

  // ---------------------------------------------------------------- 到期提醒

  /// 到期提醒通知的 id 段：2000 ~ 2999（与每日提醒的 1001 错开）。
  static const int _kDueBase = 2000;
  static const int _kDueRange = 1000;

  /// 清掉全部到期提醒（整个 2000 段）。
  ///
  /// 重排前先整体清一遍，这样"改了提前天数 / 删了信用卡"之后不会留下
  /// 过期的旧通知。
  static Future<void> cancelAllDue() async {
    await _ensureInit();
    for (var i = 0; i < _kDueRange; i++) {
      await _plugin.cancel(id: _kDueBase + i);
    }
  }

  /// 到期提醒的调度入口。
  ///
  /// [enabled] 为 false 时只清掉全部到期提醒（关开关的兜底）。
  /// 真正"该提醒哪些事由"由 [reminders] 给出（见 dueRemindersProvider）。
  /// 每个到期日发两条：**提前 [leadDays] 天**一条 + **当天**一条。
  ///
  /// 不在这里申请权限：权限弹出只发生在用户主动开开关的那一刻
  /// （见 ReminderPage），后台重排如果没权限就静默跳过，避免冷启动弹窗。
  static Future<void> syncDueReminders(
    List<DueReminder> reminders, {
    required bool enabled,
    required int leadDays,
  }) async {
    await _ensureInit();
    await cancelAllDue();
    if (!enabled) return;
    final granted = await permissionGranted();
    if (granted != true) {
      AppLog.warn('reminder', '通知权限未授予，到期提醒不会弹出');
      return;
    }
    final now = _startOfToday();
    var id = _kDueBase;
    final details = const NotificationDetails(
      android: AndroidNotificationDetails(
        'jianji_due_reminder',
        '到期提醒',
        channelDescription: '信用卡还款、账单日、借还款、目标到期提醒',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        styleInformation: BigTextStyleInformation(''),
      ),
      iOS: DarwinNotificationDetails(),
    );
    for (final r in reminders) {
      // 提前 leadDays 天
      final leadDate = r.occurrence.subtract(Duration(days: leadDays));
      if (!leadDate.isBefore(now)) {
        await _scheduleOne(id++, details, r, leadDate, pre: '还有 $leadDays 天 · ');
      }
      // 当天
      if (!r.occurrence.isBefore(now)) {
        await _scheduleOne(id++, details, r, r.occurrence, pre: '今天是 · ');
      }
    }
    AppLog.info('reminder', '已排到期提醒 ${id - _kDueBase} 条');
  }

  /// 今天零点（本地时区）。用于判断某条提醒是否已过期。
  static DateTime _startOfToday() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  static Future<void> _scheduleOne(
    int id,
    NotificationDetails details,
    DueReminder r,
    DateTime date, {
    required String pre,
  }) async {
    // 默认上午 9 点弹；若该时刻已经过去（比如"今天"的提醒在下午才重排），
    // 顺延到"现在 + 2 分钟"，否则 zonedSchedule 拿到过去的时间会告警/不触发。
    var when = DateTime(date.year, date.month, date.day, 9, 0);
    final n = DateTime.now();
    if (when.isBefore(n)) when = n.add(const Duration(minutes: 2));
    final scheduled = tz.TZDateTime.from(when.toUtc(), tz.UTC);
    await _plugin.zonedSchedule(
      id: id,
      title: r.title,
      body: '$pre${r.body}',
      scheduledDate: scheduled,
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  // ---------------------------------------------------------------- 预算提醒

  /// 预算提醒的固定通知 id（与每日 1001、到期 2000+ 错开）。
  static const int _kBudgetId = 3001;
  static const String _kBudgetWarned = 'budget_warned';

  /// 本月预算达到 80% / 超支时发一次**即时**通知。
  ///
  /// 去重：prefs 里记 `"2026-10:80"` / `"2026-10:100"`，同一个月的同一档
  /// 只弹一次；到 100% 会再弹一次（比 80% 更严重，值得再提醒）。
  static Future<void> notifyBudget({
    required int spentCents,
    required int budgetCents,
    required String symbol,
    required String monthKey,
  }) async {
    if (budgetCents <= 0 || spentCents <= 0) return;
    final ratio = spentCents / budgetCents;
    final level = ratio >= 1.0 ? 100 : (ratio >= 0.8 ? 80 : 0);
    if (level == 0) return;
    final key = '$monthKey:$level';
    final prefs = await SharedPreferences.getInstance();
    if ((prefs.getString(_kBudgetWarned) ?? '') == key) return; // 本月本档已发
    final granted = await permissionGranted();
    if (granted != true) return;
    await _ensureInit();
    final over = spentCents - budgetCents;
    final title = level >= 100 ? '本月预算已超支' : '本月预算快用完了';
    final body = level >= 100
        ? '已花 $symbol${centsToText(spentCents)}，超出 $symbol${centsToText(over)}'
        : '已花 $symbol${centsToText(spentCents)} / '
            '$symbol${centsToText(budgetCents)}（${(ratio * 100).round()}%）';
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'jianji_budget_warn',
        '预算提醒',
        channelDescription: '接近或超出月度预算时提醒',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        styleInformation: BigTextStyleInformation(''),
      ),
      iOS: DarwinNotificationDetails(),
    );
    try {
      await _plugin.show(
        id: _kBudgetId,
        title: title,
        body: body,
        notificationDetails: details,
      );
      await prefs.setString(_kBudgetWarned, key);
      AppLog.info('reminder', '已发预算提醒 $key');
    } catch (e) {
      AppLog.warn('reminder', '预算提醒失败: $e');
    }
  }

  // ---------------------------------------------------------------- 分类预算提醒

  static const int _kBucketBudgetId = 3002;
  static const String _kBucketWarned = 'bucket_budget_warned';

  /// 某个分类预算达到 80% / 超支时发一次**即时**通知。
  ///
  /// 两个刻意的设计：
  /// 1. **合成一条**。4 个分类各自弹一条会把通知栏刷满，用户也不会逐条点开；
  ///    合成「食 已超 ¥120、住 已用 92%」信息量更高、打扰更少。
  /// 2. **按 (月份, 分类, 档位) 去重**。同一档只提醒一次，但 80% → 100% 会再提醒
  ///    一次（真超支比"快超了"严重，值得再响）。跨月自动作废旧记录。
  static Future<void> notifyBucketBudgets({
    required List<
            ({
              int bucketId,
              String title,
              int spentCents,
              int budgetCents
            })>
        items,
    required String symbol,
    required String monthKey,
  }) async {
    if (items.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    // 只留本月的 token，否则这个字符串会随月份无限变长。
    final warned = (prefs.getString(_kBucketWarned) ?? '')
        .split(',')
        .where((t) => t.startsWith('$monthKey:'))
        .toSet();

    final phrases = <String>[];
    var anyOver = false;
    for (final it in items) {
      if (it.budgetCents <= 0) continue;
      final ratio = it.spentCents / it.budgetCents;
      final level = ratio >= 1.0 ? 100 : (ratio >= 0.8 ? 80 : 0);
      if (level == 0) continue;
      final token = '$monthKey:${it.bucketId}:$level';
      if (warned.contains(token)) continue;
      warned.add(token);
      if (level >= 100) anyOver = true;
      phrases.add(level >= 100
          ? '${it.title} 已超 $symbol${centsToText(it.spentCents - it.budgetCents)}'
          : '${it.title} 已用 ${(ratio * 100).round()}%');
    }
    if (phrases.isEmpty) return;

    final granted = await permissionGranted();
    if (granted != true) return;
    await _ensureInit();

    // 最多列 3 个，再多就概括成数量，避免通知正文被系统截断后只剩省略号。
    final body = phrases.length <= 3
        ? phrases.join('、')
        : '${phrases.take(3).join('、')} 等 ${phrases.length} 个分类';
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'jianji_bucket_budget_warn',
        '分类预算提醒',
        channelDescription: '某个分类接近或超出预算时提醒',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        styleInformation: BigTextStyleInformation(''),
      ),
      iOS: DarwinNotificationDetails(),
    );
    try {
      await _plugin.show(
        id: _kBucketBudgetId,
        title: anyOver ? '有分类超预算了' : '有分类快超预算了',
        body: body,
        notificationDetails: details,
      );
      await prefs.setString(_kBucketWarned, warned.join(','));
      // ⚠️ 不要把 body 原样打进日志（2026-11-08 审计 P2-6）：body 里带**具体金额**，
      // 而「日志中心」支持一键复制全部，等于把用户不想给人看的数字抄了一份。
      // 只记「发了几条、有没有超支」这类不含金额的元信息。
      AppLog.info('reminder',
          '已发分类预算提醒：${phrases.length} 个分类，${anyOver ? '含超支' : '仅预警'}');
    } catch (e) {
      AppLog.warn('reminder', '分类预算提醒失败: $e');
    }
  }
}
