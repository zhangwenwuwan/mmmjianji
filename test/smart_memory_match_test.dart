import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/services/smart_memory.dart';

/// 手动记账接上语音页的记忆表：只给候选、不自动改写草稿。
void main() {
  test('关键词短于 2 字不当关键词', () {
    expect(SmartMemory.keywordOf('  a '), '');
    expect(SmartMemory.keywordOf(' 星巴克 '), '星巴克');
  });

  test('备注命中关键词 → 返回对应 id', () {
    expect(
      SmartMemory.match('星巴克拿铁', const {'星巴克': 12, '地铁': 3}),
      12,
    );
  });

  test('多个关键词命中时取最长的那个', () {
    expect(
      SmartMemory.match('星巴克拿铁少冰',
          const {'星巴克': 12, '星巴克拿铁': 25, '冰': 9}),
      25,
    );
  });

  test('没命中返回 null，不猜默认值', () {
    expect(SmartMemory.match('随便记一笔', const {'星巴克': 12}), isNull);
    expect(SmartMemory.match('星巴克', const {}), isNull);
    expect(SmartMemory.match('a', const {'a': 1}), isNull);
  });

  test('一个字的关键词不会被当成候选', () {
    // 和 keywordOf 同一口径：短于 2 字到处都会误命中。
    expect(SmartMemory.match('x', const {'x': 0}), isNull);
  });
}
