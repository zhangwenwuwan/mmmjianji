import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/version.dart';
import '../services/update_service.dart';
import 'theme.dart';

/// 更新弹窗：说明版本 → **把 APK 下载地址交给外部浏览器**。
///
/// 2026-11-07 改：原来是在 App 内下载 APK、校验 sha256、再走
/// PackageInstaller 会话拉起系统安装器。国产 ROM（尤其这台 OPPO）对
/// 「安装未知应用」开关、会话安装、content:// 读取各有各的限制，
/// 实测经常装不上；而浏览器 / 系统下载管理器点 APK 安装走的是系统自己的
/// 路径，成功率高得多。所以这里只保留一个动作：`launchUrl(外部浏览器)`。
///
/// 底层的 download_service / update_installer / 原生安装通道暂不删除 ——
/// 它们仍被 download_test 覆盖，且构建脚本对 REQUEST_INSTALL_PACKAGES、
/// PackageInstaller、jianji/update 有构建期硬校验；删了要连原生层一起改，
/// 没必要为了一个弹窗冒这个风险。现在只是不再从这个弹窗调用。
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info,
) {
  return showDialog<void>(
    context: context,
    // 强制更新也不锁死：用户可能正断网，锁住等于让他打不开账本
    barrierDismissible: !info.forced,
    builder: (_) => _UpdateSheet(info: info),
  );
}

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.info});

  final UpdateInfo info;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  /// 打开浏览器失败 / 清单没给地址时，展示可复制的链接作为兜底。
  String? _error;

  /// 清单是远端下发的，别把 `file://` / `javascript:` 之类直接丢给外部浏览器。
  /// 只放行 http/https，且必须有 host。
  Uri? get _downloadUri {
    final raw = widget.info.apkUrl.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host.isEmpty) return null;
    if (uri.scheme != 'https' && uri.scheme != 'http') return null;
    return uri;
  }

  Future<void> _openInBrowser() async {
    final uri = _downloadUri;
    if (uri == null) {
      if (mounted) {
        setState(() =>
            _error = '清单里没有可用的下载地址，可复制下面的链接手动打开');
      }
      return;
    }
    try {
      // externalApplication：强制交给外部浏览器，别弹 App 内 WebView。
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      if (!ok) {
        setState(() =>
            _error = '没找到能打开链接的浏览器，可复制下面的链接手动打开');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() =>
          _error = '打开浏览器失败，可复制下面的链接手动打开');
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final size = UpdateService.sizeLabel(info.sizeBytes);
    return AlertDialog(
      title: Text('发现新版本 ${info.versionName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '当前 $appVersion（$appBuild） → 新版 ${info.versionName}'
            '（${info.versionCode}）${size.isEmpty ? '' : ' · $size'}',
            style: TextStyle(fontSize: 12, color: Palette.inkSoft(context)),
          ),
          if (info.forced) ...[
            const SizedBox(height: 8),
            const Text('这个版本太旧了，请尽快更新：新版可能改了数据格式。',
                style: TextStyle(fontSize: 12, color: Palette.expense)),
          ],
          if (info.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('更新内容',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Palette.ink(context))),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: SingleChildScrollView(
                child: Text(info.notes,
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.6,
                        color: Palette.inkSoft(context))),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '点「用浏览器下载」会打开浏览器下载安装包；下载完点通知栏或「下载」里的 APK，'
            '按系统提示安装即可。装完自动覆盖旧版本，账目数据保留（签名一致）。',
            style: TextStyle(
                fontSize: 11, height: 1.5, color: Palette.inkFaint(context)),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(fontSize: 12, color: Palette.expense)),
            const SizedBox(height: 4),
            SelectableText(widget.info.apkUrl,
                style:
                    TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
          ],
        ],
      ),
      actions: [
        if (!info.forced)
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('稍后')),
        FilledButton(
          onPressed: _openInBrowser,
          child: const Text('用浏览器下载'),
        ),
      ],
    );
  }
}
