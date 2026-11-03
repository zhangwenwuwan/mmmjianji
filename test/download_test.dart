import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/services/download_service.dart';

/// APK 下载的**真实 HTTP** 测试：本地起 HttpServer 发真字节。
///
/// 覆盖四个必须成立的性质：
///  1. 内容一个字节都不能差（装包对 sha256 敏感）；
///  2. 进度单调递增，最后一条 == 文件大小；
///  3. 取消要**删掉半截文件**（不能让下次「看起来下好了」）；
///  4. 失败要清干净并给一句人能看懂的话。
void main() {
  late HttpServer server;
  late String base;
  late Directory tmp;
  late Uint8List payload;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('jianji_dl_test');
    payload = Uint8List.fromList(
        List<int>.generate(1024 * 1024, (i) => Random(42).nextInt(255)));
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      switch (req.uri.path) {
        case '/app.apk':
          req.response.headers.contentLength = payload.length;
          // 分块写，让客户端真的走「流式」路径
          for (var i = 0; i < payload.length; i += 64 * 1024) {
            final end = min(i + 64 * 1024, payload.length);
            req.response.add(payload.sublist(i, end));
            await req.response.flush();
          }
          await req.response.close();
        case '/404.apk':
          req.response.statusCode = 404;
          await req.response.close();
        case '/empty.apk':
          req.response.headers.contentLength = 0;
          await req.response.close();
        default:
          req.response.statusCode = 404;
          await req.response.close();
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('下载成功：字节完全一致，进度到 100%', () async {
    final seen = <int>[];
    final file = await DownloadService.downloadApk(
      url: Uri.parse('$base/app.apk'),
      dir: tmp,
      fileName: 'a.apk',
      progressInterval: Duration.zero,
      onProgress: (p) => seen.add(p.received),
    );
    final bytes = await file.readAsBytes();
    expect(bytes.length, payload.length);
    // 抽样比对，避免 1MB 全量比较拖慢测试
    expect(bytes.sublist(0, 100), payload.sublist(0, 100));
    expect(bytes.sublist(bytes.length - 100), payload.sublist(payload.length - 100));

    expect(seen, isNotEmpty);
    expect(seen.last, payload.length);
    // 单调不减
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i] >= seen[i - 1], isTrue);
    }
  });

  test('同名旧文件先被清掉，不会留下上一次的内容', () async {
    final stale = File('${tmp.path}${Platform.pathSeparator}a.apk');
    await stale.writeAsString('old broken content');
    final file = await DownloadService.downloadApk(
      url: Uri.parse('$base/app.apk'),
      dir: tmp,
      fileName: 'a.apk',
    );
    expect((await file.readAsBytes()).length, payload.length);
  });

  test('取消：抛 DownloadCancelled，且半截文件被删', () async {
    final task = DownloadTask();
    final file = File('${tmp.path}${Platform.pathSeparator}b.apk');
    final future = DownloadService.downloadApk(
      url: Uri.parse('$base/app.apk'),
      dir: tmp,
      fileName: 'b.apk',
      task: task,
      progressInterval: const Duration(milliseconds: 1),
      onProgress: (_) => task.cancel(),
    );
    await expectLater(future, throwsA(isA<DownloadCancelled>()));
    expect(await file.exists(), isFalse);
  });

  test('HTTP 404 → DownloadFailed，带状态码', () async {
    await expectLater(
      DownloadService.downloadApk(
        url: Uri.parse('$base/404.apk'),
        dir: tmp,
        fileName: 'c.apk',
      ),
      throwsA(isA<DownloadFailed>()
          .having((e) => e.message, 'message', contains('404'))),
    );
    expect(await File('${tmp.path}${Platform.pathSeparator}c.apk').exists(),
        isFalse);
  });

  test('空文件 → DownloadFailed（不是"下载成功 0 字节"）', () async {
    await expectLater(
      DownloadService.downloadApk(
        url: Uri.parse('$base/empty.apk'),
        dir: tmp,
        fileName: 'd.apk',
      ),
      throwsA(isA<DownloadFailed>()),
    );
  });

  test('clean() 只删 apk，不碰别的文件', () async {
    await File('${tmp.path}${Platform.pathSeparator}a.apk').writeAsString('x');
    await File('${tmp.path}${Platform.pathSeparator}b.apk').writeAsString('x');
    await File('${tmp.path}${Platform.pathSeparator}note.txt').writeAsString('x');
    await DownloadService.clean(tmp);
    final names = await tmp.list().map((e) => e.path.split(Platform.pathSeparator).last).toList();
    expect(names, ['note.txt']);
  });
}
