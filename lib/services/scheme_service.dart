/// URL Scheme 的原生通道。
///
/// 冷启动：MainActivity 把 launch intent 里的 jianji:// 存在原生侧，
/// Dart 就绪后调 [pullInitial] 主动取（推早了没人接，消息会丢）。
///
/// 热启动（onNewIntent）：MainActivity 通过 [install] 挂的回调把**原始完整
/// URI** 推给 Dart（'onScheme'）。为什么不用引擎自带的转发——引擎走
/// flutter/navigation，WidgetsApp 会剥掉 scheme（jianji://voice → '/'），
/// 页面永远打不开（2026-11-09 真机实锤）。
///
/// 注意：通道只管「搬字符串」，解析在 core/scheme.dart，
/// 路由投递在 main.dart。
library;

import 'package:flutter/services.dart';

class SchemeService {
  SchemeService._();

  static const MethodChannel _channel = MethodChannel('jianji/scheme');

  static void Function(String raw)? _onScheme;

  /// 挂上热启动回调。原生 onNewIntent 会推 'onScheme' 过来。
  static void install(void Function(String raw) onScheme) {
    _onScheme = onScheme;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onScheme' && call.arguments is String) {
        _onScheme?.call(call.arguments as String);
      }
    });
  }

  /// 取冷启动链接。返回 null = 本次启动没有带 jianji://。
  static Future<String?> pullInitial() async {
    try {
      return await _channel.invokeMethod<String>('getInitialScheme');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null; // 测试环境没有原生侧
    }
  }
}
