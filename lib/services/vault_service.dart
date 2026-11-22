import 'dart:io';

import 'package:flutter/services.dart';

/// 防爆柜模块（LaClave 内嵌版）入口。密码库是这个功能的旧叫法。
///
/// 原生侧由 com.jianji.vault.VaultActivity 承载，通过 jianji/vault 通道拉起。
/// 只有 Android 支持；iOS / 桌面静默不可用（tile 会隐藏）。
class VaultService {
  VaultService._();

  static const MethodChannel _ch = MethodChannel('jianji/vault');

  static bool get isSupported => Platform.isAndroid;

  static Future<bool> open() async {
    if (!isSupported) return false;
    try {
      final ok = await _ch.invokeMethod<bool>('open') ?? false;
      return ok;
    } on PlatformException catch (e) {
      throw Exception('打开防爆柜失败：${e.message}');
    }
  }
}
