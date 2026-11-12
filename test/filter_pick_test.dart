import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/ui/search_page.dart';

/// 搜索页筛选弹层的「取消」语义回归。
///
/// 旧代码里「点外面取消」和「点不限」都返回 null，于是取消弹层会把
/// 已经选好的筛选条件悄悄清空，而注释还写着「不做改动」。

Bucket _bucket(int id) => Bucket(
      id: id,
      bookId: 1,
      flow: 'out',
      title: '食物',
      glyph: '🍚',
      archived: false,
    );

void main() {
  test('取消（null）→ 不改变筛选', () {
    final d = decodeFilterPick<int>(null);
    expect(d.changed, isFalse);
    expect(d.value, isNull);
  });

  test('点「不限」→ 改成清空', () {
    final d = decodeFilterPick<int>(filterAll);
    expect(d.changed, isTrue);
    expect(d.value, isNull);
  });

  test('选中具体值 → 改成该值', () {
    final d = decodeFilterPick<int>(2);
    expect(d.changed, isTrue);
    expect(d.value, 2);
  });

  test('分类弹层同样区分取消 / 不限 / 选中', () {
    final b = _bucket(7);
    expect(decodeFilterPick<Bucket>(null).changed, isFalse);
    expect(decodeFilterPick<Bucket>(filterAll).value, isNull);
    expect(decodeFilterPick<Bucket>(b).value?.id, 7);
  });
}
