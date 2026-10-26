/// 账单 CSV 解析（微信 / 支付宝 / 简记自身导出）。
///
/// 纯函数，不碰数据库、不碰文件：输入一段 CSV 文本，输出可导入的流水。
/// 单独抽出来是为了能穷举测试——导入错一笔比少导一笔更麻烦。
library;

import 'rules.dart';

class BillRow {
  const BillRow({
    required this.day,
    required this.cents,
    required this.flow,
    this.category = '',
    this.counterparty = '',
    this.memo = '',
    this.method = '',
    this.tags = '',
    this.reimburse = 0,
  });

  final DateTime day;
  final int cents;

  /// 'in' / 'out'（转账行会被过滤掉：账单里没有转账语义）
  final String flow;
  final String category;
  final String counterparty;
  final String memo;
  final String method;
  final String tags;
  final int reimburse;
}

class BillParseResult {
  const BillParseResult({
    required this.rows,
    required this.skipped,
    required this.warnings,
    this.source = 'unknown',
  });

  final List<BillRow> rows;

  /// 被跳过的行数（表头、不计收支、解析失败）
  final int skipped;
  final List<String> warnings;
  final String source;

  int get totalIn =>
      rows.where((r) => r.flow == 'in').fold(0, (s, r) => s + r.cents);
  int get totalOut =>
      rows.where((r) => r.flow == 'out').fold(0, (s, r) => s + r.cents);
}

/// 拆 CSV 行，支持双引号包裹与转义引号
List<String> splitCsvLine(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(ch);
      }
    } else {
      if (ch == '"') {
        inQuotes = true;
      } else if (ch == ',') {
        out.add(buf.toString().trim());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
  }
  out.add(buf.toString().trim());
  return out;
}

int? _parseAmount(String raw) {
  var t = raw
      .replaceAll('¥', '')
      .replaceAll('￥', '')
      .replaceAll('元', '')
      .replaceAll('"', '')
      .replaceAll(',', '')
      .trim();
  if (t.isEmpty) return null;
  // ⚠️ 别用 double 乘 100：
  //   8.615 * 100 = 861.4999… → round 成 861（应为 862）
  //   1.005 * 100 = 100.4999… → 100（应为 101）
  // 全 app 其它地方都走整数拆小数点的 parseAmountToCents，只有这里绕过去了。
  final cents = parseAmountToCents(t);
  if (cents == null) return null;
  // 账单金额都是正数；方向由「收/支」列决定
  return cents.abs();
}

DateTime? _parseDate(String raw) {
  var t = raw.trim().replaceAll('"', '');
  if (t.isEmpty) return null;
  t = t.replaceAll('/', '-');
  // 只取日期部分，时间丢弃
  final datePart = t.split(RegExp(r'[ T]')).first;
  final p = datePart.split('-');
  if (p.length < 3) return null;
  final y = int.tryParse(p[0]);
  final m = int.tryParse(p[1]);
  final d = int.tryParse(p[2]);
  if (y == null || m == null || d == null) return null;
  if (m < 1 || m > 12 || d < 1) return null;
  // 还要挡住 2 月 31 日这种：DateTime(2026, 2, 31) 会**静默滚到 3 月 3 日**，
  // 那笔账就被记到下个月的统计里，而用户在界面上完全看不出来。
  if (d > DateTime(y, m + 1, 0).day) return null;
  return DateTime(y, m, d);
}

/// 找表头：返回列名 → 下标
Map<String, int> _mapHeader(List<String> cells) {
  final map = <String, int>{};
  for (var i = 0; i < cells.length; i++) {
    final c = cells[i].replaceAll('"', '').trim();
    if (c.isEmpty) continue;
    if (c.contains('交易时间') || c == '日期' || c == '时间') {
      map.putIfAbsent('date', () => i);
    } else if (c.contains('金额')) {
      map.putIfAbsent('amount', () => i);
    } else if (c.contains('收/支') || c.contains('收支类型') || c == '类型') {
      map.putIfAbsent('flow', () => i);
    } else if (c.contains('交易分类') || c.contains('分类')) {
      map.putIfAbsent('category', () => i);
    } else if (c.contains('交易对方') || c.contains('对方')) {
      map.putIfAbsent('counterparty', () => i);
    } else if (c.contains('商品说明') || c.contains('商品') || c == '备注') {
      map.putIfAbsent('memo', () => i);
    } else if (c.contains('支付方式') ||
        c.contains('收/付款方式') ||
        c.contains('付款方式')) {
      map.putIfAbsent('method', () => i);
    } else if (c == '标签') {
      map.putIfAbsent('tags', () => i);
    } else if (c == '报销') {
      map.putIfAbsent('reimburse', () => i);
    } else if (c == '币种') {
      map.putIfAbsent('currency', () => i);
    } else if (c.contains('交易状态') || c.contains('当前状态')) {
      map.putIfAbsent('status', () => i);
    }
  }
  return map;
}

String _pick(List<String> cells, Map<String, int> map, String key) {
  final i = map[key];
  if (i == null || i >= cells.length) return '';
  return cells[i].replaceAll('"', '').trim();
}

/// 解析账单文本。识别不了表头时返回空结果 + 警告。
BillParseResult parseBillCsv(String text) {
  final warnings = <String>[];
  var skipped = 0;
  final rows = <BillRow>[];

  final lines = text
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) {
    return BillParseResult(
        rows: const [], skipped: 0, warnings: const ['内容是空的']);
  }

  // 找表头行：前 30 行里第一个能识别出「日期 + 金额」的
  var headerIndex = -1;
  var map = <String, int>{};
  for (var i = 0; i < lines.length && i < 30; i++) {
    final m = _mapHeader(splitCsvLine(lines[i]));
    if (m.containsKey('date') && m.containsKey('amount')) {
      headerIndex = i;
      map = m;
      break;
    }
  }
  if (headerIndex < 0) {
    return BillParseResult(
      rows: const [],
      skipped: 0,
      warnings: const ['没找到表头：需要包含「交易时间/日期」和「金额」两列'],
    );
  }

  var source = 'generic';
  final headerLine = lines[headerIndex];
  // 先判支付宝：它同时有「交易对方」和「商品说明」，
  // 如果先判微信会被误识别成微信（踩过）。
  if (headerLine.contains('收/付款方式') || headerLine.contains('交易分类')) {
    source = 'alipay';
  } else if (headerLine.contains('交易对方') && headerLine.contains('商品')) {
    source = 'wechat';
  }

  for (var i = headerIndex + 1; i < lines.length; i++) {
    final cells = splitCsvLine(lines[i]);
    final day = _parseDate(_pick(cells, map, 'date'));
    final cents = _parseAmount(_pick(cells, map, 'amount'));
    if (day == null || cents == null || cents == 0) {
      skipped++;
      if (warnings.length < 5) warnings.add('第 ${i + 1} 行日期或金额无效，已跳过');
      continue;
    }

    final flowRaw = _pick(cells, map, 'flow');
    final statusRaw = _pick(cells, map, 'status');
    // 「不计收支」「退款成功」这类行不该进账
    if (flowRaw.contains('不计') || statusRaw.contains('已全额退款')) {
      skipped++;
      continue;
    }
    String flow;
    if (flowRaw.contains('收入') || flowRaw == '收') {
      flow = 'in';
    } else if (flowRaw.contains('支出') || flowRaw == '支') {
      flow = 'out';
    } else {
      // 简记自己的导出：类型列写的是「支出/收入/转账」
      if (flowRaw.contains('转账')) {
        skipped++;
        continue;
      }
      flow = flowRaw.contains('收入') ? 'in' : 'out';
    }

    final reimburseText = _pick(cells, map, 'reimburse');
    rows.add(BillRow(
      day: day,
      cents: cents,
      flow: flow,
      category: _pick(cells, map, 'category'),
      counterparty: _pick(cells, map, 'counterparty'),
      memo: _pick(cells, map, 'memo'),
      method: _pick(cells, map, 'method'),
      tags: _pick(cells, map, 'tags'),
      reimburse: reimburseText.contains('待报销')
          ? 1
          : (reimburseText.contains('已报销') ? 2 : 0),
    ));
  }

  if (rows.isEmpty) {
    warnings.add('没有解析出任何记录，检查一下是不是原始的账单 CSV');
  }
  return BillParseResult(
      rows: rows, skipped: skipped, warnings: warnings, source: source);
}

/// 导入时的备注：对方 + 商品说明拼一起，避免只剩「商户单号」这种没信息的内容
String billMemoOf(BillRow row) {
  final parts = <String>[
    if (row.counterparty.isNotEmpty) row.counterparty,
    if (row.memo.isNotEmpty && row.memo != row.counterparty) row.memo,
  ];
  final text = parts.join(' · ');
  return text.length > 60 ? text.substring(0, 60) : text;
}

/// 去重指纹：同一天、同金额、同备注视为重复
String billFingerprint(DateTime day, int cents, String memo) =>
    '${dayKey(day)}|$cents|$memo';
