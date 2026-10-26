import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/lunar.dart';

void main() {
  test('二十四节气按公历日期返回', () {
    expect(solarTermName(DateTime(2026, 2, 4)), '立春');
    expect(solarTermName(DateTime(2026, 4, 5)), '清明');
    expect(solarTermName(DateTime(2026, 10, 8)), '寒露');
  });

  test('农历节日优先显示', () {
    expect(calendarLabel(DateTime(2026, 2, 16)), '除夕');
    expect(calendarLabel(DateTime(2026, 2, 17)), '春节');
  });

  test('公历节日正常显示', () {
    expect(calendarLabel(DateTime(2026, 10, 1)), '国庆节');
    expect(calendarLabel(DateTime(2026, 1, 1)), '元旦');
  });
}
