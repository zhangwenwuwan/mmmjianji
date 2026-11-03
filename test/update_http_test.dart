import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/version.dart';
import 'package:jianji/services/update_service.dart';

/// 更新检查的**网络分支**：起一个本地 HttpServer，用真实 HTTP 走一遍。
///
/// 不 mock HttpClient —— 我们要验的正是「发请求、读状态码、解 body、
/// 判版本」这条链，mock 掉就只剩自己的断言了。
void main() {
  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    // 每个请求由测试自己决定怎么回
    server.listen((req) async {
      final path = req.uri.path;
      if (path == '/v500.json') {
        req.response.statusCode = 500;
        await req.response.close();
        return;
      }
      final body = switch (path) {
        '/newer.json' => jsonEncode({
            'versionName': '9.9.9',
            'versionCode': appBuild + 1,
            'size': 28334998,
            'notes': '新功能',
            'apkUrl': 'https://example.com/a.apk',
          }),
        '/same.json' => jsonEncode({
            'versionName': '1.4.20',
            'versionCode': appBuild,
          }),
        '/forced.json' => jsonEncode({
            'versionName': '9.9.9',
            'versionCode': appBuild + 5,
            'minSupportedCode': appBuild + 1,
          }),
        '/broken.json' => '{"versionName":',
        _ => '{}',
      };
      req.response.headers.contentType = ContentType.json;
      req.response.write(body);
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('远程版本更新 → available，且字段都解出来了', () async {
    final r = await UpdateService.check(url: '$base/newer.json');
    expect(r.status, UpdateStatus.available);
    expect(r.info!.versionCode, appBuild + 1);
    expect(UpdateService.sizeLabel(r.info!.sizeBytes), '27.0 MB');
  });

  test('版本相同 → latest（不弹更新）', () async {
    final r = await UpdateService.check(url: '$base/same.json');
    expect(r.status, UpdateStatus.latest);
  });

  test('minSupportedCode 高于本地 → forced', () async {
    final r = await UpdateService.check(url: '$base/forced.json');
    expect(r.status, UpdateStatus.available);
    expect(r.info!.forced, isTrue);
  });

  test('HTTP 500 → failed，带状态码，不抛异常', () async {
    final r = await UpdateService.check(url: '$base/v500.json');
    expect(r.status, UpdateStatus.failed);
    expect(r.message, contains('500'));
  });

  test('body 是半截 JSON → failed（不是崩）', () async {
    final r = await UpdateService.check(url: '$base/broken.json');
    expect(r.status, UpdateStatus.failed);
  });

  test('地址为空 → notConfigured，根本不发请求', () async {
    final r = await UpdateService.check(url: '');
    expect(r.status, UpdateStatus.notConfigured);
  });

  test('连不上的端口 → failed（网络异常被兜住）', () async {
    // 先关掉 server，确保这个端口没人监听
    final port = server.port;
    await server.close(force: true);
    final r = await UpdateService.check(url: 'http://127.0.0.1:$port/x.json');
    expect(r.status, UpdateStatus.failed);
  });
}
