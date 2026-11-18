import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/bucket_order.dart';

/// 拖拽落点换算：`onReorderItem` 的 newIndex 是**移除之后**的位置。
///
/// 这里差一格就是「拖动没反应 / 多跳一格」，而且只在手感上能察觉，
/// 用纯函数钉住比在真机上反复拖快得多。
void main() {
  test('往下拖：新位置直接就是插入点', () {
    // [A,B,C] 把 A 拖到 index 2（B、C 之后）
    expect(moveId([1, 2, 3], 0, 2), [2, 3, 1]);
  });

  test('往上拖：插到目标位置之前', () {
    // [A,B,C] 把 C 拖到 index 0
    expect(moveId([1, 2, 3], 2, 0), [3, 1, 2]);
  });

  test('相邻交换', () {
    expect(moveId([1, 2, 3], 1, 0), [2, 1, 3]);
    expect(moveId([1, 2, 3], 0, 1), [2, 1, 3]);
  });

  test('拖到末尾（newIndex == length）', () {
    expect(moveId([1, 2, 3], 0, 3), [2, 3, 1]);
  });

  test('越界不抛异常，夹到合法范围', () {
    expect(moveId([1, 2, 3], 0, 99), [2, 3, 1]);
    expect(moveId([1, 2, 3], 2, -5), [3, 1, 2]);
    expect(moveId([1, 2, 3], 5, 0), [1, 2, 3], reason: '非法来源原样返回');
  });

  test('单项列表和空列表不出错', () {
    expect(moveId([7], 0, 1), [7]);
    expect(moveId([], 0, 0), isEmpty);
  });

  test('不改原列表（页面还要用它算落库顺序）', () {
    final src = [1, 2, 3];
    final out = moveId(src, 0, 2);
    expect(src, [1, 2, 3]);
    expect(out, [2, 3, 1]);
  });
}
