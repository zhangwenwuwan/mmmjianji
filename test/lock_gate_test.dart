import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jianji/state/settings.dart';
import 'package:jianji/ui/lock_gate.dart';

/// 应用锁回归测试。
///
/// 这批修复的 bug 是「冷启动时锁不上」：`LockGate` 原来在 `initState` 的 postFrame
/// 回调里读一次 `settingsProvider.lockEnabled`，而那一瞬间 `SettingsNotifier.build()`
/// 返回的还是 `const AppSettings()`（默认 false）——真正的偏好要等 platform channel
/// 回来才写回。所以开了锁也永远读不到，杀进程重开一次 PIN 都不用输。
///
/// 这个 bug 手工测很难发现（只有「切后台 >30 秒回来」那条路径真的会锁），
/// 所以必须用测试钉住。
void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 「解锁后 3 秒不回锁」那条守卫是为系统生物识别弹窗准备的；测试里
    // 没有弹窗，把它关掉才能验证「切走就上锁」。
    lockUnlockGuard = Duration.zero;
  });

  tearDown(() {
    lockUnlockGuard = const Duration(seconds: 3);
  });

  Future<AppSettings> pumpGate(WidgetTester tester, {required bool locked}) async {
    late AppSettings observed;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              observed = ref.watch(settingsProvider);
              return LockGate(
                child: const Material(child: Center(child: Text('CHILD'))),
              );
            },
          ),
        ),
      ),
    );
    return observed;
  }

  group('应用锁', () {
    testWidgets('开了锁：hydration 完成后必须显示 PIN 界面，不能放行', (tester) async {
      SharedPreferences.setMockInitialValues({
        'lock_enabled': true,
        'pin_hash': _hash('salt', '1234'),
        'pin_salt': 'salt',
      });

      await pumpGate(tester, locked: true);

      // 首帧：还没读到偏好。这里**绝不能**放行到子内容。
      expect(find.text('CHILD'), findsNothing,
          reason: '偏好没读完就放行 = 冷启动不用输 PIN');

      await tester.pumpAndSettle();

      expect(find.text('简记已锁定'), findsOneWidget);
      expect(find.text('CHILD'), findsNothing);
    });

    testWidgets('没开锁：正常放行', (tester) async {
      await pumpGate(tester, locked: false);
      await tester.pumpAndSettle();
      expect(find.text('CHILD'), findsOneWidget);
      expect(find.text('简记已锁定'), findsNothing);
    });

    testWidgets('PIN 正确才解锁，错误给提示且不放行', (tester) async {
      SharedPreferences.setMockInitialValues({
        'lock_enabled': true,
        'pin_hash': _hash('salt', '1234'),
        'pin_salt': 'salt',
      });
      await pumpGate(tester, locked: true);
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '9999');
      await tester.tap(find.text('解锁'));
      await tester.pumpAndSettle();
      expect(find.text('PIN 不正确'), findsOneWidget);
      expect(find.text('CHILD'), findsNothing,
          reason: '输错 PIN 不能把内容放出来');

      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('解锁'));
      await tester.pumpAndSettle();
      expect(find.text('CHILD'), findsOneWidget);
    });

    testWidgets('解锁后再重建不会重新上锁（本次会话保持解锁）', (tester) async {
      SharedPreferences.setMockInitialValues({
        'lock_enabled': true,
        'pin_hash': _hash('salt', '1234'),
        'pin_salt': 'salt',
      });
      await pumpGate(tester, locked: true);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1234');
      await tester.tap(find.text('解锁'));
      await tester.pumpAndSettle();
      expect(find.text('CHILD'), findsOneWidget);

      // 触发一次重建（例如主题/字号变化）
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) => LockGate(
                child: const Material(child: Center(child: Text('CHILD'))),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('CHILD'), findsOneWidget,
          reason: '已解锁的会话不该因为重建又被锁上');
    });
    testWidgets('每次切回都上锁（grace=0）：切走就锁，回前台不用再等', (tester) async {
      SharedPreferences.setMockInitialValues({
        'lock_enabled': true,
        'pin_hash': _hash('salt', '1234'),
        'pin_salt': 'salt',
        'lock_grace_seconds': 0,
      });
      await pumpGate(tester, locked: true);
      await tester.pumpAndSettle();
      await _unlockWith(tester, '1234');
      expect(find.text('CHILD'), findsOneWidget);

      // 切到后台：应当**当场**锁上。
      // 原来要等 resumed 才 setState，用户回到前台会先看到一帧真实账目，
      // 表现就是「延迟上锁 / 锁界面慢半拍」。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(find.text('简记已锁定'), findsOneWidget,
          reason: '离开时就要锁，不能等回到前台');

      // 回来：hidden → inactive → resumed（Framework 要求的合法顺序）
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('简记已锁定'), findsOneWidget);
      expect(find.text('CHILD'), findsNothing);
    });

    testWidgets('只发 inactive → resumed（手势导航/通知栏）也会上锁', (tester) async {
      SharedPreferences.setMockInitialValues({
        'lock_enabled': true,
        'pin_hash': _hash('salt', '1234'),
        'pin_salt': 'salt',
        'lock_grace_seconds': 0,
      });
      await pumpGate(tester, locked: true);
      await tester.pumpAndSettle();
      await _unlockWith(tester, '1234');

      // 某些系统路径不会发 paused，只发 inactive。
      // 只认 paused 的老逻辑会漏锁 —— 这就是"有时候就是不上锁"。
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('简记已锁定'), findsOneWidget);
      expect(find.text('CHILD'), findsNothing);
    });

    testWidgets('宽限期 30 秒：马上回来不锁', (tester) async {
      SharedPreferences.setMockInitialValues({
        'lock_enabled': true,
        'pin_hash': _hash('salt', '1234'),
        'pin_salt': 'salt',
        'lock_grace_seconds': 30,
      });
      await pumpGate(tester, locked: true);
      await tester.pumpAndSettle();
      await _unlockWith(tester, '1234');

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(find.text('CHILD'), findsOneWidget,
          reason: '宽限期内的短暂切换不该回锁');
    });
  });

  testWidgets('锁屏要盖住 push 出来的页面，不能只盖首页', (tester) async {
    // 2026-11-06 真机 bug：LockGate 原来挂在首页路由里，
    // 设置/记账页这些 push 出来的页面永远在它上面 ——
    // 切后台回来时锁是"锁上了"，但用户看到的还是原来那页。
    SharedPreferences.setMockInitialValues({
      'lock_enabled': true,
      'pin_hash': _hash('salt', '1234'),
      'pin_salt': 'salt',
      'lock_grace_seconds': 0,
    });

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          // 和 main.dart 一样挂在 builder（Navigator 之上）
          builder: (context, child) =>
              LockGate(child: child ?? const SizedBox.shrink()),
          home: Material(
            child: Builder(
              builder: (ctx) => Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                    builder: (_) => const Material(child: Text('PUSHED')),
                  )),
                  child: const Text('GO'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _unlockWith(tester, '1234');
    expect(find.text('GO'), findsOneWidget);

    await tester.tap(find.text('GO'));
    await tester.pumpAndSettle();
    expect(find.text('PUSHED'), findsOneWidget);

    // 切后台：页面还在栈顶，锁必须出现在它上面
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(find.text('简记已锁定'), findsOneWidget,
        reason: '锁屏必须盖住 push 出来的页面');
    expect(find.text('PUSHED'), findsNothing,
        reason: '锁定时底下那页不该被看到');

    // 回来仍然是锁屏；解锁后回到原来那一页（页面栈没被清掉）
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('简记已锁定'), findsOneWidget);

    await _unlockWith(tester, '1234');
    expect(find.text('PUSHED'), findsOneWidget,
        reason: '解锁要回到原来那一页，不能重置到首页');
  });
}

/// 输 PIN 解锁（4 位会自动提交，这里仍点一次"解锁"兜住老数据）。
Future<void> _unlockWith(WidgetTester tester, String pin) async {
  await tester.enterText(find.byType(TextField), pin);
  await tester.pump();
  if (find.text('解锁').evaluate().isNotEmpty) {
    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();
  }
}

/// 与 `SettingsNotifier.hashPin` 相同的 FNV-1a 64 位实现（复制过来只为构造测试数据）。
String _hash(String salt, String pin) {
  const offset = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  var hash = offset;
  for (final code in '$salt|$pin'.codeUnits) {
    hash ^= code;
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16);
}
