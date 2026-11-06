import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/rules.dart';

/// 「保存时写什么时分」的公共口径。
///
/// 2026-11-07 用户发现：手动记的账有 00:04，同一分钟语音记的三笔却是 --:--。
/// 根因是这份规则原本是 editor_page.dart 的库私有函数，语音页没接上。
/// 现在手动 / 语音都走 saveTimeMinutes，这里把边界钉住。
void main() {
  test('今天的账写当前时分，补记历史日期不编时间', () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    expect(saveTimeMinutes(today), now.hour * 60 + now.minute);
    // 传带时分的 DateTime 也只按「年月日」判定，不该被时分影响。
    expect(saveTimeMinutes(now), now.hour * 60 + now.minute);

    expect(saveTimeMinutes(today.subtract(const Duration(days: 1))), isNull,
        reason: '昨天无从得知具体几点');
    expect(saveTimeMinutes(DateTime(now.year - 1, now.month, now.day)), isNull);
    expect(saveTimeMinutes(today.add(const Duration(days: 1))), isNull,
        reason: '未来日期也不编时间');
  });
}
