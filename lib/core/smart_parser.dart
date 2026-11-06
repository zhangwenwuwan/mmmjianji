/// 口语文本 → 账单草稿。
///
/// 设计取自一木记账的「智能记账」：**语音/听写只负责把话变成文字，语义全在这里解析**。
/// 这样以后换 ASR、加自动记账或截图 OCR，都复用同一份规则。
///
/// 纯 Dart、不依赖 Flutter / 数据库 / 网络，输入固定 [SmartContext.now] 时结果可复现，
/// 所以能用普通单测覆盖。金额单位统一「分」（见 core/rules.dart）。
library;

import 'package:jianji/core/rules.dart';

/// 解析时能用到的分类（由 UI 从 bucketsProvider 转成这个轻量结构）。
class SmartCategory {
  const SmartCategory({
    required this.id,
    required this.title,
    required this.flow,
    this.parentId,
  });

  final int id;
  final String title;
  final String flow;
  final int? parentId;
}

/// 解析时能用到的账户（title 正式名、alias 简称）。
class SmartAccount {
  const SmartAccount({required this.id, required this.title, this.alias});

  final int id;
  final String title;
  final String? alias;

  List<String> get names => [
        title,
        if (alias != null && alias!.trim().isNotEmpty) alias!.trim(),
      ];
}

/// 记忆表：用户上次手动改过的「关键词 → 分类/账户 id」。
/// 由 UI 从 SharedPreferences 读进来，解析时优先命中。
class SmartContext {
  const SmartContext({
    required this.now,
    this.categories = const [],
    this.accounts = const [],
    this.categoryHints = const {},
    this.accountHints = const {},
  });

  final DateTime now;
  final List<SmartCategory> categories;
  final List<SmartAccount> accounts;
  final Map<String, int> categoryHints;
  final Map<String, int> accountHints;
}

/// 解析结果。字段都可为空 —— 缺的部分在确认页让用户补，绝不猜一个值塞进去。
class BillDraft {
  const BillDraft({
    required this.raw,
    required this.day,
    this.amountCents,
    this.flow = 'out',
    this.bucketId,
    this.pocketId,
    this.toPocketId,
    this.timeMinutes,
    this.memo = '',
    this.keyword = '',
    this.confidence = 0.3,
    this.missing = const [],
    this.notes = const [],
  });

  final String raw;
  final int? amountCents;
  final String flow; // out / in / transfer
  final int? bucketId;
  final int? pocketId;
  final int? toPocketId;
  final DateTime day;
  final int? timeMinutes;
  final String memo;

  /// 用于记忆表的关键词（去掉金额/时间/账户/分类后的说法，如「星巴克」）。
  final String keyword;

  /// 0..1，只用来在确认页提示「把握不大，请核对」，不参与落库。
  final double confidence;
  final List<String> missing;
  final List<String> notes;

  bool get hasAmount => (amountCents ?? 0) > 0;
  bool get isTransfer => flow == 'transfer';
  bool get canSave =>
      hasAmount && (!isTransfer || (pocketId != null && toPocketId != null));
}

/// 口语里说法 → 分类标题的兜底词典。
///
/// 只写「用户会这么说」的词，不写分类名本身；分类名从 [SmartContext.categories]
/// 里查，这样用户自定义分类照样能命中。简记默认分类是 衣/食/住/行 四个单字，
/// 所以这里把它们写成目标字，匹配时要求精确相等，避免「行」误命中「银行」。
const Map<String, String> _categoryWords = {
  '早餐': '食', '早饭': '食', '午饭': '食', '午餐': '食',
  '晚饭': '食', '晚餐': '食', '吃饭': '食', '外卖': '食',
  '咖啡': '食', '奶茶': '食', '买菜': '食', '水果': '食',
  '零食': '食', '聚餐': '食', '饮料': '食', '夜宵': '食',
  '打车': '行', '地铁': '行', '公交': '行', '加油': '行',
  '停车': '行', '高铁': '行', '火车': '行', '机票': '行',
  '单车': '行', '出租车': '行', '过路费': '行',
  '房租': '住', '水电': '住', '水费': '住', '电费': '住',
  '物业': '住', '宽带': '住', '话费': '住', '燃气': '住',
  '衣服': '衣', '鞋子': '衣', '理发': '衣', '化妆品': '衣',
  '裤子': '衣', '洗衣': '衣',
  '工资': '收入', '薪水': '收入', '奖金': '收入', '红包': '收入',
  '退款': '收入', '利息': '收入', '兼职': '收入', '分红': '收入',
  '电影': '娱乐', '游戏': '娱乐', '会员': '娱乐', '门票': '娱乐',
  '看病': '医疗', '医院': '医疗', '买药': '医疗', '挂号': '医疗',
  '买书': '学习', '课程': '学习', '学费': '学习', '培训': '学习',
};

const List<String> _incomeWords = [
  '工资', '薪水', '奖金', '红包', '退款', '利息', '分红', '兼职',
  '收入', '到账', '收到', '入账', '赚了', '发了工资', '收款',
];

const List<String> _transferWords = [
  '转到', '转给', '转入', '转至', '划到', '转进', '转帐', '转账',
];

/// 常见账户叫法：先在用户账户里找包含这个词的，找不到就当没识别。
const List<String> _accountAliases = [
  '支付宝', '微信', '余额宝', '银行卡', '信用卡', '储蓄卡', '现金',
  '饭卡', '公积金', '花呗', '零钱', '工资卡',
];

const Map<String, int> _dayWordOffset = {
  '大前天': -3,
  '前天': -2,
  '昨天': -1,
  '昨日': -1,
  '今天': 0,
  '今日': 0,
  '明天': 1,
  '明日': 1,
  '后天': 2,
  '大后天': 3,
};

const Map<String, int> _cnDigits = {
  '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
  '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
};

/// 归一化：全角转半角、去空白。中文标点保留（备注里要用）。
String _normalize(String raw) {
  final buf = StringBuffer();
  for (final cu in raw.codeUnits) {
    var c = cu;
    if (c >= 0xFF01 && c <= 0xFF5E) {
      c = c - 0xFEE0; // 全角字母/数字/标点 → 半角
    } else if (c == 0xFFE5) {
      c = 0xA5; // ￥ → ¥
    } else if (c == 0x3000) {
      c = 0x20;
    }
    buf.writeCharCode(c);
  }
  return buf.toString().replaceAll(RegExp(r'\s+'), '');
}

DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

int? _digitValue(String s) {
  if (s.isEmpty) return null;
  if (s.length == 1) {
    final cn = _cnDigits[s];
    if (cn != null) return cn;
  }
  return int.tryParse(s);
}

/// 中文数字转整数：「十五」15、「二十」20、「一百二」120（口语省略「十」）。
int? _cnToInt(String s) {
  if (s.isEmpty) return null;
  final single = _cnDigits[s];
  if (single != null) return single;
  var section = 0;
  var num = 0;
  var sawBigUnit = false;
  for (final ch in s.split('')) {
    final d = _cnDigits[ch];
    if (d != null) {
      num = d;
      continue;
    }
    if (ch == '十') {
      section += (num == 0 ? 1 : num) * 10;
      num = 0;
    } else if (ch == '百') {
      section += (num == 0 ? 1 : num) * 100;
      num = 0;
      sawBigUnit = true;
    } else if (ch == '千') {
      section += (num == 0 ? 1 : num) * 1000;
      num = 0;
      sawBigUnit = true;
    } else {
      return null;
    }
  }
  var total = section + num;
  // 「一百二」= 120 而不是 102；「一百二十」含「十」，不进这个分支。
  if (sawBigUnit && num > 0 && !s.contains('十')) total = section + num * 10;
  return total;
}

class _TimeHit {
  const _TimeHit({
    required this.day,
    this.minutes,
    this.spans = const [],
    this.labels = const [],
  });

  final DateTime day;
  final int? minutes;
  final List<String> spans;
  final List<String> labels;
}

_TimeHit _parseTime(String text, DateTime now) {
  final spans = <String>[];
  final labels = <String>[];

  final wordRe =
      RegExp(r'(大前天|大后天|前天|后天|昨天|昨日|今天|今日|明天|明日)');
  final word = wordRe.firstMatch(text);
  DateTime? day;
  if (word != null) {
    final key = word.group(1)!;
    day = _dateOnly(now.add(Duration(days: _dayWordOffset[key] ?? 0)));
    spans.add(word.group(0)!);
    labels.add(key);
  }

  final ymdRe = RegExp(r'(\d{4})年(\d{1,2})月(\d{1,2})[日号]?');
  final ymd = ymdRe.firstMatch(text);
  final mdRe = RegExp(r'(\d{1,2})月(\d{1,2})[日号]?');
  if (ymd != null) {
    final y = int.parse(ymd.group(1)!);
    final m = int.parse(ymd.group(2)!);
    final d = int.parse(ymd.group(3)!);
    if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
      day = DateTime(y, m, d);
      spans.add(ymd.group(0)!);
      labels.add('$m月$d日');
    }
  } else {
    final md = mdRe.firstMatch(text);
    if (md != null) {
      final m = int.parse(md.group(1)!);
      final d = int.parse(md.group(2)!);
      if (m >= 1 && m <= 12 && d >= 1 && d <= 31) {
        day = DateTime(now.year, m, d);
        spans.add(md.group(0)!);
        labels.add('$m月$d日');
      }
    } else {
      final dayRe = RegExp(r'(\d{1,2})[日号]');
      final dOnly = dayRe.firstMatch(text);
      if (dOnly != null && word == null) {
        final d = int.parse(dOnly.group(1)!);
        if (d >= 1 && d <= 31) {
          day = DateTime(now.year, now.month, d);
          spans.add(dOnly.group(0)!);
          labels.add('$d号');
        }
      }
    }
  }

  final weekRe = RegExp(r'(上|这|本|下)?(?:周|星期)([一二三四五六七天日1-7])');
  final week = weekRe.firstMatch(text);
  if (week != null) {
    final x = _digitValue(week.group(2)!) ?? 1;
    final target = x.clamp(1, 7);
    final prefix = week.group(1);
    final shift = prefix == '上'
        ? -7
        : prefix == '下'
            ? 7
            : 0;
    final monday = _dateOnly(now.subtract(Duration(days: now.weekday - 1)));
    day = monday.add(Duration(days: shift + target - 1));
    spans.add(week.group(0)!);
    labels.add(week.group(0)!);
  }

  final clockRe = RegExp(
      r'(早上|早晨|上午|中午|下午|晚上|傍晚|凌晨)?(\d{1,2})(?:点|时|:|：)(\d{1,2})?半?');
  final clock = clockRe.firstMatch(text);
  int? minutes;
  if (clock != null) {
    var hour = int.tryParse(clock.group(2)!) ?? 0;
    final minuteText = clock.group(3);
    var minute = minuteText != null ? (int.tryParse(minuteText) ?? 0) : 0;
    final span = clock.group(0)!;
    if (minuteText == null && span.contains('半')) minute = 30;
    final period = clock.group(1);
    if ((period == '下午' || period == '晚上' || period == '傍晚') &&
        hour < 12) {
      hour += 12;
    } else if (period == '中午' && hour < 12) {
      hour = 12;
    }
    hour = hour.clamp(0, 23);
    minute = minute.clamp(0, 59);
    minutes = hour * 60 + minute;
    spans.add(span);
    labels.add(span);
  }

  return _TimeHit(
    day: day ?? _dateOnly(now),
    minutes: minutes,
    spans: spans,
    labels: labels,
  );
}

class _AmountHit {
  const _AmountHit(this.cents, this.span, this.explicit, this.label);
  final int cents;
  final String span;
  final bool explicit;
  final String label;
}

_AmountHit? _parseAmount(String text) {
  final yenRe = RegExp(r'¥\s*(\d+(?:\.\d{1,2})?)');
  final yen = yenRe.firstMatch(text);
  if (yen != null) {
    final cents = parseAmountToCents(yen.group(1)!);
    if (cents != null && cents > 0) {
      return _AmountHit(cents, yen.group(0)!, true, yen.group(0)!);
    }
  }

  final unitRe = RegExp(
      r'(?:(\d+(?:\.\d{1,2})?)|([零一二两三四五六七八九十百千]+))\s*'
      r'(?:块钱|块|元|圆|人民币|RMB|rmb)\s*'
      r'([零一二三四五六七八九0-9])?');
  final unit = unitRe.firstMatch(text);
  if (unit != null) {
    int? cents;
    if (unit.group(1) != null) {
      cents = parseAmountToCents(unit.group(1)!);
    } else if (unit.group(2) != null) {
      final n = _cnToInt(unit.group(2)!);
      if (n != null) cents = n * 100;
    }
    final jiao = unit.group(3);
    if (cents != null && jiao != null) {
      cents += (_digitValue(jiao) ?? 0) * 10;
    }
    if (cents != null && cents > 0) {
      final span = unit.group(0)!;
      return _AmountHit(cents, span, true, span);
    }
  }

  final jiaoRe = RegExp(r'([零一二两三四五六七八九十百千\d]+)\s*(?:毛|角)');
  final jiao = jiaoRe.firstMatch(text);
  if (jiao != null) {
    final raw = jiao.group(1)!;
    final n = int.tryParse(raw) ?? _cnToInt(raw);
    if (n != null && n > 0) {
      return _AmountHit(n * 10, jiao.group(0)!, true, jiao.group(0)!);
    }
  }

  // 没有单位：只认孤立的阿拉伯数字，且排除时间/日期残片。
  // 这是「早餐 15」这类说法，把握不大，置信度会在调用处降权。
  final bareRe = RegExp(r'\d+(?:\.\d{1,2})?');
  for (final m in bareRe.allMatches(text)) {
    final after = m.end < text.length ? text[m.end] : '';
    // contains('') 在 Dart 里恒为 true，句尾的裸数字会被误当成时间残片跳过。
    if (after.isNotEmpty && '年月日点号时周分秒个笔次天'.contains(after)) {
      continue;
    }
    final v = parseAmountToCents(m.group(0)!);
    if (v == null || v <= 0) continue;
    if (v >= 100000 && v <= 210000) continue; // 四位年份
    return _AmountHit(v, m.group(0)!, false, m.group(0)!);
  }
  return null;
}

/// 在文本里找一个分类关键词（长的优先），返回关键词本身。
String? _matchWord(String text, Iterable<String> words) {
  final sorted = words.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final w in sorted) {
    if (w.isEmpty) continue;
    if (text.contains(w)) return w;
  }
  return null;
}

int? _findCategoryId(String target, List<SmartCategory> categories, String flow) {
  for (final c in categories) {
    if (c.flow == flow && c.title == target) return c.id;
  }
  for (final c in categories) {
    if (c.flow != flow) continue;
    if (c.title.length >= 2 &&
        (c.title.contains(target) || target.contains(c.title))) {
      return c.id;
    }
  }
  return null;
}

({int? id, String? span}) _parseCategory(
    String text, SmartContext ctx, String flow) {
  // 1. 记忆表优先：用户上次手动纠正过的说法最可信。
  final hintKeys = ctx.categoryHints.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final k in hintKeys) {
    if (k.isNotEmpty && text.contains(k)) {
      return (id: ctx.categoryHints[k], span: k);
    }
  }
  // 2. 用户自定义分类名直接出现（≥2 字，避免「行」误命中「银行」）。
  final named = ctx.categories
      .where((c) => c.flow == flow && c.title.trim().length >= 2)
      .map((c) => c.title.trim())
      .toList();
  final hitNamed = _matchWord(text, named);
  if (hitNamed != null) {
    final id = _findCategoryId(hitNamed, ctx.categories, flow);
    if (id != null) return (id: id, span: hitNamed);
  }
  // 3. 内置口语词典 → 分类标题。
  final hit = _matchWord(text, _categoryWords.keys);
  if (hit != null) {
    final target = _categoryWords[hit]!;
    final id = _findCategoryId(target, ctx.categories, flow);
    if (id != null) return (id: id, span: hit);
    // 词典里的词本身可能就是分类名
    final direct = _findCategoryId(hit, ctx.categories, flow);
    if (direct != null) return (id: direct, span: hit);
    return (id: null, span: hit);
  }
  return (id: null, span: null);
}

List<({int id, int index, String span})> _parseAccounts(
    String text, SmartContext ctx) {
  final hits = <({int id, int index, String span})>[];
  final seen = <int>{};

  void add(int id, String word) {
    if (seen.contains(id)) return;
    final index = text.indexOf(word);
    if (index < 0) return;
    seen.add(id);
    hits.add((id: id, index: index, span: word));
  }

  final hintKeys = ctx.accountHints.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final k in hintKeys) {
    if (k.isNotEmpty && text.contains(k)) add(ctx.accountHints[k]!, k);
  }
  final names = <({int id, String name})>[];
  for (final a in ctx.accounts) {
    for (final n in a.names) {
      if (n.trim().length >= 2) names.add((id: a.id, name: n.trim()));
    }
  }
  names.sort((a, b) => b.name.length.compareTo(a.name.length));
  for (final n in names) {
    if (text.contains(n.name)) add(n.id, n.name);
  }
  final alias = _matchWord(text, _accountAliases);
  if (alias != null) {
    for (final a in ctx.accounts) {
      final all = a.names.join('|');
      if (all.contains(alias)) {
        add(a.id, alias);
        break;
      }
    }
  }
  hits.sort((a, b) => a.index.compareTo(b.index));
  return hits;
}

/// 从剩余文本里清掉语气词，得到备注。
String _memoOf(String text) {
  var s = text;
  const fillers = [
    '记一下', '一共', '总共', '花了', '买了', '用了', '付了', '支付了',
    '消费', '花费', '支出', '收入', '一笔', '块钱', '我', '了', '的',
    '在', '给', '把', '又', '还', '元', '块', '转', '从', '到',
  ];
  for (final f in fillers) {
    s = s.replaceAll(f, '');
  }
  s = s.replaceAll(RegExp(r'[,，。.!！?？;；:：~～\-—_/\\+*#]+'), '');
  return s.trim();
}

/// 入口：把一句口语变成账单草稿。
BillDraft parseSmartText(String raw, SmartContext ctx) {
  final norm = _normalize(raw);
  if (norm.isEmpty) {
    return BillDraft(
      raw: raw,
      day: _dateOnly(ctx.now),
      confidence: 0.0,
      missing: const ['金额'],
      notes: const ['还没有输入内容'],
    );
  }

  final notes = <String>[];
  final missing = <String>[];
  final consumed = <String>[];
  var confidence = 0.35;

  // 1. 时间：先把时间片段挖掉，避免「8点」「3月5日」被当成金额。
  final time = _parseTime(norm, ctx.now);
  consumed.addAll(time.spans);
  if (time.labels.isNotEmpty) {
    confidence += 0.08;
    notes.add('时间 ${time.labels.join('、')} → ${dayKey(time.day)}');
  }
  if (time.minutes != null) {
    final h = time.minutes! ~/ 60;
    final m = time.minutes! % 60;
    notes.add('记在 ${pad2(h)}:${pad2(m)}');
  }
  var rest = norm;
  for (final span in time.spans) {
    rest = rest.replaceFirst(span, '');
  }

  // 2. 金额
  final amount = _parseAmount(rest);
  int? amountCents;
  if (amount != null) {
    amountCents = amount.cents;
    consumed.add(amount.span);
    rest = rest.replaceFirst(amount.span, '');
    confidence += amount.explicit ? 0.25 : 0.05;
    notes.add(amount.explicit
        ? '金额 ${centsToText(amount.cents)} 元'
        : '金额 ${centsToText(amount.cents)} 元（没带单位，请核对）');
    if (!amount.explicit) confidence -= 0.1;
  } else {
    missing.add('金额');
  }

  // 3. 转账 / 收支。
  // 带「转到/转给」这类连接词时，连接词**前面**才是转出账户：
  // 「转到微信 15 元」缺转出账户，不能把微信当成转出。
  String? transferWord;
  for (final w in _transferWords) {
    if (rest.contains(w)) {
      transferWord = w;
      break;
    }
  }
  final singleTurn = RegExp(r'[一-龥\d]+转[一-龥\d]+').hasMatch(rest);
  final isTransferWord = transferWord != null || singleTurn;
  final isIncome =
      !isTransferWord && _incomeWords.any((w) => rest.contains(w));
  final flow = isTransferWord ? 'transfer' : (isIncome ? 'in' : 'out');
  var before = '';
  var after = '';
  if (isTransferWord) {
    notes.add('识别为转账');
    if (transferWord != null) {
      final idx = rest.indexOf(transferWord);
      before = rest.substring(0, idx);
      after = rest.substring(idx + transferWord.length);
      consumed.add(transferWord);
      rest = '$before$after';
    }
  } else if (isIncome) {
    notes.add('识别为收入');
  }

  // 4. 账户（转账取连接词两侧各一个，普通记账取第一个）
  int? pocketId;
  int? toPocketId;
  void takeAccount(List<({int id, int index, String span})> hits,
      {required bool asFrom}) {
    if (hits.isEmpty) return;
    final hit = hits.first;
    if (asFrom) {
      pocketId = hit.id;
      notes.add('账户 ${hit.span}');
    } else {
      toPocketId = hit.id;
      notes.add('转入 ${hit.span}');
    }
    consumed.add(hit.span);
    rest = rest.replaceFirst(hit.span, '');
    confidence += 0.12;
  }

  if (transferWord != null) {
    takeAccount(_parseAccounts(before, ctx), asFrom: true);
    takeAccount(_parseAccounts(after, ctx), asFrom: false);
  } else {
    final accounts = _parseAccounts(rest, ctx);
    if (accounts.isNotEmpty) {
      takeAccount([accounts.first], asFrom: true);
      if (isTransferWord && accounts.length >= 2) {
        takeAccount([accounts[1]], asFrom: false);
      }
    }
  }
  if (isTransferWord) {
    if (pocketId == null) missing.add('转出账户');
    if (toPocketId == null) missing.add('转入账户');
  } else if (pocketId == null) {
    missing.add('账户');
  }

  // 5. 分类（转账不需要）
  int? bucketId;
  if (!isTransferWord) {
    final cat = _parseCategory(rest, ctx, flow);
    if (cat.span != null && rest.contains(cat.span!)) {
      consumed.add(cat.span!);
      rest = rest.replaceFirst(cat.span!, '');
    }
    bucketId = cat.id;
    if (bucketId != null) {
      confidence += 0.15;
      notes.add('分类 ${cat.span}');
    } else if (cat.span != null) {
      notes.add('说法「${cat.span}」没找到对应分类');
      missing.add('分类');
    } else {
      missing.add('分类');
    }
  }

  // 6. 备注与记忆关键词
  var memo = _memoOf(rest);
  if (memo.length > 24) memo = memo.substring(0, 24);
  if (memo.isEmpty) {
    final fallback = _matchWord(norm, _categoryWords.keys);
    if (fallback != null) {
      memo = fallback;
    } else {
      // 命中记忆表时说法本身被消费掉了，从消费片段里挑一个中文词当备注，
      // 别把「星巴克 38 元」整句塞进备注栏。
      final candidates = consumed
          .where((s) => RegExp(r'^[一-龥]{2,}$').hasMatch(s))
          .toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      memo = candidates.isNotEmpty ? candidates.first : raw.trim();
    }
    if (memo.length > 24) memo = memo.substring(0, 24);
  }
  final keyword = memo.length >= 2 ? memo : '';

  return BillDraft(
    raw: raw,
    day: time.day,
    amountCents: amountCents,
    flow: flow,
    bucketId: bucketId,
    pocketId: pocketId,
    toPocketId: toPocketId,
    timeMinutes: time.minutes,
    memo: memo,
    keyword: keyword,
    confidence: confidence.clamp(0.05, 0.98).toDouble(),
    missing: List.unmodifiable(missing),
    notes: List.unmodifiable(notes),
  );
}
