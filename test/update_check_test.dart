import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/version.dart';
import 'package:jianji/services/update_service.dart';

/// 更新检查的**纯逻辑**测试：清单解析 + 版本比较 + 强制更新判定。
///
/// 不测网络：`UpdateService.check()` 走 HttpClient，而 flutter_test 默认把所有
/// HTTP 请求拦成 400，测出来的只是"框架行为"，不是我们的逻辑。
void main() {
  group('更新清单解析', () {
    test('正常清单：字段齐全', () {
      final info = parseUpdateManifest(jsonEncode({
        'versionName': '1.4.21',
        'versionCode': 65,
        'size': 29123456,
        'sha256': 'abc123',
        'minSupportedCode': 60,
        'notes': '1. 左滑删除\n2. 日期头吸顶',
        'apkUrl': 'https://example.com/jianji1.4.21-arm64.apk',
      }))!;
      expect(info.versionName, '1.4.21');
      expect(info.versionCode, 65);
      expect(info.sizeBytes, 29123456);
      expect(info.sha256, 'abc123');
      expect(info.minSupportedCode, 60);
      expect(info.notes, contains('左滑删除'));
      expect(info.apkUrl, endsWith('.apk'));
    });

    test('versionCode 写成浮点也能认（服务端 JSON 常见）', () {
      final info = parseUpdateManifest('{"versionName":"1.4.21","versionCode":65.0}')!;
      expect(info.versionCode, 65);
    });

    test('缺 versionCode / 名字为空 / 非 JSON / 顶层是数组 → 一律 null', () {
      expect(parseUpdateManifest('{"versionName":"1.4.21"}'), isNull);
      expect(parseUpdateManifest('{"versionName":"  ","versionCode":65}'), isNull);
      expect(parseUpdateManifest('not json'), isNull);
      expect(parseUpdateManifest('[1,2,3]'), isNull);
      expect(parseUpdateManifest('{"versionName":"1.4.21","versionCode":0}'), isNull);
    });

    test('可选字段缺失不影响解析', () {
      final info = parseUpdateManifest(
          '{"versionName":"1.5.0","versionCode":70}')!;
      expect(info.sizeBytes, isNull);
      expect(info.notes, '');
      expect(info.apkUrl, '');
      expect(info.minSupportedCode, isNull);
    });
  });

  group('版本比较（用 versionCode，不碰字符串）', () {
    UpdateInfo info(int code) =>
        UpdateInfo(versionName: 'x', versionCode: code);

    test('versionCode 比本地大才算新版本', () {
      expect(info(appBuild + 1).isNewer, isTrue);
      expect(info(appBuild).isNewer, isFalse);
      expect(info(appBuild - 1).isNewer, isFalse);
    });

    test('1.4.10 与 1.4.9：按 code 比不会判错（字符串比会）', () {
      // 字符串比较里 '1.4.10' < '1.4.9' 是 true —— 这就是必须用 code 的原因
      expect('1.4.10'.compareTo('1.4.9') < 0, isTrue);
      // ⚠️ 这里必须相对 appBuild 写，不能写死数字：升版一次测试就红一次
      final newer = UpdateInfo(versionName: '1.4.10', versionCode: appBuild + 1);
      final older = UpdateInfo(versionName: '1.4.9', versionCode: appBuild - 15);
      expect(newer.isNewer, isTrue);
      expect(older.isNewer, isFalse);
    });

    test('minSupportedCode 高于本地 = 强制更新', () {
      final forced = UpdateInfo(
          versionName: '2.0.0', versionCode: 90, minSupportedCode: appBuild + 1);
      expect(forced.forced, isTrue);
      final soft = UpdateInfo(
          versionName: '2.0.0', versionCode: 90, minSupportedCode: appBuild);
      expect(soft.forced, isFalse);
      final none = UpdateInfo(versionName: '2.0.0', versionCode: 90);
      expect(none.forced, isFalse);
    });
  });

  group('文件大小文案', () {
    test('MB / KB / 空值', () {
      expect(UpdateService.sizeLabel(29 * 1024 * 1024), '29.0 MB');
      expect(UpdateService.sizeLabel(512 * 1024), '512 KB');
      expect(UpdateService.sizeLabel(null), '');
      expect(UpdateService.sizeLabel(0), '');
    });
  });
}
