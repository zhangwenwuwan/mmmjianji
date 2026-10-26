import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/cover_palette.dart';

/// 首页主封面的文件与取色管理。
///
/// 关键设计：**不存 ImagePicker 返回的原路径**。
/// 那个路径在系统缓存目录里（`/data/.../cache/xxx.jpg`），清理缓存、
/// 或系统内存吃紧时会被回收，用户下次打开就会看到「封面没了」——
/// 而且他什么也没做。所以选完图立刻复制一份到应用私有目录，
/// 存副本路径。
class CoverService {
  const CoverService._();

  static const _fileName = 'home_cover.jpg';

  /// 应用私有目录里的固定封面路径。
  static Future<String> coverPath() async {
    final dir = await getApplicationSupportDirectory();
    final coverDir = Directory(p.join(dir.path, 'cover'));
    if (!await coverDir.exists()) {
      await coverDir.create(recursive: true);
    }
    return p.join(coverDir.path, _fileName);
  }

  /// 从相册选一张图 → 复制到私有目录 → 取色。
  ///
  /// 返回 null 表示用户取消了（不是错误，调用方静默返回即可）。
  /// 注意 [palette] 也可能为 null：图片能存下来、但（比如纯白截图）抽不出
  /// 可用主色。这时候封面照常显示，只是不换肤——不能因为取不到色就
  /// 把用户选的图丢掉。
  static Future<({String path, CoverPalette? palette})?> pick(
      {ImageSource source = ImageSource.gallery}) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      // 封面是背景图，不需要原图。2048 宽足够在 1080p 屏上不糊，
      // 同时把「解码-取色-复制」三步的耗时压到几百毫秒级。
      maxWidth: 2048,
      imageQuality: 88,
    );
    if (picked == null) return null;

    final target = await coverPath();
    await File(picked.path).copy(target);

    final palette = await extract(target);
    return (path: target, palette: palette);
  }

  /// 对已存在的封面重新取色（用户点「重新取色」）。
  static Future<CoverPalette?> extract(String path) async {
    try {
      final bytes = await File(path).readAsBytes();
      return await paletteFromImageBytes(bytes);
    } catch (e) {
      debugPrint('封面读取失败: $e');
      return null;
    }
  }

  /// 从已有的封面路径重新取色（启动时封面文件在、但 seed 丢了的情况）。
  static Future<CoverPalette?> reextractIfNeeded(String path) async {
    if (path.isEmpty) return null;
    if (!await File(path).exists()) return null;
    return extract(path);
  }

  static Future<void> remove() async {
    try {
      final path = await coverPath();
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      debugPrint('封面删除失败: $e');
    }
  }
}
