import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'app_log.dart';

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
}
