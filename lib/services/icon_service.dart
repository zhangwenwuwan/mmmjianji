import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'pick_result.dart';

export 'pick_result.dart';

/// 自定义图标（从相册选图当分类/账户/愿望的图标）。
///
/// **约定**：`glyph` 字段里存
/// - `'🍜'` —— 普通 emoji（老数据）；
/// - `'img:20261025_143012.jpg'` —— 自定义图标，`img:` 前缀 + **相对文件名**。
///
/// 为什么存相对文件名而不是绝对路径：绝对路径在换机、恢复备份、应用重装
/// 之后全都会变（封面 coverPath 就踩过这个坑，注释里写着"恢复备份后丢失"）。
/// 渲染时统一拼到 icons 目录，备份 JSON 里带的也只是文件名，跟着走。
///
/// 为什么不给表加列：glyph 本来就是 TEXT 列，前缀约定零迁移；
/// 加列的话 buckets/pockets/wishes/books 四张表都要改、导出导入也要跟着改，
/// 而多出来的判断逻辑一行都不少。
class IconService {
  const IconService._();

  static const _prefix = 'img:';

  /// 已解析的 glyph → 绝对路径。避免每帧发 IO。
  static final Map<String, String> _resolved = {};

  /// glyph → 解析 Future。
  ///
  /// **缓存 Future 本身**（不是只缓存结果）：AppGlyph 用 FutureBuilder，
  /// 每次 rebuild 都会 new 一个 Future 的话，FutureBuilder 会不停地
  /// 退订重订（虽然不至于死循环，但白白浪费）。Future 实例稳定就没事。
  static final Map<String, Future<String?>> _futures = {};

  static bool isImage(String glyph) => glyph.startsWith(_prefix);

  /// icons 目录（应用私有目录下的 icons/）
  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'icons'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 从相册选一张图 → 缩到 256px → 拷进私有目录 → 返回 `img:xxx.jpg`。
  ///
  /// 返回 [PickOutcome]：权限被拒（denied）和用户取消（cancelled）要分开说，
  /// 否则被拒的人只看到「没有选中图片」，永远不知道要去设置里开权限。
  static Future<PickOutcome> pickFromGallery() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // 图标只有几十像素宽，256 足够，再大只是白占存储。
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 85,
      );
      if (picked == null) return const PickOutcome(PickResult.cancelled);

      final dir = await _dir();
      final name = 'icon_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(picked.path).copy(p.join(dir.path, name));
      return PickOutcome(PickResult.ok, path: '$_prefix$name');
    } catch (e) {
      debugPrint('自定义图标选择失败: $e');
      final s = e.toString().toLowerCase();
      return PickOutcome((s.contains('denied') ||
              s.contains('permission') ||
              s.contains('拒绝'))
          ? PickResult.denied
          : PickResult.error);
    }
  }

  /// `'img:xxx.jpg'` → 绝对路径；不是图片图标返回 null。
  static Future<String?> resolve(String glyph) {
    if (!isImage(glyph)) return Future.value(null);
    return _futures.putIfAbsent(glyph, () => _resolve(glyph));
  }

  static Future<String?> _resolve(String glyph) async {
    final hit = _resolved[glyph];
    if (hit != null) return hit;
    try {
      final dir = await _dir();
      final path = p.join(dir.path, glyph.substring(_prefix.length));
      if (!await File(path).exists()) return null;
      _resolved[glyph] = path;
      return path;
    } catch (_) {
      return null;
    }
  }

  /// 删掉一个自定义图标文件（分类/账户被删时调用，顺手清磁盘）。
  ///
  /// 找不到就算了 —— 用户可能刚换过图，文件已经被新的替代。
  static Future<void> remove(String glyph) async {
    if (!isImage(glyph)) return;
    _resolved.remove(glyph);
    _futures.remove(glyph);
    try {
      final dir = await _dir();
      final f = File(p.join(dir.path, glyph.substring(_prefix.length)));
      if (await f.exists()) await f.delete();
    } catch (_) {
      // 删不掉不影响使用
    }
  }
}
