import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';

/// 附件（图片凭证）的本地存储。
///
/// 选好的图会被**复制**进应用私有目录 `attachments/book_<id>/`，
/// 这样原图被删、相册被清都不会让凭证丢失。
/// 只压缩到长边 1600 / 质量 82，一张凭证通常 100~300KB。
class AttachmentService {
  AttachmentService._();

  static final _picker = ImagePicker();

  static Future<Directory> _dir(int bookId) async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, 'attachments', 'book_$bookId'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<String> saveFile(File src, int bookId) async {
    final dir = await _dir(bookId);
    final ext = p.extension(src.path).isEmpty ? '.jpg' : p.extension(src.path);
    final name =
        '${DateTime.now().millisecondsSinceEpoch}_${src.path.hashCode.abs()}$ext';
    final dest = File(p.join(dir.path, name));
    await src.copy(dest.path);
    AppLog.info('attachment', '已保存附件 ${dest.path}');
    return dest.path;
  }

  /// 从相册选一张
  static Future<String?> pickFromGallery(int bookId) async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 82,
      );
      if (x == null) return null;
      return saveFile(File(x.path), bookId);
    } catch (e) {
      AppLog.warn('attachment', '相册选图失败: $e');
      return null;
    }
  }

  /// 拍一张
  static Future<String?> pickFromCamera(int bookId) async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 82,
      );
      if (x == null) return null;
      return saveFile(File(x.path), bookId);
    } catch (e) {
      AppLog.warn('attachment', '拍照失败: $e');
      return null;
    }
  }

  static Future<void> deleteFile(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (e) {
      AppLog.warn('attachment', '删除附件文件失败: $e');
    }
  }

  /// 删掉某个账本下的全部附件文件（删账本时调用）。
  ///
  /// 只删数据库行是不够的：图片文件留在 documents 里，
  /// 「存储管理」会一直显示占用，用户也删不掉。
  static Future<void> deleteBookDir(int bookId) async {
    try {
      final d = await _dir(bookId);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (e) {
      AppLog.warn('attachment', '删除账本附件目录失败: $e');
    }
  }

  /// 删掉全部附件文件（清空数据 / 恢复备份时调用）。
  /// 备份里本来就不含凭证，留着只会挂到错的新流水上。
  static Future<void> deleteAll() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final d = Directory(p.join(base.path, 'attachments'));
      if (await d.exists()) await d.delete(recursive: true);
    } catch (e) {
      AppLog.warn('attachment', '删除附件目录失败: $e');
    }
  }

  static Future<int> totalBytes(int bookId) async {
    try {
      final dir = await _dir(bookId);
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) total += await e.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}
