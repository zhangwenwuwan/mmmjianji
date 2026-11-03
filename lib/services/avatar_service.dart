import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pick_result.dart';

export 'pick_result.dart';

/// 「我的」页头像：从相册选一张图，缩到 512px 存进应用私有目录。
///
/// 和 `IconService` 的区别：头像只有一张，所以这里**存绝对路径、不存相对名**。
/// 出问题最多回退成默认钱包图标，不像分类图标那样会批量变「🧾」。
///
/// ⚠️ 文件名带时间戳（不是固定 `avatar.jpg`）：Flutter 的 ImageCache 按
/// 「路径 + scale」缓存解码结果，覆盖同名文件后 UI 不会刷新，用户会以为换头像失败。
class AvatarService {
  const AvatarService._();

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'avatar'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 选图并落盘，返回新文件的绝对路径。取消/权限被拒/出错分开返回。
  ///
  /// [oldPath] 传进来会顺手删掉，避免每换一次多留一个文件。
  static Future<PickOutcome> pickFromGallery({String oldPath = ''}) async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // 头像最大也就显示 56pt，512 足够清晰（高 DPI 下 3x = 168）。
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 90,
      );
      if (picked == null) return const PickOutcome(PickResult.cancelled);

      final dir = await _dir();
      final name = 'avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final saved = await File(picked.path).copy(p.join(dir.path, name));
      await _prune(keep: saved.path);
      return PickOutcome(PickResult.ok, path: saved.path);
    } catch (e) {
      debugPrint('头像选择失败: $e');
      final s = e.toString().toLowerCase();
      return PickOutcome((s.contains('denied') ||
              s.contains('permission') ||
              s.contains('拒绝'))
          ? PickResult.denied
          : PickResult.error);
    }
  }

  /// 删掉目录里除 [keep] 以外的所有头像（旧版本文件 / 换图残留）。
  static Future<void> _prune({String keep = ''}) async {
    try {
      final dir = await _dir();
      await for (final f in dir.list()) {
        if (f is File && f.path != keep) {
          await f.delete();
        }
      }
    } catch (_) {
      // 清不掉不影响使用
    }
  }

  /// 恢复默认头像时把磁盘也清干净。
  static Future<void> clear() => _prune();
}
