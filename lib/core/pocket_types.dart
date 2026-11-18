import '../data/store.dart';

/// 账户「类型」预设：一木记账那种「支付宝 / 微信 / 花呗 / 房贷…」的列表。
///
/// 关键分层（别把两层混成一层）：
/// - [PocketKind] 只有 4 个值，管的是**计算语义**：余额正负、算不算负债、
///   要不要信用额度和账单日。所有统计、资产合计、净资产都靠它。
/// - [PocketType] 是**展示层**的细分类，有几十个，但每个都必须挂在某个
///   [PocketKind] 下面。它只决定：建账户时预填什么名字/图标、列表里显示
///   什么图标、选择器里归到哪一组。
///
/// 这样加类型只是往表里加一行，永远不会碰坏统计口径 —— 如果直接把
/// 支付宝 / 花呗 做成 enum 的新值，`isLiability`、`switch (kind)` 全部要改，
/// 漏一处就是余额符号翻转。
class PocketType {
  const PocketType({
    required this.id,
    required this.label,
    required this.glyph,
    required this.kind,
    required this.group,
    this.nameHint,
    this.legacyGlyph,
  });

  /// 存库用的稳定标识（不要改，改了老数据就对不上了）
  final String id;
  final String label;
  final String glyph;

  /// 1.4.73 之前用的 emoji 图标。
  ///
  /// 换成插画后，老账户（1.3.1 之前建的、没有 type 字段）身上存的还是 emoji，
  /// [guessPocketType] 靠它反推类型。同时也说明「这个类型是有插画的」。
  final String? legacyGlyph;
  final PocketKind kind;

  /// 选择器里的分组标题
  final String group;

  /// 新建时「名称」输入框的占位文案
  final String? nameHint;

  String get hint => nameHint ?? '例如 $label';
}

/// 全部分组（决定账户编辑页「所属分组」那行显示的文案）。
///
/// 1.4.73 精简类型表后只剩这三组 —— 原来还有「投资与保障」「负债与借款」，
/// 那两组下面的类型全删了（原因见 [kPocketTypes]）。
const List<String> kPocketTypeGroups = [
  '现金与储值',
  '银行与支付',
  '信用与分期',
];

/// 预设类型表：**只留「选择类型」里点得到的 11 个**（顺序与 [kAccountChooserGroups] 一致）。
///
/// 历史：这里一度有 49 个类型（储值卡 / 公交卡 / 股票 / 基金 / 房贷 / 黄金…），
/// 但「选择类型」只露两列 11 个，剩下 38 个既选不到、又各自挂着一个 emoji 图标，
/// 只在老账户的编辑页偶尔露一眼。1.4.73 换插画时把它们全删了 ——
/// 少一套 emoji，也少一张「有类型却选不到」的隐形表。
///
/// ⚠️ 加新类型的唯一前置条件：**先画好插画**（`ic:` 前缀，见 core/glyphs.dart），
/// 否则又是一个选不到、只能靠 emoji 撑着的孤儿。
///
/// `legacyGlyph` 必须留着：老账户没存 type，升级后靠「kind + 旧 emoji」反推类型，
/// 少了它认不出老账户是什么（桑基图会当场变红）。
const List<PocketType> kPocketTypes = [
  // ---- 资金账户（PocketKind.cash / bank）
  PocketType(
      id: 'cash',
      label: '现金',
      glyph: 'ic:acc_cash',
      legacyGlyph: '💵',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 钱包、零钱'),
  PocketType(
      id: 'alipay',
      label: '支付宝',
      glyph: 'ic:acc_alipay',
      legacyGlyph: '🅰️',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 支付宝余额'),
  PocketType(
      id: 'wechatWallet',
      label: '微信钱包',
      glyph: 'ic:acc_wechat',
      legacyGlyph: '💚',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 微信钱包'),
  PocketType(
      id: 'bankcard',
      label: '银行卡',
      glyph: 'ic:acc_bank',
      legacyGlyph: '🏦',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 招行借记卡'),
  PocketType(
      id: 'qq',
      label: 'QQ钱包',
      glyph: 'ic:acc_qq',
      legacyGlyph: '🐧',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 QQ钱包'),
  PocketType(
      id: 'jd',
      label: '京东金融',
      glyph: 'ic:acc_jd',
      legacyGlyph: '🐶',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 京东金融'),
  // 资金账户那一列的「自定义」：走现金口径（有余额、可记收支）。
  PocketType(
      id: 'custom',
      label: '自定义',
      glyph: 'ic:acc_custom',
      legacyGlyph: '⭐',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '自定义账户'),

  // ---- 信贷账户（PocketKind.credit：有额度 / 欠款 / 出账日 / 还款日）
  PocketType(
      id: 'credit',
      label: '信用卡',
      glyph: 'ic:acc_credit',
      legacyGlyph: '💳',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 招行信用卡'),
  PocketType(
      id: 'huabei',
      label: '花呗',
      glyph: 'ic:acc_huabei',
      legacyGlyph: '🌸',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 花呗'),
  PocketType(
      id: 'baitiaoPlain',
      label: '白条',
      glyph: 'ic:acc_baitiao',
      legacyGlyph: '🧾',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 京东白条'),
  // 信贷账户那一列的「自定义」：**和 custom 是不同的类型**，
  // 走信用卡口径，页面跟信用卡一致。
  PocketType(
      id: 'customCredit',
      label: '自定义',
      glyph: 'ic:acc_custom_credit',
      legacyGlyph: '⭐',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '自定义信用卡'),
];


/// 新增账户时「选择类型」展示的分组与类型。
///
/// 2026-10-26 用户拍板：只留「资金账户 / 信贷账户」两列，
/// 充值账户、投资理财、二手货物、债务四组**从这个页面删掉**（不是隐藏）。
///
/// ⚠️ 那些老类型**仍然留在 [kPocketTypes] 里** —— 否则老账户的 typeId 会失联、
/// 图标和名称一起丢。要增删可选类型，改这里就行，别动上面那张表。
const List<(String, List<String>)> kAccountChooserGroups = [
  (
    '资金账户',
    ['cash', 'alipay', 'wechatWallet', 'bankcard', 'qq', 'jd', 'custom']
  ),
  ('信贷账户', ['credit', 'huabei', 'baitiaoPlain', 'customCredit']),
];

PocketType? pocketTypeOf(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final t in kPocketTypes) {
    if (t.id == id) return t;
  }
  return null;
}

/// 老账户没有 type（1.3.1 之前建的），按 kind + glyph 反推一个最像的预设，
/// 只为让编辑页显示「现金 / 储蓄卡」而不是空着。
PocketType? guessPocketType(PocketKind kind, String glyph) {
  for (final t in kPocketTypes) {
    if (t.kind == kind && (t.glyph == glyph || t.legacyGlyph == glyph)) {
      return t;
    }
  }
  for (final t in kPocketTypes) {
    if (t.kind == kind && t.id == kind.name) return t;
  }
  return null;
}
