import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/amount_input.dart';
import 'package:jianji/ui/amount_keypad.dart';
import 'package:jianji/ui/common.dart';

void main() {
  group('金额输入过滤', () {
    const formatter = AmountInputFormatter();

    TextEditingValue apply(String before, String after) => formatter
        .formatEditUpdate(TextEditingValue(text: before), TextEditingValue(text: after));

    test('允许合法输入', () {
      expect(apply('', '1').text, '1');
      expect(apply('1', '1.').text, '1.');
      expect(apply('1.', '1.2').text, '1.2');
      expect(apply('1.2', '1.23').text, '1.23');
      expect(apply('1.23', '1.234').text, '1.23'); // 第三位小数被拒
    });

    test('拒绝第二个小数点与非法字符', () {
      expect(apply('1.2', '1.2.').text, '1.2');
      expect(apply('1', '1a').text, '1');
      expect(apply('', '.').text, '.'); // 允许先打小数点，接着输 .5
    });

    test('整数部分最多 9 位（2026-11-18 由 7 位放开）', () {
      // 9 位能打进去：9.99 亿，记房贷 / 年收入 / 公司账够用
      expect(apply('12345678', '123456789').text, '123456789');
      expect(apply('999999999', '9999999999').text, '999999999'); // 第 10 位被拒
      // 老上限 7 位不能再生效
      expect(apply('1234567', '12345678').text, '12345678');
    });

    test('清空允许', () {
      expect(apply('1.23', '').text, '');
    });
  });

  group('MoneyText 符号', () {
    Future<void> pumpMoney(WidgetTester tester, int cents, {String? flow, bool hide = false}) async {
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MoneyText(cents, flow: flow),
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('无 flow 时负数必须带负号', (tester) async {
      await pumpMoney(tester, -5000);
      expect(find.text('-¥50'), findsOneWidget, reason: '结余/余额为负时不能显示成正数');
    });

    testWidgets('正数不带符号', (tester) async {
      await pumpMoney(tester, 5000);
      expect(find.text('¥50'), findsOneWidget);
    });

    testWidgets('支出/收入符号由 flow 决定', (tester) async {
      await pumpMoney(tester, 1234, flow: 'out');
      expect(find.text('-¥12.34'), findsOneWidget);
      await pumpMoney(tester, 1234, flow: 'in');
      expect(find.text('+¥12.34'), findsOneWidget);
    });
  });

  // 键盘控制器是第一道关：它会**静默忽略**超限按键，用户看到的是「按了没反应」。
  // 上限放到 9 位后要确认到底放开了多少，别只是改了正则的另一处。
  group('金额键盘位数上限', () {
    AmountKeypadController type(String s) {
      final c = AmountKeypadController();
      for (final ch in s.split('')) {
        c.press(ch);
      }
      return c;
    }

    test('9 位整数可输入，第 10 位被拒', () {
      final c = type('123456789');
      expect(c.cents, 123456789 * 100);
      c.press('9');
      expect(c.cents, 123456789 * 100, reason: '第 10 位应该打不进去');
    });

    test('9 位 + 两位小数', () {
      expect(type('999999999.99').cents, 99999999999);
    });

    test('老版本 7 位上限已失效', () {
      expect(type('12345678').cents, 12345678 * 100);
    });
  });
}
