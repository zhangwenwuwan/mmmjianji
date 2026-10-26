import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一条日志
class AppLogEntry {
  const AppLogEntry({
    required this.at,
    required this.level,
    required this.tag,
    required this.message,
  });

  final DateTime at;

  /// I / W / E
  final String level;
  final String tag;
  final String message;

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'lv': level,
        'tag': tag,
        'msg': message,
      };

  static AppLogEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final at = DateTime.tryParse('${raw['at']}');
    if (at == null) return null;
    return AppLogEntry(
      at: at,
      level: '${raw['lv'] ?? 'I'}',
      tag: '${raw['tag'] ?? ''}',
      message: '${raw['msg'] ?? ''}',
    );
  }
}

/// 应用内日志（对齐原版「日志中心」的用途：出问题时能看见发生过什么）。
///
/// 只在内存里留最近 [maxEntries] 条，同时**限流落盘**到 SharedPreferences，
/// 这样崩溃重开之后还能翻到上一次的记录。写入不阻塞 UI（异步 + 节流）。
class AppLog {
  AppLog._();

  static const int maxEntries = 400;
  static const String _kKey = 'app_log_v1';

  static final List<AppLogEntry> _entries = <AppLogEntry>[];
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Timer? _flushTimer;
  static bool _dirty = false;

  static List<AppLogEntry> get entries => List.unmodifiable(_entries);

  static void info(String tag, String message) => _add('I', tag, message);

  static void warn(String tag, String message) => _add('W', tag, message);

  static void error(String tag, String message,
          [Object? error, StackTrace? stack]) =>
      _add(
          'E',
          tag,
          error == null
              ? message
              : '$message\n$error${stack == null ? '' : '\n$stack'}');

  static void _add(String level, String tag, String message) {
    final e = AppLogEntry(
      at: DateTime.now(),
      level: level,
      tag: tag,
      message: message.length > 4000 ? message.substring(0, 4000) : message,
    );
    _entries.insert(0, e);
    if (_entries.length > maxEntries) {
      _entries.removeRange(maxEntries, _entries.length);
    }
    revision.value++;
    dev.log('[$level][$tag] $message');
    _scheduleFlush();
  }

  /// 节流落盘：2 秒内多次写入只落一次
  static void _scheduleFlush() {
    _dirty = true;
    _flushTimer ??= Timer(const Duration(seconds: 2), () async {
      _flushTimer = null;
      if (!_dirty) return;
      _dirty = false;
      await _flush();
    });
  }

  static Future<void> _flush() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = jsonEncode([
        for (final e in _entries.take(150)) e.toJson(),
      ]);
      await prefs.setString(_kKey, payload);
    } catch (_) {
      // 日志落盘失败不能再抛，否则会变成递归错误
    }
  }

  /// 启动时把上次的日志读回来
  static Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw);
      if (list is! List) return;
      final restored = <AppLogEntry>[];
      for (final item in list) {
        final e = AppLogEntry.fromJson(item);
        if (e != null) restored.add(e);
      }
      if (restored.isEmpty) return;
      _entries
        ..clear()
        ..addAll(restored.take(maxEntries));
      revision.value++;
    } catch (_) {}
  }

  static Future<void> clear() async {
    _entries.clear();
    revision.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kKey);
    } catch (_) {}
  }

  static String dump() {
    final b = StringBuffer();
    for (final e in _entries) {
      b.writeln('${_ts(e.at)} [${e.level}] (${e.tag}) ${e.message}');
    }
    return b.toString();
  }

  static String _ts(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// 在 main 里调用：接管全局未捕获错误
  static void installGlobalHandlers() {
    final prev = FlutterError.onError;
    FlutterError.onError = (details) {
      error('flutter', details.exceptionAsString(), details.exception,
          details.stack);
      prev?.call(details);
    };
    PlatformDispatcher.instance.onError = (e, st) {
      error('platform', '$e', e, st);
      return true;
    };
  }
}
