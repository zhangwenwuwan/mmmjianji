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
  });

  /// 存库用的稳定标识（不要改，改了老数据就对不上了）
  final String id;
  final String label;
  final String glyph;
  final PocketKind kind;

  /// 选择器里的分组标题
  final String group;

  /// 新建时「名称」输入框的占位文案
  final String? nameHint;

  String get hint => nameHint ?? '例如 $label';
}

/// 全部分组（顺序就是选择器里的顺序）。
const List<String> kPocketTypeGroups = [
  '现金与储值',
  '银行与支付',
  '信用与分期',
  '投资与保障',
  '负债与借款',
];

/// 预设类型表。
///
/// 取舍：只收「真的会有人单独建账户」的。像「微信零钱」和「微信零钱通」
/// 这种不拆——一个账户记两笔更容易对账。图标一律用 emoji：不额外打包
/// 字体，Android / iOS 都能渲染。
const List<PocketType> kPocketTypes = [
  // ---- 现金与储值
  PocketType(
      id: 'cash',
      label: '现金',
      glyph: '💵',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 钱包、零钱'),
  // 2026-10-26 按 iCost 重构选择器后新增：和 cash 同口径，只是叫法更贴 iCost。
  PocketType(
      id: 'cashWallet',
      label: '现金钱包',
      glyph: '💵',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 钱包、零钱'),
  PocketType(
      id: 'wallet',
      label: '钱包',
      glyph: '👛',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 随身钱包'),
  PocketType(
      id: 'stored',
      label: '储值卡',
      glyph: '🎫',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 星巴克卡、理发卡'),
  PocketType(
      id: 'transit',
      label: '公交卡',
      glyph: '🚌',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 交通卡'),
  PocketType(
      id: 'meal',
      label: '饭卡',
      glyph: '🍱',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 公司饭卡、校园卡'),
  PocketType(
      id: 'gift',
      label: '购物卡',
      glyph: '🎁',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 京东卡、超市卡'),

  // ---- 银行与支付
  PocketType(
      id: 'debit',
      label: '储蓄卡',
      glyph: '🏦',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 招行储蓄卡'),
  PocketType(
      id: 'alipay',
      label: '支付宝',
      glyph: '🅰️',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 支付宝余额'),
  PocketType(
      id: 'wechat',
      label: '微信零钱',
      glyph: '💚',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 微信零钱'),
  // iCost 用的是「微信钱包」这个叫法
  PocketType(
      id: 'wechatWallet',
      label: '微信钱包',
      glyph: '💚',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 微信钱包'),
  PocketType(
      id: 'unionpay',
      label: '云闪付',
      glyph: '☁️',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 云闪付'),
  PocketType(
      id: 'paypal',
      label: 'PayPal',
      glyph: '🌐',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 PayPal'),
  PocketType(
      id: 'foreign',
      label: '外币账户',
      glyph: '💱',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 美元账户（记得改币种）'),

  // ---- 信用与分期（都是「先花后还」，有额度）
  PocketType(
      id: 'credit',
      label: '信用卡',
      glyph: '💳',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 招行信用卡'),
  PocketType(
      id: 'huabei',
      label: '花呗',
      glyph: '🌸',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 花呗'),
  PocketType(
      id: 'baitiao',
      label: '京东白条',
      glyph: '🐶',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 京东白条'),
  PocketType(
      id: 'meituan',
      label: '美团月付',
      glyph: '🍊',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 美团月付'),
  PocketType(
      id: 'douyin',
      label: '抖音月付',
      glyph: '🎵',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 抖音月付'),
  PocketType(
      id: 'fenqi',
      label: '分期平台',
      glyph: '🧾',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 分期乐、任性付'),

  // ---- 投资与保障（余额 = 现在值多少，不参与收支）
  PocketType(
      id: 'stock',
      label: '股票',
      glyph: '📈',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 证券账户'),
  PocketType(
      id: 'fund',
      label: '基金',
      glyph: '📊',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 天天基金'),
  PocketType(
      id: 'wealth',
      label: '理财',
      glyph: '💹',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 余额宝、理财通'),
  // iCost 的「其他理财」：一个通用理财账户兜底
  PocketType(
      id: 'otherWealth',
      label: '其他理财',
      glyph: '💹',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 银行理财、券商理财'),
  PocketType(
      id: 'deposit',
      label: '定期',
      glyph: '📜',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 三年定期'),
  PocketType(
      id: 'gold',
      label: '黄金',
      glyph: '🥇',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 纸黄金、金条'),
  PocketType(
      id: 'provident',
      label: '公积金',
      glyph: '🏛️',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 住房公积金'),
  PocketType(
      id: 'medical',
      label: '医保',
      glyph: '🏥',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 医保个人账户'),
  PocketType(
      id: 'insurance',
      label: '保险',
      glyph: '🛡️',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 增额终身寿'),

  // ---- 负债与借款（余额 = 还欠多少）
  // iCost 的「贷款」：房贷/车贷/网贷都往这里放，余额记「还欠多少」
  PocketType(
      id: 'loan',
      label: '贷款',
      glyph: '💸',
      kind: PocketKind.debt,
      group: '负债与借款',
      nameHint: '例如 房贷、车贷、网贷'),
  PocketType(
      id: 'mortgage',
      label: '房贷',
      glyph: '🏠',
      kind: PocketKind.debt,
      group: '负债与借款',
      nameHint: '例如 招行房贷'),
  PocketType(
      id: 'carloan',
      label: '车贷',
      glyph: '🚗',
      kind: PocketKind.debt,
      group: '负债与借款',
      nameHint: '例如 车贷'),
  PocketType(
      id: 'jiebei',
      label: '借呗',
      glyph: '💰',
      kind: PocketKind.debt,
      group: '负债与借款',
      nameHint: '例如 借呗、网商贷'),
  PocketType(
      id: 'borrow',
      label: '借款',
      glyph: '🤝',
      kind: PocketKind.debt,
      group: '负债与借款',
      nameHint: '例如 欠小王 3000'),
  PocketType(
      id: 'payable',
      label: '应付账款',
      glyph: '📮',
      kind: PocketKind.debt,
      group: '负债与借款',
      nameHint: '例如 待付货款'),

  // ---- 以下为「选择类型」页（对照参考 App）扩展的常用类型 ----
  // 注意：group 仍须落在 kPocketTypeGroups 内（sankey 测试约束）；
  // 选择器里的「展示分组」由 kAccountChooserGroups 单独控制，互不影响。
  // 口径（铁律）：应收/借出/报销是「别人欠我」，算资产 → bank；
  // 借入/应付是「我欠别人」，算负债 → debt。
  PocketType(
      id: 'bankcard',
      label: '银行卡',
      glyph: '🏦',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 招行借记卡'),
  PocketType(
      id: 'qq',
      label: 'QQ钱包',
      glyph: '🐧',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 QQ钱包'),
  PocketType(
      id: 'jd',
      label: '京东金融',
      glyph: '🐶',
      kind: PocketKind.bank,
      group: '银行与支付',
      nameHint: '例如 京东金融'),
  PocketType(
      id: 'baitiaoPlain',
      label: '白条',
      glyph: '🧾',
      kind: PocketKind.credit,
      group: '信用与分期',
      nameHint: '例如 京东白条'),
  PocketType(
      id: 'member',
      label: '会员卡',
      glyph: '🎫',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 超市会员卡'),
  PocketType(
      id: 'depositCard',
      label: '押金',
      glyph: '🛡️',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '例如 租房押金'),
  PocketType(
      id: 'crypto',
      label: '虚拟货币',
      glyph: '🪙',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 BTC、ETH'),
  PocketType(
      id: 'house',
      label: '房子',
      glyph: '🏠',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 自住房、出租房'),
  PocketType(
      id: 'car',
      label: '车子',
      glyph: '🚗',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 私家车'),
  PocketType(
      id: 'borrowIn',
      label: '借入',
      glyph: '🤝',
      kind: PocketKind.debt,
      group: '负债与借款',
      nameHint: '例如 欠朋友的钱'),
  PocketType(
      id: 'lendOut',
      label: '借出',
      glyph: '💸',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 借给朋友的钱'),
  PocketType(
      id: 'reimburse',
      label: '报销',
      glyph: '🧾',
      kind: PocketKind.bank,
      group: '投资与保障',
      nameHint: '例如 待报销的票'),
  // 「自定义」：选择器里的自定义项，选中后让用户自己改名 / 换图标。
  PocketType(
      id: 'custom',
      label: '自定义',
      glyph: '⭐',
      kind: PocketKind.cash,
      group: '现金与储值',
      nameHint: '自定义账户'),
];

/// 新增账户时「选择类型」展示的分组与类型（对照参考 App 的 6 组 25 项）。
///
/// ⚠️ 老类型**仍然留在 [kPocketTypes] 里**，只是不进这个选择器 ——
/// 否则老账户的 typeId 会失联、图标和名称一起丢。要增删可选类型，改这里就行。
const List<(String, List<String>)> kAccountChooserGroups = [
  ('资金账户', ['cash', 'alipay', 'wechatWallet', 'bankcard', 'qq', 'jd', 'custom']),
  ('信贷账户', ['credit', 'huabei', 'baitiaoPlain', 'custom']),
  ('充值账户', ['member', 'transit', 'meal', 'depositCard', 'custom']),
  ('投资理财', ['insurance', 'crypto', 'custom']),
  ('二手货物', ['house', 'car', 'custom']),
  ('债务', ['borrowIn', 'lendOut', 'reimburse']),
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
    if (t.kind == kind && t.glyph == glyph) return t;
  }
  for (final t in kPocketTypes) {
    if (t.kind == kind && t.id == kind.name) return t;
  }
  return null;
}
