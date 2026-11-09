/// URL Scheme 快捷记账：`jianji:///add?...` / `jianji:///voice`。
///
/// 用途：第三方 App、自动化工具（Tasker / HTTP Shortcuts 等）、桌面长按
/// 快捷方式都能直接把参数带进来落账，不用先打开 App 再手动输入。
///
/// 解析原则：**这里只做语法解析与校验，不做任何业务查询**——
/// 分类/账户按名称匹配要查数据库，放在编辑器层做（见 editor_page 的
/// _applySchemeDraft）。解析失败返回 null，调用方对 null 的处理是
/// 「正常打开 App」，绝不崩。
///
/// 支持（推荐三斜杠路径式，见 parseScheme 注释）：
/// - `jianji:///add?money=25.5&note=午饭&bucket=食&pocket=微信&flow=out&date=2026-11-09&auto=1`
/// - `jianji:///voice`  → 直接开语音记账页
/// - 兼容旧式 `jianji://add?...` 与引擎剥残体 `/add?...`、`/?money=...`
///
/// 参数说明：
/// - money（必填）：金额，接受 "25" / "25.5" / "25.50"，最多两位小数；
///   也容忍 "¥25" 这种带符号前缀。负数/零/非法 → 整条命令判 null。
/// - note：备注（原样带进备忘输入框）。
/// - bucket：分类名（先精确匹配，再前缀匹配；找不到就保持默认分类）。
/// - pocket：账户名（匹配规则同上；找不到就走「上次账户」逻辑）。
/// - flow：out（支出，默认）/ in（收入）。转账不开放——转账要填转入方，
///   参数太多，第三方拼不对还不如手记。
/// - date：YYYY-MM-DD；省略 = 今天。未来日期不拦（用户可能预记）。
/// - auto：1 = 进编辑器后直接落库（失败则停在编辑器让人补，不静默丢账）。
library;

import 'rules.dart';

/// 一条 scheme 命令。
class SchemeCommand {
  const SchemeCommand.add(this.draft) : action = 'add';
  const SchemeCommand.voice() : action = 'voice', draft = null;

  /// add = 带参记账；voice = 直接开语音记账页。
  final String action;

  /// 仅 add 有值。
  final SchemeAddDraft? draft;
}

/// `jianji://add` 的参数（已过语法校验）。
///
/// bucket/pocket 只带「名字」，按名字到数据库匹配是编辑器的事。
class SchemeAddDraft {
  const SchemeAddDraft({
    required this.amountCents,
    this.flow = 'out',
    this.memo = '',
    this.bucketName,
    this.pocketName,
    this.day,
    this.auto = false,
  });

  /// 已转成整数分；0 = 裸 add（桌面快捷方式），金额留空直接开编辑器。
  final int amountCents;

  /// out / in。
  final String flow;

  final String memo;

  /// 分类名（用户在 URL 里写的原文）。
  final String? bucketName;

  /// 账户名（同上）。
  final String? pocketName;

  /// null = 今天。
  final DateTime? day;

  /// true = 打开编辑器后自动落库。
  final bool auto;

  /// 键盘金额串（不带千分位，直接进 _amount）。
  String get amountText => centsToText(amountCents);
}

/// 解析一条 scheme 链接。不认识 / 参数不合法 → null。
///
/// **认三种形态**（2026-11-09 真机实锤：Android 引擎热启动转发时，
/// WidgetsApp.didPushRouteInformation 会把链接的 scheme 剥掉——
/// `jianji:///voice` 变成 `/voice`、`jianji://add?...` 变成 `/?...`——
/// 所以剥残体也要认识）：
/// - 完整：`jianji://add?...`、`jianji:///add?...`、`jianji://voice`、`jianji:///voice`
/// - 剥残体：`/voice`、`/add?...`、`/?money=...`（最后这种来自旧式
///   authority 写法被引擎剥掉的结果，认它是为了不崩、能正常记账）
///
/// 推荐**三斜杠路径式** `jianji:///add?...`：authority 为空时整条命令
/// 都在 path 里，剥掉 scheme 后照常工作。
SchemeCommand? parseScheme(String? raw) {
  if (raw == null) return null;
  final s = raw.trim();
  if (s.isEmpty) return null;
  final Uri uri;
  try {
    uri = Uri.parse(s);
  } on FormatException {
    return null;
  }

  String? action;
  if (uri.scheme == 'jianji') {
    if (uri.host == 'add' || uri.host == 'voice') {
      action = uri.host;
    } else if (uri.host.isEmpty) {
      // jianji:///add?... / jianji:///voice：路径式
      action = _pathAction(uri.path);
    } else {
      return null;
    }
  } else if (uri.scheme.isEmpty && uri.host.isEmpty && uri.path.startsWith('/')) {
    // 引擎剥掉 scheme 后的残体
    action = _pathAction(uri.path);
  } else {
    return null;
  }

  switch (action) {
    case 'voice':
      return const SchemeCommand.voice();
    case 'add':
      final draft = _parseAdd(uri);
      return draft == null ? null : SchemeCommand.add(draft);
    default:
      return null;
  }
}

/// 从 path 判断动作。`/` 或空（`/?money=...` 的残体）按 add 处理——
/// 真正的首页启动根本不会走到这里（home 命中在前），parseScheme('/goods')
/// 这种也会因 money 缺失整条判 null。
String? _pathAction(String path) {
  switch (path) {
    case '/voice':
      return 'voice';
    case '/add':
    case '/':
    case '':
      return 'add';
    default:
      return null;
  }
}

SchemeAddDraft? _parseAdd(Uri uri) {
  final q = uri.queryParameters;

  final bare = uri.queryParameters.isEmpty; // 裸 add（桌面快捷方式）：开空编辑器

  // money 是唯一硬性参数：解析不出正数就整条作废。
  // 容忍 "¥25" / "￥25" 前缀——第三方拼接时常见。
  // 例外：**裸 add**（一个参数都没有）表示「直接开编辑器」，金额留空。
  // 只要带了 query，money 缺失/非法就整条作废——不猜用户意图，不静默记错账。
  final moneyRaw =
      (q['money'] ?? '').replaceAll('¥', '').replaceAll('￥', '').trim();
  final cents = moneyRaw.isEmpty && bare ? 0 : parseAmountToCents(moneyRaw);
  if (cents == null || cents < 0) return null;
  if (cents == 0 && !bare) return null;

  final flow = (q['flow'] ?? 'out').trim().toLowerCase();
  if (flow != 'out' && flow != 'in') return null;

  // date 只认 YYYY-MM-DD；写不出合法日期就当没传（回落到今天），
  // 不因为一个可选参数写错而整条作废。
  DateTime? day;
  final dateRaw = (q['date'] ?? '').trim();
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(dateRaw);
  if (m != null) {
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
      day = DateTime(y, mo, d);
    }
  }

  String? name(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty ? null : t;
  }

  return SchemeAddDraft(
    amountCents: cents,
    flow: flow,
    memo: (q['note'] ?? q['memo'] ?? '').trim(),
    bucketName: name(q['bucket']),
    pocketName: name(q['pocket']),
    day: day,
    auto: (q['auto'] ?? '') == '1' || (q['auto'] ?? '').toLowerCase() == 'true',
  );
}

/// 生成一条标准 scheme（也用于测试与「复制示例」）。
///
/// 用**三斜杠路径式**：`jianji:///add?...`。authority 为空时整条命令都在
/// path 里——Android 引擎热启动转发会剥掉 scheme，但保留 path，所以这种
/// 写法冷启动、热启动、剥残体三种情况都能正确路由（见 parseScheme 注释）。
String buildAddScheme(SchemeAddDraft d) {
  final p = <String, String>{
    'money': centsToText(d.amountCents),
    if (d.flow != 'out') 'flow': d.flow,
    if (d.memo.isNotEmpty) 'note': d.memo,
    if (d.bucketName != null) 'bucket': d.bucketName!,
    if (d.pocketName != null) 'pocket': d.pocketName!,
    if (d.day != null)
      'date':
          '${d.day!.year.toString().padLeft(4, '0')}-'
          '${d.day!.month.toString().padLeft(2, '0')}-'
          '${d.day!.day.toString().padLeft(2, '0')}',
    if (d.auto) 'auto': '1',
  };
  final q = p.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}'
          '=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return 'jianji:///add${q.isEmpty ? '' : '?$q'}';
}
