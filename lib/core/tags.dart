/// 标签文本处理（纯函数，不碰数据库/UI）。
///
/// App 里标签一直是一列逗号分隔的字符串（`聚餐,报销`），新增固定标签只是
/// 「多一个可点的候选」，落库格式不变 —— 不动任何统计口径，也不加新表。
library;

/// 拆分 + 去空 + 去重，保留用户录入顺序。
List<String> parseTags(String raw) {
  final out = <String>[];
  for (final part in raw.split(RegExp(r'[,，]'))) {
    final t = part.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }
  return out;
}

/// 点一下标签：已在列表里就去掉，否则加到最后。
String toggleTag(String raw, String tag) {
  final t = tag.trim();
  if (t.isEmpty) return raw;
  final list = parseTags(raw);
  if (list.contains(t)) {
    list.remove(t);
  } else {
    list.add(t);
  }
  return list.join(',');
}

/// 固定标签候选：固定标签 + 历史标签，去重、固定标签优先。
List<String> mergeTagCandidates(
  Iterable<String> fixed,
  Iterable<String> history,
) {
  final out = <String>[];
  for (final t in fixed) {
    final v = t.trim();
    if (v.isNotEmpty && !out.contains(v)) out.add(v);
  }
  for (final t in history) {
    final v = t.trim();
    if (v.isNotEmpty && !out.contains(v)) out.add(v);
  }
  return out;
}
