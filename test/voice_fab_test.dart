import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/state/settings.dart';
import 'package:jianji/ui/voice_fab.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 语音悬浮按钮的**位置**：默认右下角，长按拖动后落位并记住。
///
/// 交互定稿（2026-11-07）：点一下开始识别、再点一下立刻结束；
/// **长按**才进拖动。所以这里钉的是「长按 500ms 之后才开始跟手」，
/// 以及「松手把归一化坐标写进偏好、下次进来还在原地」。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget host(ProviderContainer container) => UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(
            body: Stack(children: [Positioned.fill(child: VoiceFabLayer())]),
          ),
        ),
      );

  testWidgets('长按拖动改变位置，松手后位置落进偏好', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(host(container));
    // 冷启动的浮入动画
    await tester.pump(const Duration(milliseconds: 600));

    final fab = find.byKey(const ValueKey('voice-entry-fab'));
    expect(fab, findsOneWidget);
    final before = tester.getTopLeft(fab);

    // 默认在右下角（右边 14、底栏上方）
    expect(before.dx, greaterThan(600), reason: '默认应贴在右侧');
    expect(before.dy, greaterThan(400), reason: '默认应贴在下边');

    final gesture = await tester.startGesture(tester.getCenter(fab));
    // 超过长按判定阈值（500ms）才开始拖
    await tester.pump(const Duration(milliseconds: 700));
    await gesture.moveBy(const Offset(-260, -300));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));

    final after = tester.getTopLeft(fab);
    expect(after.dx, lessThan(before.dx - 150), reason: '应该跟着手指往左走');
    expect(after.dy, lessThan(before.dy - 150), reason: '应该跟着手指往上走');

    // 落盘：状态是同步更新的，回调里已经写了
    final settings = container.read(settingsProvider);
    expect(settings.voiceFabMoved, isTrue, reason: '松手要记住新位置');
    expect(settings.voiceFabDx, lessThan(0.9), reason: '归一化横坐标应随拖动变小');
    expect(settings.voiceFabDy, lessThan(0.9), reason: '归一化纵坐标应随拖动变小');

    // 真实把偏好写完，别给测试收尾留一个悬着的 Future。
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
  });

  testWidgets('按钮不会被拖出屏幕、也不会压住底栏', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(host(container));
    await tester.pump(const Duration(milliseconds: 600));

    final fab = find.byKey(const ValueKey('voice-entry-fab'));
    final gesture = await tester.startGesture(tester.getCenter(fab));
    await tester.pump(const Duration(milliseconds: 700));
    // 往右下角使劲甩，超出边界
    await gesture.moveBy(const Offset(900, 900));
    await tester.pump();
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 300));

    final box = tester.getRect(fab);
    final screen = tester.getRect(find.byType(Scaffold));
    expect(box.right, lessThanOrEqualTo(screen.right),
        reason: '右边缘不能出屏');
    expect(box.bottom, lessThanOrEqualTo(screen.bottom - 70),
        reason: '下边缘要留在悬浮底栏上方');

    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
  });
}
