import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/common.dart';

/// 2026-10-28：全 App 的短提示统一走 `ScaffoldMessengerState.toast()`。
///
/// 改之前 47 处弹提示只有 8 处会先收掉上一条，剩下的都靠 ScaffoldMessenger
/// **排队**：连点两次保存，第一条要播满 4 秒才轮到第二条，用户会觉得"卡住了"。
/// 这条测试钉两件事：不排队、2 秒自己走。
void main() {
  testWidgets('连续两条 toast 只留最后一条（不排队）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () {
              ScaffoldMessenger.of(ctx).toast('第一条');
              ScaffoldMessenger.of(ctx).toast('第二条');
            },
            child: const Text('go'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('第二条'), findsOneWidget);
    expect(find.text('第一条'), findsNothing,
        reason: '第一条要立刻被收掉，而不是排队等它播完');
  });

  testWidgets('toast 2 秒后自己消失（不是默认的 4 秒）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => ScaffoldMessenger.of(ctx).toast('已保存'),
            child: const Text('go'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('已保存'), findsOneWidget);

    // 2 秒 + 进出场动画 ≈ 2.6 秒。断言 3.2 秒时已经消失 —— 如果还是默认的
    // 4 秒，这个时刻它必然还挂在屏幕上。
    // ⚠️ 必须小步 pump：一次跳 3 秒的话动画没有中间帧，widget 会一直留在树上。
    var elapsed = 400;
    while (elapsed < 3200 && find.text('已保存').evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 100));
      elapsed += 100;
    }
    expect(find.text('已保存'), findsNothing,
        reason: '2 秒的提示不该活过 3.2 秒（默认 4 秒的话这里还在）');
  });
}
