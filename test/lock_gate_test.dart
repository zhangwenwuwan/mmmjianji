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
  });
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
