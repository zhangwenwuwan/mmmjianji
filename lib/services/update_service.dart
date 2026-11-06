import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/update_config.dart';
import '../core/version.dart';

/// 检查更新：只查「有没有新版」，不下载、不安装。
///
/// 为什么只用 `dart:io` 的 HttpClient、不引 http 包：这是全 App 唯一一次
/// 主动联网（其余数据都只存本机），为此加一个依赖不划算，10 行代码足够。
///
/// 这条路走的是「自建清单」而不是应用商店 API —— 简记不上架，
/// 商店那套用不了。清单是一个静态 JSON，和 APK 一起放在自己的网站上。
class UpdateInfo {
  const UpdateInfo({
    required this.versionName,
    required this.versionCode,
    this.sizeBytes,
    this.sha256,
    this.minSupportedCode,
    this.notes = '',
    this.apkUrl = '',
  });

  final String versionName;

  /// 必须用 versionCode 比较，不能用字符串比 versionName：
  /// `'1.4.10' < '1.4.9'` 是 true，字符串比较会把新版本判成旧的。
  final int versionCode;

  final int? sizeBytes;
  final String? sha256;

  /// 低于这个 versionCode 的客户端「必须更新」（强制更新）。
  final int? minSupportedCode;

  final String notes;
  final String apkUrl;

  /// 本地版本低于 minSupportedCode = 这个版本不再兼容，不给「以后再说」。
  bool get forced =>
      minSupportedCode != null && appBuild < minSupportedCode!;

  bool get isNewer => versionCode > appBuild;
}

/// 解析更新清单。**任何字段不合法都返回 null** ——
/// 宁可说「检查失败」，也不要拿半截数据弹一个「发现新版本 v」吓人。
UpdateInfo? parseUpdateManifest(String raw) {
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;

  final name = (decoded['versionName'] as Object?)?.toString().trim() ?? '';
  final codeRaw = decoded['versionCode'];
  // 允许 65 / 65.0（JSON 数字在某些服务端会被写成浮点）
  final code = codeRaw is num ? codeRaw.toInt() : int.tryParse('$codeRaw');
  if (name.isEmpty || code == null || code <= 0) return null;

  final sizeRaw = decoded['size'];
  final minRaw = decoded['minSupportedCode'];
  return UpdateInfo(
    versionName: name,
    versionCode: code,
    sizeBytes: sizeRaw is num ? sizeRaw.toInt() : null,
    sha256: (decoded['sha256'] as Object?)?.toString(),
    minSupportedCode: minRaw is num ? minRaw.toInt() : null,
    notes: (decoded['notes'] as Object?)?.toString() ?? '',
    apkUrl: (decoded['apkUrl'] as Object?)?.toString() ?? '',
  );
}

enum UpdateStatus {
  /// 还没配置 kUpdateManifestUrl
  notConfigured,

  /// 已经是最新
  latest,

  /// 有新版本
  available,

  /// 检查失败（网络 / 格式 / HTTP 状态）
  failed,
}

class UpdateCheck {
  const UpdateCheck(
    this.status, {
    this.info,
    this.message,
    this.transient = false,
  });

  final UpdateStatus status;
  final UpdateInfo? info;

  /// 失败原因，直接给用户看的一句话（不抛原始异常堆栈）
  final String? message;

  /// 网络层抖动（连不上 / 超时 / 半路被掐断）→ 值得再试一次。
  ///
  /// 2026-11-07 真机实测：这台手机首连 github.com 30s 超时，紧接着的第二次
  /// 0.5s 就通了。只试一次 = 把「其实能更新」直接报成「上次检查失败」。
  final bool transient;
}

class UpdateService {
  const UpdateService._();

  /// 一共试几次。第二次几乎总能通（见 [UpdateCheck.transient] 的实测记录），
  /// 所以 2 次足够，再多只是让用户多等。
  static const int maxTries = 2;

  /// 两次之间稍等一下再打，紧接着重连反而容易继续被掐。
  static const Duration retryGap = Duration(milliseconds: 600);

  /// 查一次。**永远不抛异常**，失败都折成 [UpdateStatus.failed]，
  /// 让设置页那行不至于因为断网变成红色报错。
  ///
  /// 网络层抖动会自动重试（[maxTries] 次）；格式错、HTTP 4xx/5xx 这类
  /// 重试也没用的失败立刻返回。
  ///
  /// [url] 只在测试里传（起一个本地 HttpServer 走真实网络路径），
  /// 正式调用不传，走 [kUpdateManifestUrl]。
  static Future<UpdateCheck> check({
    String? url,
    int tries = maxTries,
  }) async {
    final target = (url ?? kUpdateManifestUrl).trim();
    if (target.isEmpty) return const UpdateCheck(UpdateStatus.notConfigured);

    final Uri uri;
    try {
      uri = Uri.parse(target);
    } catch (_) {
      return const UpdateCheck(UpdateStatus.failed, message: '更新地址写得不对');
    }

    UpdateCheck last = const UpdateCheck(UpdateStatus.failed, message: '检查失败');
    for (var i = 0; i < tries; i++) {
      last = await _attempt(uri);
      if (!last.transient) return last;
      if (i + 1 < tries) await Future<void>.delayed(retryGap);
    }
    return last;
  }

  static Future<UpdateCheck> _attempt(Uri uri) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      // 公共 CDN 挂了会一直挂着；超时必须自己兜住
      ..idleTimeout = const Duration(seconds: 8);
    try {
      final req = await client.getUrl(uri);
      // 带上版本号：服务端可以据此做灰度（老版本返回新版，最新版返回自己）
      req.headers.set('User-Agent', 'jianji/$appVersion+$appBuild');
      final res = await req.close().timeout(const Duration(seconds: 15));
      if (res.statusCode != HttpStatus.ok) {
        return UpdateCheck(UpdateStatus.failed,
            message: '服务器返回 ${res.statusCode}');
      }
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 15));
      final info = parseUpdateManifest(body);
      if (info == null) {
        return const UpdateCheck(UpdateStatus.failed, message: '更新清单格式不对');
      }
      return info.isNewer
          ? UpdateCheck(UpdateStatus.available, info: info)
          : UpdateCheck(UpdateStatus.latest, info: info);
    } on SocketException {
      return const UpdateCheck(UpdateStatus.failed,
          message: '网络连不上', transient: true);
    } on TimeoutException {
      return const UpdateCheck(UpdateStatus.failed,
          message: '请求超时', transient: true);
    } on HandshakeException {
      return const UpdateCheck(UpdateStatus.failed,
          message: 'HTTPS 证书有问题', transient: true);
    } on HttpException {
      // 连接被中途掐断（移动网络下很常见）
      return const UpdateCheck(UpdateStatus.failed,
          message: '连接中断', transient: true);
    } catch (e) {
      return UpdateCheck(UpdateStatus.failed, message: '检查失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  /// 字节数 → 「28.3 MB」（弹窗里给人看的大小）
  static String sizeLabel(int? bytes) {
    if (bytes == null || bytes <= 0) return '';
    final mb = bytes / 1024 / 1024;
    return mb >= 1
        ? '${mb.toStringAsFixed(1)} MB'
        : '${(bytes / 1024).toStringAsFixed(0)} KB';
  }
}
