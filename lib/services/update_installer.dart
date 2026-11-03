import 'dart:io';

import 'package:flutter/services.dart';

/// 安装结果。和 Kotlin 侧 `installApk` 返回的状态码一一对应。
enum InstallResult {
  /// 已经拉起系统安装器（用户还要点一下「安装」）
  ok,

  /// 文件不在 / 是空文件
  missingFile,

  /// SHA-256 对不上（下载被截断、CDN 返回了错误页、或包被换过）
  hashMismatch,

  /// 用户还没允许「安装未知应用」
  noPermission,

  /// 其它失败（原生抛异常、通道不可用）
  error,
}

/// 应用内更新的「安装」那一步 —— 唯一需要原生代码的地方。
///
/// 为什么必须走原生：Flutter 没有办法构造 `Intent`。常见的做法是引
/// `open_filex` / `permission_handler` 两个插件，但那样会多两个依赖、
/// 而且 open_filex 在部分 ROM 上会忽略 MIME type 导致安装器认不出文件。
/// 这里只有 40 行 Kotlin（见 MainActivity.kt 的 `jianji/update` 通道），
/// 行为完全可控，也不增加 APK 体积。
class UpdateInstaller {
  const UpdateInstaller._();

  static const _channel = MethodChannel('jianji/update');

  /// 用户是否已允许「安装未知应用」。
  ///
  /// 通道不可用（桌面端 / 单元测试 / 非 Android）时返回 false，
  /// 让调用方走「去设置」的分支而不是崩掉。
  static Future<bool> canInstall() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('canInstall') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// 打开系统的「安装未知应用」设置页。
  static Future<bool> openInstallSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openInstallSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 校验（可选）并拉起安装器。
  ///
  /// [sha256] 传了就一定会校验：文件内容对不上直接返回 [InstallResult.hashMismatch]，
  /// **不会把半个文件交给安装器**。
  static Future<InstallResult> install(String path, {String? sha256}) async {
    if (!Platform.isAndroid) return InstallResult.error;
    try {
      final status = await _channel.invokeMethod<String>('installApk', {
        'path': path,
        'sha256': sha256,
      });
      return switch (status) {
        'ok' => InstallResult.ok,
        'missing_file' => InstallResult.missingFile,
        'hash_mismatch' => InstallResult.hashMismatch,
        'no_permission' => InstallResult.noPermission,
        _ => InstallResult.error,
      };
    } on PlatformException {
      return InstallResult.error;
    } on MissingPluginException {
      return InstallResult.error;
    }
  }
}
