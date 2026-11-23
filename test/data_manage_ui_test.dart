import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/data_manage_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据管理页精简后的界面契约（2026-11-23）：
/// 「备份与导入」分组只有三项 —— 导出 / 导入 / 微信支付宝账单导入。
/// 明文剪贴板、CSV、配置、日志中心、存储管理、清空 这些入口都不该再出现。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'onboarded_v1': true});
    final dir = await databaseFactory.getDatabasesPath();
    try {
      await databaseFactory.deleteDatabase('$dir/jianji_ledger.db');
    } catch (_) {}
  });

  testWidgets('导入导出分组只剩三项，旧的明文入口都消失', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: DataManagePage()),
    ));
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 60));
    }

    // 新界面：确实存在
    expect(find.text('备份与导入'), findsOneWidget);
    expect(find.text('导出备份'), findsWidgets);
    expect(find.text('导入备份'), findsOneWidget);
    expect(find.text('微信 / 支付宝账单导入'), findsOneWidget);
    expect(find.textContaining('加密'), findsWidgets);

    // 旧界面：都不该再出现
    for (final old in [
      '复制备份到剪贴板',
      '从剪贴板导入',
      '导出 CSV',
      '导出数据',
      '日志中心',
      '导出配置',
      '从剪贴板导入配置',
      '存储管理',
      '清空所有数据',
    ]) {
      expect(find.text(old), findsNothing, reason: '$old 不该还在界面上');
    }
  });
}
