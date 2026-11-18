/// 分类拖拽的纯逻辑：把某一项移动到新位置。
///
/// 只为单测存在（见 test/bucket_order_test.dart）。不放在页面里是因为
/// widget 测试驱动真实拖拽时，ReorderableListView 的自动滚动 + 假时钟会挂住，
/// 而「移动后顺序对不对」恰恰是最容易写错的一步：
/// `newIndex` 到底是「移除前」还是「移除后」的位置，差一格就是拖不动。
library;

/// 把 [ids] 里第 [oldIndex] 项移到 [newIndex]。
///
/// [newIndex] 按**移除之后**的位置给（`onReorderItem` 就是这个语义，
/// 老的 `onReorder` 需要自己 `if (newIndex > oldIndex) newIndex--`）。
/// 越界一律夹到合法范围，拖到列表头尾之外不会抛异常。
List<int> moveId(List<int> ids, int oldIndex, int newIndex) {
  if (oldIndex < 0 || oldIndex >= ids.length) return ids;
  final out = [...ids];
  final moved = out.removeAt(oldIndex);
  final at = newIndex < 0 ? 0 : (newIndex > out.length ? out.length : newIndex);
  out.insert(at, moved);
  return out;
}
