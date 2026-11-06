/// 语音/文本记账的「记忆表」。
///
/// 参考一木的「记忆表命中」：用户手动把「星巴克」改到某个分类/账户后，
/// 下次再说同样的话就直接命中，不用每次都改。
///
/// 只存关键词 → id 的小表，放 SharedPreferences，不动数据库（新表必须同时进
/// exportJson/importJson，不值得为这点偏好加一次 schema 迁移）。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_log.dart';

class SmartMemory {
  const SmartMemory._();

  static const String _kCategory = 'smart_voice_category_v1';
  static const String _kAccount = 'smart_voice_account_v1';
  static const int _maxEntries = 200;

  static Future<Map<String, int>> _load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return <String, int>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, int>{};
      final out = <String, int>{};
      decoded.forEach((k, v) {
        final id = v is int ? v : int.tryParse(v.toString());
        if (k.toString().isNotEmpty && id != null && id > 0) {
          out[k.toString()] = id;
        }
      });
      return out;
    } catch (e) {
      AppLog.warn('voice', '读取记忆表失败: $e');
      return <String, int>{};
    }
  }

  static Future<void> _remember(String key, String keyword, int id) async {
    final word = keyword.trim();
    if (word.isEmpty || word.length > 24 || id <= 0) return;
    try {
      final map = await _load(key);
      map.remove(word);
      map[word] = id;
      if (map.length > _maxEntries) {
        final stale = map.keys.take(map.length - _maxEntries).toList();
        for (final k in stale) {
          map.remove(k);
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, jsonEncode(map));
    } catch (e) {
      AppLog.warn('voice', '写入记忆表失败: $e');
    }
  }

  static Future<Map<String, int>> categoryHints() => _load(_kCategory);
  static Future<Map<String, int>> accountHints() => _load(_kAccount);

  static Future<void> rememberCategory(String keyword, int bucketId) =>
      _remember(_kCategory, keyword, bucketId);

  static Future<void> rememberAccount(String keyword, int pocketId) =>
      _remember(_kAccount, keyword, pocketId);

  /// 设置页/测试用：清空全部记忆。
  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kCategory);
      await prefs.remove(_kAccount);
    } catch (e) {
      AppLog.warn('voice', '清空记忆表失败: $e');
    }
  }
}
