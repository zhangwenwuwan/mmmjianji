import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/tags.dart';

/// 标签弹窗的纯逻辑：解析、点选切换、固定标签 + 历史的候选合并。
/// 落库格式仍是逗号分隔，零 schema 改动。

void main() {
  test('解析：中英文逗号都认，去空去重，保序', () {
    expect(parseTags(' 聚餐, 报销，，聚餐,出差 '), ['聚餐', '报销', '出差']);
    expect(parseTags(''), isEmpty);
    expect(parseTags(' , , '), isEmpty);
  });

  test('点选：不在就加，在就删', () {
    expect(toggleTag('聚餐,报销', '出差'), '聚餐,报销,出差');
    expect(toggleTag('聚餐,报销', '报销'), '聚餐');
    expect(toggleTag('聚餐', '聚餐'), '');
    expect(toggleTag('', '聚餐'), '聚餐');
  });

  test('空标签名不改原文', () {
    expect(toggleTag('聚餐', '  '), '聚餐');
  });

  test('固定标签优先，历史标签跟着补齐，不重复', () {
    expect(
      mergeTagCandidates(['出差', '聚餐'], ['聚餐', '报销', '出差', '宠物']),
      ['出差', '聚餐', '报销', '宠物'],
    );
  });

  test('两边都空就没有候选', () {
    expect(mergeTagCandidates(const [], const ['', ' ']), isEmpty);
  });
}
