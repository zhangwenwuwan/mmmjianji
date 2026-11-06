import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/services/update_service.dart';
import 'package:jianji/ui/update_dialog.dart';

/// 钉住「发现新版后走浏览器」这条交互。
///
/// 2026-11-07 用户反馈应用内下载 + 调安装器经常装不上，改成把 APK 地址
/// 交给外部浏览器。这里不点按钮（点会触发平台通道），只核对弹窗里
/// 只剩浏览器入口、旧的应用内安装链路文案全都不在。
void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;

  const info = UpdateInfo(
    versionName: '1.4.54',
    versionCode: 98,
    sizeBytes: 30 * 1024 * 1024,
    notes: '修复语音记账',
    apkUrl: 'https://example.com/jianji1.4.54-arm64.apk',
  );

  Widget host() => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => unawaited(showUpdateDialog(ctx, info)),
                child: const Text('检查更新'),
              ),
            ),
          ),
        ),
      );

  testWidgets('发现新版只提供「用浏览器下载」，不再有应用内安装', (tester) async {
    await tester.pumpWidget(host());
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本 1.4.54'), findsOneWidget);
    expect(find.text('用浏览器下载'), findsOneWidget);
    expect(find.textContaining('浏览器下载安装包'), findsOneWidget);
    expect(find.textContaining('账目数据保留'), findsOneWidget);

    // 旧链路的按钮 / 权限引导 / 下载进度都不该再出现
    expect(find.text('下载并更新'), findsNothing);
    expect(find.text('立即更新'), findsNothing);
    expect(find.text('去设置'), findsNothing);
    expect(find.text('取消下载'), findsNothing);
    expect(find.textContaining('安装未知应用'), findsNothing);
  });

  testWidgets('强制更新仍不锁死弹窗，主按钮依旧是浏览器下载', (tester) async {
    const forced = UpdateInfo(
      versionName: '1.4.54',
      versionCode: 98,
      minSupportedCode: 98,
      apkUrl: 'https://example.com/jianji1.4.54-arm64.apk',
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => unawaited(showUpdateDialog(ctx, forced)),
              child: const Text('检查更新'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('用浏览器下载'), findsOneWidget);
    // 强制更新不给「稍后」，但也不许退化成应用内安装
    expect(find.text('稍后'), findsNothing);
    expect(find.text('下载并更新'), findsNothing);
  });
}
