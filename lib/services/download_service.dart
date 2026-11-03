import 'dart:async';
import 'dart:io';

/// 用户点了「取消」：抛它让调用方区分「取消」和「失败」。
class DownloadCancelled implements Exception {
  const DownloadCancelled();
  @override
  String toString() => '下载已取消';
}

/// 下载失败（网络 / HTTP 状态 / 磁盘）。带一句能给人看的话。
class DownloadFailed implements Exception {
  const DownloadFailed(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 可取消的下载任务。
class DownloadTask {
  bool _cancelled = false;
  bool get cancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// 下载进度快照。**节流后**才回调给 UI（默认 200ms 一次）——
/// 28MB 分 64KB 一块是 400 多次回调，每次都 setState 会把主线程压满，
/// 画面反而更卡。
class DownloadProgress {
  const DownloadProgress({
    required this.received,
    this.total,
    required this.bytesPerSecond,
  });

  final int received;
  final int? total;
  final int bytesPerSecond;

  /// 0~1；总大小未知时返回 null（服务器没给 Content-Length）
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }
}

/// APK 下载：流式写入文件 + 进度 + 可取消。
///
/// 不用 `dio` / `http` 的原因和检查更新一样：全 App 只有这一处联网，
/// `HttpClient` 已经够用，不为此加依赖。
/// 关键点有三个：
///  1. **流式**：不能 `res.readBytes()` 把 28MB 全塞内存（低端机会 OOM）；
///  2. **可取消**：用户等不及要能停，取消后**删掉半截文件**；
///  3. **不覆盖安装包以外的文件**：只写进 `updates/` 目录，见 FileProvider 配置。
class DownloadService {
  const DownloadService._();

  static Future<File> downloadApk({
    required Uri url,
    required Directory dir,
    required String fileName,
    DownloadTask? task,
    void Function(DownloadProgress)? onProgress,
    Duration progressInterval = const Duration(milliseconds: 200),
  }) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    final target = File('${dir.path}${Platform.pathSeparator}$fileName');
    // 上一次的残留先清掉：同名文件留着会让「下载到一半失败」变成
    // 「看起来下载完了但装不上」。
    if (await target.exists()) await target.delete();

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..idleTimeout = const Duration(seconds: 20);

    IOSink? sink;
    try {
      final req = await client.getUrl(url);
      // 有些 CDN 会按 UA 拒绝请求；带上自己的标识也方便在服务端统计版本分布
      req.headers.set('User-Agent', 'jianji-updater');
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != HttpStatus.ok) {
        throw DownloadFailed('服务器返回 ${res.statusCode}');
      }
      final total = res.contentLength > 0 ? res.contentLength : null;

      sink = target.openWrite();
      var received = 0;
      final startedAt = DateTime.now();
      var lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

      await for (final chunk in res) {
        if (task?.cancelled ?? false) throw const DownloadCancelled();
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (onProgress != null && now.difference(lastEmit) >= progressInterval) {
          lastEmit = now;
          final elapsed = now.difference(startedAt).inMilliseconds;
          onProgress(DownloadProgress(
            received: received,
            total: total,
            bytesPerSecond:
                elapsed <= 0 ? 0 : (received * 1000 / elapsed).round(),
          ));
        }
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (task?.cancelled ?? false) throw const DownloadCancelled();
      if (received == 0) throw const DownloadFailed('下载到的文件是空的');
      // 服务器给了大小就必须对得上：少一个字节都是坏包
      if (total != null && received != total) {
        throw DownloadFailed('下载不完整（$received / $total 字节）');
      }

      onProgress?.call(DownloadProgress(
        received: received,
        total: total ?? received,
        bytesPerSecond: 0,
      ));
      return target;
    } on DownloadCancelled {
      await _quietClose(sink);
      await _quietDelete(target);
      rethrow;
    } on DownloadFailed {
      await _quietClose(sink);
      await _quietDelete(target);
      rethrow;
    } on SocketException {
      await _quietClose(sink);
      await _quietDelete(target);
      throw const DownloadFailed('网络断了，换个网络再试');
    } on TimeoutException {
      await _quietClose(sink);
      await _quietDelete(target);
      throw const DownloadFailed('下载超时');
    } on FileSystemException catch (e) {
      await _quietClose(sink);
      await _quietDelete(target);
      throw DownloadFailed('写入失败（磁盘可能满了）：${e.message}');
    } catch (e) {
      await _quietClose(sink);
      await _quietDelete(target);
      throw DownloadFailed('下载失败：$e');
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _quietClose(IOSink? sink) async {
    if (sink == null) return;
    try {
      await sink.close();
    } catch (_) {}
  }

  static Future<void> _quietDelete(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 清掉 updates 目录里的旧包（装完 / 装失败都调）。
  static Future<void> clean(Directory dir) async {
    try {
      if (!await dir.exists()) return;
      await for (final e in dir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.apk')) {
          await e.delete();
        }
      }
    } catch (_) {}
  }
}
