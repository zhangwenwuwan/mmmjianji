import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/version.dart';
import 'package:jianji/services/update_service.dart';

/// 钉住「网络抖动要自动重试」这条。
///
/// 2026-11-07 真机实测（OPPO PBEM00，移动网络）：首连 github.com 30s 超时，
/// 紧接着的第二次 0.5s 就通了。原来的实现只打一枪，于是「其实能更新」
/// 被报成「上次检查失败」。这里用本地 HttpServer 复现「第一次掐断连接」。
void main() {
  Future<HttpServer> serve(void Function(HttpRequest req, int hit) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var hit = 0;
    server.listen((req) => handler(req, ++hit));
    return server;
  }

  test('第一次连接被掐断 → 自动再试一次并成功', () async {
    var hits = 0;
    final server = await serve((req, hit) async {
      hits = hit;
      if (hit == 1) {
        // 收下 TCP 连接后直接销毁 socket：客户端读到 HttpException
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.destroy();
        return;
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'versionName': '1.4.55',
        'versionCode': appBuild + 1,
        'apkUrl': 'https://example.com/a.apk',
      }));
      await req.response.close();
    });

    final r = await UpdateService.check(url: 'http://127.0.0.1:${server.port}/v.json');
    expect(r.status, UpdateStatus.available);
    expect(r.info!.versionCode, appBuild + 1);
    expect(hits, 2, reason: '应该正好重试一次');
    await server.close(force: true);
  });

  test('格式错 / HTTP 500 不重试，只打一枪', () async {
    var hits = 0;
    final server = await serve((req, hit) async {
      hits = hit;
      req.response.statusCode = 500;
      await req.response.close();
    });

    final r = await UpdateService.check(url: 'http://127.0.0.1:${server.port}/v.json');
    expect(r.status, UpdateStatus.failed);
    expect(hits, 1, reason: '服务端明确报错，重试没有意义');
    await server.close(force: true);
  });

  test('tries=1 时退回单次行为（测试与排查用）', () async {
    var hits = 0;
    final server = await serve((req, hit) async {
      hits = hit;
      final socket = await req.response.detachSocket(writeHeaders: false);
      socket.destroy();
    });

    final r = await UpdateService.check(
        url: 'http://127.0.0.1:${server.port}/v.json', tries: 1);
    expect(r.status, UpdateStatus.failed);
    expect(hits, 1);
    await server.close(force: true);
  });
}
