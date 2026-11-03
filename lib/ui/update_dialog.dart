import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/version.dart';
import '../services/download_service.dart';
import '../services/update_installer.dart';
import '../services/update_service.dart';
import 'common.dart';
import 'theme.dart';

/// 更新弹窗：说明 → 下载（带进度/取消）→ 校验 → 拉起系统安装器。
///
/// 为什么单独一个文件：它有一台小小的状态机（权限 / 下载 / 失败 / 完成），
/// 塞进 profile_page 会把那个文件撑爆，也不方便单独改文案。
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

enum _Stage { intro, needPermission, downloading, failed }

class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.info});

  final UpdateInfo info;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  _Stage _stage = _Stage.intro;
  DownloadProgress? _progress;
  DownloadTask? _task;
  String? _error;

  @override
  void dispose() {
    // 对话框被关掉（强制关闭/返回）时把下载停掉，别在后台偷偷下
    _task?.cancel();
    super.dispose();
  }

  String get _apkName {
    final url = widget.info.apkUrl.trim();
    final last = url.isEmpty ? '' : url.split('/').last.split('?').first;
    if (last.toLowerCase().endsWith('.apk')) return last;
    return 'jianji-${widget.info.versionCode}-arm64.apk';
  }

  Future<Directory> _downloadDir() async {
    final tmp = await getTemporaryDirectory();
    return Directory('${tmp.path}${Platform.pathSeparator}updates');
  }

  Future<void> _start() async {
    // 先看系统给不给装：没权限就先去开，别下完 28MB 才发现装不了
    final allowed = await UpdateInstaller.canInstall();
    if (!mounted) return;
    if (!allowed) {
      setState(() => _stage = _Stage.needPermission);
      return;
    }
    await _download();
  }

  Future<void> _download() async {
    final url = Uri.tryParse(widget.info.apkUrl.trim());
    if (url == null || url.host.isEmpty) {
      setState(() {
        _stage = _Stage.failed;
        _error = '清单里没有可用的下载地址';
      });
      return;
    }
    final task = DownloadTask();
    setState(() {
      _task = task;
      _stage = _Stage.downloading;
      _progress = const DownloadProgress(
          received: 0, total: null, bytesPerSecond: 0);
      _error = null;
    });

    try {
      final dir = await _downloadDir();
      final file = await DownloadService.downloadApk(
        url: url,
        dir: dir,
        fileName: _apkName,
        task: task,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      await _install(file, dir);
    } on DownloadCancelled {
      if (mounted) setState(() => _stage = _Stage.intro);
    } on DownloadFailed catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = e.message;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failed;
          _error = '$e';
        });
      }
    }
  }

  Future<void> _install(File file, Directory dir) async {
    final r = await UpdateInstaller.install(file.path,
        sha256: widget.info.sha256);
    if (!mounted) return;
    switch (r) {
      case InstallResult.ok:
        // 交出去了：装完这个进程会被系统杀掉重启，这里能做的只有提示
        await DownloadService.clean(dir);
        if (!mounted) return;
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context)
            .toast('安装器已打开，按提示完成安装');
      case InstallResult.hashMismatch:
        // 校验没过：删掉坏包，让用户重下（不要拿半个文件去装）
        await DownloadService.clean(dir);
        if (!mounted) return;
        setState(() {
          _stage = _Stage.failed;
          _error = '文件校验没通过（可能下载被截断或包被替换过），已删除，请重试';
        });
      case InstallResult.noPermission:
        setState(() => _stage = _Stage.needPermission);
      case InstallResult.missingFile:
        setState(() {
          _stage = _Stage.failed;
          _error = '下载的文件不见了，请重试';
        });
      case InstallResult.error:
        setState(() {
          _stage = _Stage.failed;
          _error = '安装失败，请手动到下载页安装';
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return PopScope(
      // 下载中不许点外面/返回关掉：半截文件会留在缓存里，也容易让用户以为没在下载
      canPop: _stage != _Stage.downloading,
      child: AlertDialog(
        title: Text('发现新版本 ${info.versionName}'),
        content: switch (_stage) {
          _Stage.intro => _intro(context),
          _Stage.needPermission => _permission(context),
          _Stage.downloading => _downloading(context),
          _Stage.failed => _failed(context),
        },
        actions: _actions(context),
      ),
    );
  }

  Widget _intro(BuildContext context) {
    final info = widget.info;
    final size = UpdateService.sizeLabel(info.sizeBytes);
    return Column(
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
          Text('这个版本太旧了，请尽快更新：新版可能改了数据格式。',
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
                      fontSize: 12, height: 1.6, color: Palette.inkSoft(context))),
            ),
          ),
        ],
        const SizedBox(height: 10),
        Text('装完会自动覆盖旧版本，账目数据都保留（签名一致）。',
            style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
      ],
    );
  }

  Widget _permission(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('需要先允许「安装未知应用」',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Palette.ink(context))),
        const SizedBox(height: 8),
        Text(
          '系统默认不允许 App 自己装包。点下面的按钮去设置里给简记打开这个开关，'
          '回来就能继续下载。\n\n'
          '国产 ROM 的位置不完全一样，找不到时按这个路径：'
          '设置 → 应用管理 → 简记 → 安装未知应用。',
          style: TextStyle(
              fontSize: 12, height: 1.6, color: Palette.inkSoft(context)),
        ),
      ],
    );
  }

  Widget _downloading(BuildContext context) {
    final p = _progress;
    final frac = p?.fraction;
    final received = p == null ? 0 : p.received;
    final total = p?.total;
    final speed = p?.bytesPerSecond ?? 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          frac == null
              ? '正在下载 ${UpdateService.sizeLabel(received)}'
              : '正在下载 ${(frac * 100).round()}%',
          style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Palette.ink(context)),
        ),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            // 服务器没给 Content-Length 时就是一条来回跑的不确定进度
            value: frac,
            minHeight: 6,
            backgroundColor: Palette.hairline(context),
            valueColor: AlwaysStoppedAnimation(Palette.brand(context)),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          [
            if (total != null)
              '${UpdateService.sizeLabel(received)} / ${UpdateService.sizeLabel(total)}',
            if (speed > 0)
              '${(speed / 1024 / 1024).toStringAsFixed(1)} MB/s',
          ].join(' · '),
          style: TextStyle(fontSize: 11, color: Palette.inkFaint(context)),
        ),
        const SizedBox(height: 10),
        Text('下载完会自动打开安装器，按系统提示点「安装」即可。',
            style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
      ],
    );
  }

  Widget _failed(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('更新没成功',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Palette.expense)),
        const SizedBox(height: 8),
        Text(_error ?? '未知错误',
            style: TextStyle(
                fontSize: 12, height: 1.6, color: Palette.inkSoft(context))),
        if (widget.info.apkUrl.trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('也可以复制下载地址，用浏览器手动下载：',
              style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
          const SizedBox(height: 2),
          SelectableText(widget.info.apkUrl,
              style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
        ],
      ],
    );
  }

  List<Widget> _actions(BuildContext context) {
    switch (_stage) {
      case _Stage.intro:
        return [
          if (!widget.info.forced)
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('稍后')),
          FilledButton(
            onPressed: _start,
            child: Text(widget.info.forced ? '立即更新' : '下载并更新'),
          ),
        ];
      case _Stage.needPermission:
        return [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消')),
          TextButton(
            onPressed: () async {
              await UpdateInstaller.openInstallSettings();
            },
            child: const Text('去设置'),
          ),
          FilledButton(
            onPressed: _start,
            child: const Text('我已开启'),
          ),
        ];
      case _Stage.downloading:
        return [
          TextButton(
            onPressed: () => _task?.cancel(),
            child: const Text('取消下载'),
          ),
        ];
      case _Stage.failed:
        return [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭')),
          FilledButton(onPressed: _download, child: const Text('重试')),
        ];
    }
  }
}

