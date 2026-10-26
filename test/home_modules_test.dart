import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/home_modules.dart';

/// 首页模块顺序的归一化。
///
/// 这块最容易出的不是"排序错了"，而是**新版加的模块对老用户永远不可见**——
/// 老存档里没有这个 id，如果只按存档渲染，新模块等于白加。
/// 所以 normalizeOrder 必须补全。
void main() {
  test('没存过顺序 → 默认顺序，且包含全部模块', () {
    final order = normalizeOrder('');
    expect(order, HomeModule.values);
    expect(order.length, HomeModule.values.length);
  });

  test('null 也当没存过', () {
    expect(normalizeOrder(null), HomeModule.values);
  });

  test('按存档顺序排，且尊重用户的自定义顺序', () {
    final order = normalizeOrder('lastMonth,hero,addEntry');
    expect(order.take(3).toList(), [
      HomeModule.lastMonth,
      HomeModule.hero,
      HomeModule.addEntry,
    ]);
    // 剩下的按枚举顺序补齐
    expect(order.length, HomeModule.values.length);
    expect(order.toSet(), HomeModule.values.toSet());
  });

  test('存档里缺的模块（新版本新增）补到末尾，不会消失', () {
    // 模拟老存档：只有前四个
    final legacy = HomeModule.values.take(4).map((m) => m.id).join(',');
    final order = normalizeOrder(legacy);
    expect(order.length, HomeModule.values.length);
    expect(order.last, HomeModule.values.last);
  });

  test('未知 id / 空段 / 重复 id 都被吃掉', () {
    final order = normalizeOrder('hero,,nonsense,hero,addEntry, hero ');
    expect(order.first, HomeModule.hero);
    expect(order.where((m) => m == HomeModule.hero).length, 1);
    expect(order.length, HomeModule.values.length);
  });

  group('隐藏集合', () {
    test('解析并忽略未知 id', () {
      final h = parseHidden('lastMonth,bogus,annualReport');
      expect(h, {HomeModule.lastMonth, HomeModule.annualReport});
    });

    test('「记一笔」写进隐藏也无效（它是唯一入口）', () {
      final h = parseHidden('addEntry');
      expect(h, isEmpty);
      expect(HomeModule.addEntry.canHide, isFalse);
    });
  });

  group('visibleModules', () {
    test('过滤隐藏项，保留顺序', () {
      final order = normalizeOrder('');
      final hidden = {HomeModule.lastMonth};
      final visible = visibleModules(order, hidden);
      expect(visible.contains(HomeModule.lastMonth), isFalse);
      expect(visible.first, HomeModule.hero);
    });

    test('即使隐藏集合里混进了 addEntry，也必须保留', () {
      final order = normalizeOrder('');
      // parseHidden 会挡一层，这里再直接喂一个脏集合
      final visible = visibleModules(order, {HomeModule.addEntry});
      expect(visible.contains(HomeModule.addEntry), isTrue);
    });
  });
}
