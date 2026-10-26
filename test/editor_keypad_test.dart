import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/editor_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 记账页键盘 + 一屏流程：这是用户每笔记账都要走的路，必须钉住。
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('一屏流程：金额常驻、点分类只选中不弹层、键盘累加/小数点/退格',
      (tester) async {
    // 不用 databasePathProvider 覆盖：覆盖会在 widget 测试里把 provider 图卡住
    // （实测过，别问为什么，用默认库就能跑）。
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: EntryEditorPage()),
    ));

    // 分类是数据库读出来的，且首帧后要经 postFrame 自动选中第一个一级分类，
    // 金额面板才会出现。
    // ⚠️ 必须用 runAsync：tester.pump(时长) 只推进**假时钟**，
    // 推不动真实的文件/数据库 IO（冒烟测试里踩过同一个坑）。
    Future<void> waitForPanel() async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 60));
        if (find.byKey(const Key('amount-display')).evaluate().isNotEmpty) return;
      }
      fail('一屏金额面板没有出现（分类没读出来？）');
    }

    await waitForPanel();

    String amount() =>
        (tester.widget(find.byKey(const Key('amount-display'))) as Text).data!;

    // 面板常驻：不需要先点分类、也不需要等弹层升起
    expect(amount(), '0.00');
    // 保存/再记一笔/清空都在面板里
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('再记一笔'), findsOneWidget);
    expect(find.text('清空'), findsOneWidget);

    // 新键盘是计算器式：运算符在右列，没有 = 键
    expect(find.byKey(const Key('key-eq')), findsNothing);
    expect(find.byKey(const Key('key-+')), findsOneWidget);
    expect(find.byKey(const Key('key-÷')), findsOneWidget);

    Future<void> press(String k) async {
      await tester.tap(find.byKey(Key('key-$k')));
      await tester.pump();
    }

    await press('1');
    expect(amount(), '1');

    await press('2');
    expect(amount(), '12');

    await press('.');
    await press('5');
    expect(amount(), '12.5');

    // 第二个小数点被拒
    await press('.');
    expect(amount(), '12.5');

    // 退格
    await press('del');
    expect(amount(), '12.');

    // 面板上的「清空」按钮（旧键盘上的 clear 键已并入这个按钮）
    await tester.tap(find.text('清空'));
    await tester.pump();
    expect(amount(), '0.00');

    // 分类网格和记账面板同屏共存（一屏流程的直观证据）
    expect(find.byType(GridView), findsWidgets);
    expect(find.byKey(const Key('amount-display')), findsOneWidget);
  });

  testWidgets('计算器键盘：表达式实时求值，不需要 = 键', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: EntryEditorPage()),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      if (find.byKey(const Key('amount-display')).evaluate().isNotEmpty) break;
    }

    String amount() =>
        (tester.widget(find.byKey(const Key('amount-display'))) as Text).data!;

    Future<void> press(String k) async {
      await tester.tap(find.byKey(Key('key-$k')));
      await tester.pump();
    }

    // 12 + 5 × 2 = 34
    await press('1');
    await press('2');
    expect(amount(), '12');
    await press('+');
    // 一按运算符，上方出现「12 + …」的过程行，金额区实时显示当前累加结果
    // （这就是「实时求值」，所以键盘上不需要 = 键）
    // 注意 centsToText 对整额不带 .00，所以这里是 '12' 而不是 '12.00'
    expect(amount(), '12');
    expect(find.text('…'), findsOneWidget);
    await press('5');
    expect(amount(), '17');
    await press('×');
    expect(amount(), '17');
    await press('2');
    // 3400 分 = 34 元。⚠️ 这里千万别写成 '3,400'：
    // 早期版本把「分 × 分」直接相乘，1700×200=340000 分，屏幕上就是 3,400 元（放大 100 倍）。
    expect(amount(), '34');

    // 除零不崩：按 ÷ 再按 0，结果保持累加值
    await press('÷');
    expect(amount(), '34');
    await press('0');
    expect(amount(), '34');
  });

  testWidgets('回归：17 × 2 必须是 34 元，不是 3400 元', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: EntryEditorPage()),
    ));
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 60));
      if (find.byKey(const Key('amount-display')).evaluate().isNotEmpty) break;
    }

    String amount() =>
        (tester.widget(find.byKey(const Key('amount-display'))) as Text).data!;

    Future<void> press(String k) async {
      await tester.tap(find.byKey(Key('key-$k')));
      await tester.pump();
    }

    await press('1');
    await press('7');
    await press('×');
    await press('2');
    expect(amount(), '34');
  });
}
