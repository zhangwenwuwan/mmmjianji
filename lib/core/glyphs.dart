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
/// 1.4.73 之前 `kPocketTypes` 有 49 个类型，其中 38 个没有插画、继续用 emoji。
/// 那些类型在「选择类型」里本来就看不到，只在老账户的编辑页露一眼 ——
/// 留着等于让 emoji 在 App 里阴魂不散。现在整表只留这 11 个（见 pocket_types.dart），
/// 老账户由 DB v27 迁移归一，一个 emoji 都不剩。
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
  // 第二批：物体图标池
  'obj_notebook': '📒',
  'obj_house': '🏠',
  'obj_luggage': '🧳',
  'obj_office': '💼',
  'obj_graduation': '🎓',
  'obj_pet': '🐱',
  'obj_car': '🚗',
  'obj_plane': '✈️',
  'obj_tv': '📺',
  'obj_movie': '🎬',
  'obj_music': '🎵',
  'obj_cloud': '☁️',
  'obj_box': '📦',
  'obj_game': '🎮',
  'obj_book': '📚',
  'obj_cart': '🛒',
  'obj_ai': '🤖',
  'obj_clipboard': '📋',
  'obj_coffee': '☕',
  'obj_bulb': '💡',
  'obj_phone': '📱',
  'obj_fuel': '⛽',
  'obj_sneaker': '👟',
  'obj_laptop': '💻',
  'obj_headphone': '🎧',
  'obj_watch': '⌚',
  'obj_bag': '👜',
  'obj_chair': '🪑',
};

// ---------------------------------------------------------------------------
// 第二批：账本 / 会员订阅 / 记账模板 / 心愿单
//
// 这四组共用同一个「物体」图标池（`obj_*`）：房子、车子、飞机、游戏机这些
// 概念在四个功能里都用得上，画一次到处引用，别按功能各画一套。
// 少数几张直接复用第一批的分类图标（吃饭/通勤/买药/礼物）。
// ---------------------------------------------------------------------------

/// 账本图标（账本管理列表 + 账本编辑框）。
const List<String> kBookGlyphIds = [
  'obj_notebook',
  'obj_house',
  'obj_luggage',
  'obj_office',
  'obj_graduation',
  'obj_pet',
  'obj_car',
  'obj_plane',
];

/// 会员订阅图标。
const List<String> kSubsGlyphIds = [
  'obj_tv',
  'obj_movie',
  'obj_music',
  'obj_cloud',
  'obj_box',
  'obj_game',
  'obj_book',
  'obj_office',
  'obj_cart',
  'obj_ai',
];

/// 记账模板图标。吃饭/通勤/买药直接复用分类插画，不为模板再画一遍。
const List<String> kTplGlyphIds = [
  'obj_clipboard',
  'out_food',
  'out_transport',
  'obj_coffee',
  'obj_cart',
  'obj_bulb',
  'obj_phone',
  'obj_house',
  'obj_fuel',
  'obj_movie',
  'out_medical',
  'obj_pet',
];

/// 心愿单图标。礼物盒复用分类的「礼」。
const List<String> kWishGlyphIds = [
  'out_gift',
  'obj_sneaker',
  'obj_phone',
  'obj_laptop',
  'obj_headphone',
  'obj_watch',
  'obj_bag',
  'obj_game',
  'obj_plane',
  'obj_chair',
];

/// 把 id 清单转成存库值（`['out_food']` → `['ic:out_food']`）。
List<String> glyphListOf(List<String> ids) => [for (final id in ids) Glyphs.of(id)];
