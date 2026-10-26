import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/version.dart';
import 'package:jianji/ui/about_page.dart';

void main() {
  test('界面版本常量与 pubspec 保持一致', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(r'^version:\s*([0-9.]+)\+([0-9]+)$', multiLine: true)
        .firstMatch(pubspec);
    expect(match, isNotNull);
    expect(match!.group(1), appVersion);
    expect(int.parse(match.group(2)!), appBuild);
  });

  testWidgets('关于页只讲简记自己（2026-10-25 用户要求：删掉上游/许可相关行）',
      (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: AboutPage()),
    ));

    expect(find.text('版本 $appVersion（$appBuild）'), findsOneWidget);
    // 用户明确要求删掉这些，写个反向断言钉住，免得以后又被加回来
    expect(find.text('BeeCount 软件许可'), findsNothing);
    expect(find.text('第三方组件声明'), findsNothing);
    expect(find.text('第三方开源许可'), findsNothing);
    expect(find.text('上游项目'), findsNothing);
    expect(find.textContaining('github.com/TNT-Likely/BeeCount'), findsNothing);
    expect(find.textContaining('基于 BeeCount'), findsNothing);
  });
}
