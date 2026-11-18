/// 内置图标（设计师画的 PNG）与 emoji 的统一标识。
///
/// 历史：1.4.72 之前 `glyph` 一律是 emoji 字符串（`'🍜'`），直接 `Text` 画。
/// 1.4.73 起分类/账户换成 PNG，存 `'ic:out_food'` 这种 id，渲染走 [AppGlyph]。
///
/// ⚠️ **老数据（emoji）必须继续能画**：升级后老账户/老分类不会变空白，
/// 也不会因为认不出 id 而整块消失。所有判断都走 [isIcon]，认不出就当 emoji。
class Glyphs {
  const Glyphs._();

  static const prefix = 'ic:';

  /// 是不是内置 PNG 图标（而不是 emoji / 自定义图片）。
  static bool isIcon(String glyph) => glyph.startsWith(prefix);

  /// 拼一个图标 id 的存库值：`Glyphs.of('out_food')` → `'ic:out_food'`。
  static String of(String id) => '$prefix$id';

  /// 取 id：`'ic:out_food'` → `'out_food'`。
  static String idOf(String glyph) =>
      isIcon(glyph) ? glyph.substring(prefix.length) : glyph;

  /// 资源路径。目录是平铺的，文件名 = id，加新图标只放文件 + 加常量。
  static String assetPath(String glyph) =>
      'assets/icons/${idOf(glyph)}.png';
}

/// 支出一级分类的图标 id（顺序 = 记账页 4 列网格的排列）。
///
/// 前 8 个正好两行，第 9 个「其他」独占第三行 —— 位置本身在提示它是兜底项。
const List<String> kOutGlyphIds = [
  'out_food',
  'out_transport',
  'out_housing',
  'out_shopping',
  'out_fun',
  'out_medical',
  'out_education',
  'out_gift',
  'out_other',
];

/// 收入一级分类的图标 id。
const List<String> kInGlyphIds = [
  'in_salary',
  'in_sidejob',
  'in_invest',
  'in_redpacket',
  'in_other',
];

/// 账户图标 id：只覆盖「新增账户」里能选到的 11 个类型。
///
/// 其余类型（股票、基金、房产、贷款…）没有专属插画，继续用 emoji ——
/// 硬塞一个不相干的图标比 emoji 更误导。
const List<String> kAccountGlyphIds = [
  'acc_cash',
  'acc_alipay',
  'acc_wechat',
  'acc_bank',
  'acc_qq',
  'acc_jd',
  'acc_credit',
  'acc_huabei',
  'acc_baitiao',
  'acc_custom',
  'acc_custom_credit',
];

/// 图标 id → emoji。
///
/// 只给**放不进图片**的位置用（桑基图标签、下拉项文字、图例），
/// 这些地方拼的是纯字符串，塞不进一张图。文字替代的入口统一是
/// `app_glyph.dart` 的 `glyphLabel()`。
const Map<String, String> kGlyphEmoji = {
  'out_food': '🍜',
  'out_transport': '🚌',
  'out_housing': '🏠',
  'out_shopping': '🛍️',
  'out_fun': '🎮',
  'out_medical': '💊',
  'out_education': '📚',
  'out_gift': '🎁',
  'out_other': '✨',
  'in_salary': '💰',
  'in_sidejob': '💼',
  'in_invest': '📈',
  'in_redpacket': '🧧',
  'in_other': '✨',
  'acc_cash': '💵',
  'acc_alipay': '🅰️',
  'acc_wechat': '💚',
  'acc_bank': '🏦',
  'acc_qq': '🐧',
  'acc_jd': '🐶',
  'acc_credit': '💳',
  'acc_huabei': '🌸',
  'acc_baitiao': '🧾',
  'acc_custom': '⭐',
  'acc_custom_credit': '⭐',
};
