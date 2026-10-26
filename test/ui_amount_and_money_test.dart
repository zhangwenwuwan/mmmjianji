import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/ui/amount_input.dart';
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

    test('整数部分最多 7 位', () {
      expect(apply('1234567', '12345678').text, '1234567');
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
}
