/// 固定标签：用户自己添加的「每次记账都能一键点」的常用标签。
///
/// 存在 SharedPreferences 而不是数据库新表：
/// - 不触发 schema 迁移，也不用改 exportJson/importJson（项目铁律：新表必须同时进两边）
/// - 标签只是输入偏好，和账本流水同生死没必要；丢了也不影响账
/// - 按账本 id 隔离，切账本不会串标签
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/tags.dart';

class FixedTags {
  const FixedTags._();

  static const String _prefix = 'fixed_tags_v1_';
  static const int _max = 60;

  static String _key(int bookId) => '$_prefix$bookId';

  static Future<List<String>> load(int bookId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(bookId));
      if (raw == null || raw.isEmpty) return const <String>[];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <String>[];
      return parseTags(decoded.map((e) => e.toString()).join(','));
    } catch (_) {
      // 读不到就是「没有固定标签」。不写 AppLog：widget 测试里没有
      // SharedPreferences 插件，warn 的 2s flush 定时器会造成 Pending timers。
      return const <String>[];
    }
  }

  static Future<void> save(int bookId, List<String> tags) async {
    final clean = parseTags(tags.join(',')).take(_max).toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(bookId), jsonEncode(clean));
    } catch (_) {
      // 保存失败不该阻断记账，静默即可。
    }
  }

  static Future<void> add(int bookId, String tag) async {
    final t = tag.trim();
    if (t.isEmpty || t.length > 16) return;
    final current = await load(bookId);
    if (current.contains(t)) return;
    await save(bookId, [...current, t]);
  }

  static Future<void> remove(int bookId, String tag) async {
    final current = await load(bookId);
    if (!current.remove(tag)) return;
    await save(bookId, current);
  }
}
