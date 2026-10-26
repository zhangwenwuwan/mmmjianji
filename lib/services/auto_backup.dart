import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../data/store.dart';

/// 本地自动备份：每次启动写一份 JSON 到应用私有目录，只留最近几份。
///
/// 为什么不用系统定时任务：那需要原生插件（WorkManager/通知），本机验证不了。
/// 这里做的是「打开 App 就备份一次」，配合"只留 5 份"已经能覆盖误删/数据损坏。
class AutoBackup {
  const AutoBackup._();

  static const int keepCount = 5;

  static Future<Directory> dir() async {
    final base = await getDatabasesPath();
    final d = Directory(p.join(base, 'backups'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 列出备份（新 → 旧）
  static Future<List<File>> list() async {
    try {
      final d = await dir();
      final files = await d
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      files.sort((a, b) => b.path.compareTo(a.path));
      return files;
    } catch (_) {
      return const [];
    }
  }

  /// 跑一次备份。同一天只写一份（避免每次切前后台都写）。
  /// 返回刚写入的文件；今天已备份过则返回 null。
  static Future<File?> run(LedgerStore store) async {
    try {
      final d = await dir();
      final now = DateTime.now();
      final stamp = '${now.year}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}';
      final existing = await list();
      final todayPrefix = 'auto_$stamp';
      if (existing.any((f) => p.basename(f.path).startsWith(todayPrefix))) {
        return null;
      }
      final json = await store.exportJson();
      final file = File(p.join(
          d.path,
          '${todayPrefix}_${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}.json'));
      await file.writeAsString(json, flush: true);
      await prune();
      return file;
    } catch (_) {
      // 备份失败不能影响正常使用
      return null;
    }
  }

  /// 只留最近 [keepCount] 份
  static Future<void> prune() async {
    final files = await list();
    for (var i = keepCount; i < files.length; i++) {
      try {
        await files[i].delete();
      } catch (_) {}
    }
  }

  static Future<String> read(File file) => file.readAsString();

  static Future<void> delete(File file) async {
    try {
      await file.delete();
    } catch (_) {}
  }
}
