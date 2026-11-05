import 'package:flutter/material.dart';

/// 简记的视觉基调：米纸底 + 主题主色 + 朱红支出 / 青绿收入。
/// 全部自己定义，不依赖任何外部设计资源。
///
/// 一套配色 = **渐变**（大卡 / 按钮）+ **单色 seed**（生成整套 M3 配色）。
///
/// 为什么不是纯渐变：`ColorScheme.fromSeed` 只吃一个颜色，而文字、选中态、
/// 图标这些都要能算对比度的**实色**。所以 seed 负责"能被读的部分"，
/// 渐变只铺在大块面上（首页本月卡、资产页头部、主按钮）。
///
/// 前景色（白字 / 深字）不写死，由 [_onGradient] 按渐变平均亮度自动选 ——
/// 浅紫、薄荷、蜜桃这三套铺白字会糊，极光那套铺深字会脏。
typedef AppPaletteDef = ({
  String name,
  String hint,
  Color seed,
  List<Color> gradient,
});

const Map<String, AppPaletteDef> kPalettes = {
  'teal': (
    name: '草木薄荷',
    hint: '薄荷到青柠 · 低饱和冷调',
    seed: Color(0xFF0E7C66),
    gradient: [Color(0xFF8FD6BE), Color(0xFFCBE79A)],
  ),
  'indigo': (
    name: '极光油膜',
    hint: '青到靛紫 · 高饱和低明度',
    seed: Color(0xFF2B5C8A),
    gradient: [Color(0xFF0B3B52), Color(0xFF3B2F6B), Color(0xFF7A2B58)],
  ),
  'rose': (
    name: '薰衣草湖',
    hint: '浅紫到淡蓝 · 微光',
    seed: Color(0xFF6F63B8),
    gradient: [Color(0xFFC9B6F2), Color(0xFFA9D6F2)],
  ),
  'ochre': (
    name: '日落蜜桃',
    hint: '日落橙到蜜桃粉 · 暖调',
    seed: Color(0xFFC06A46),
    gradient: [Color(0xFFF2A25C), Color(0xFFF7BFC2)],
  ),
};

/// 渐变平均亮度超过这个值就用深色字。
///
/// 0.45 是试出来的分界：薄荷 / 薰衣草 / 蜜桃平均在 0.55~0.62，
/// 极光在 0.05 附近，中间没有配色落在这条线附近，所以不会反复横跳。
const Color _kOnLight = Color(0xFF14201B);

Color _onGradient(List<Color> stops) {
  var lum = 0.0;
  for (final c in stops) {
    lum += c.computeLuminance();
  }
  return (lum / stops.length) > 0.45 ? _kOnLight : Colors.white;
}

/// 当前配色方案的渐变 / 前景色。
///
/// 用 ThemeExtension 而不是全局变量：主题是跟着 `Theme.of(context)` 走的，
/// 深浅色模式下渐变要自动压暗，靠 context 取才不会出现"切深色后大卡还是亮粉"。
@immutable
class AppPaletteTheme extends ThemeExtension<AppPaletteTheme> {
  const AppPaletteTheme({
    required this.paletteId,
    required this.gradient,
    required this.onGradient,
  });

  final String paletteId;
  final LinearGradient gradient;

  /// 铺在渐变上的文字/图标颜色（白或深墨）。
  final Color onGradient;

  static const fallback = AppPaletteTheme(
    paletteId: 'teal',
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF8FD6BE), Color(0xFFCBE79A)],
    ),
    onGradient: _kOnLight,
  );

  @override
  AppPaletteTheme copyWith({
    String? paletteId,
    LinearGradient? gradient,
    Color? onGradient,
  }) =>
      AppPaletteTheme(
        paletteId: paletteId ?? this.paletteId,
        gradient: gradient ?? this.gradient,
        onGradient: onGradient ?? this.onGradient,
      );

  /// 主题切换是瞬时的（没有交叉淡入），插值没有意义，直接返回自身。
  @override
  AppPaletteTheme lerp(ThemeExtension<AppPaletteTheme>? other, double t) => this;
}

class Palette {
  const Palette._();

  static const seed = Color(0xFF0E7C66);

  /// 分类固定色板（2026-10-28）。
  ///
  /// 之前分类图标一律是**无彩灰底**（`hairline` 60%），一屏看过去全是灰方块；
  /// 图表原来有一套按「排序位置」分配的色板 ——
  /// 同一个「衣」，金额排名一变颜色就跟着变，颜色等于没有记忆点。
  ///
  /// 现在改成**按分类名固定取色**：同一个名字永远同一个颜色，
  /// 跨月份、跨页面（流水行 / 环形图 / 桑基图 / 分类管理）都一致。
  ///
  /// 选色原则：低饱和、同一明度档，铺在 14% 透明的图标底上不会抢文字；
  /// 十色足够区分常见分类，再多就分不清了。
  ///
  /// ⚠️ **故意不含品牌绿**：分类色经常和「+ 按钮 / 选中态 / 品牌元素」同屏出现，
  /// 撞成同一个绿就分不出"这是分类色还是主色"了。品牌绿只在下面 [seed] 用。
  static const kCategoryColors = <Color>[
    Color(0xFF3E9DBF), // 湖蓝
    Color(0xFFE0A458), // 琥珀
    Color(0xFF7B6BB5), // 紫
    Color(0xFFC94F45), // 朱红
    Color(0xFF5B8C5A), // 苔绿
    Color(0xFFC77B9E), // 绛粉
    Color(0xFF6B8CAE), // 灰蓝
    Color(0xFFB8894A), // 驼
    Color(0xFF8A9C8E), // 灰绿
    Color(0xFF0E7C66), // 松石绿（放最后：只有哈希恰好落到这格才用）
  ];

  /// 常见分类名的固定色。
  ///
  /// 只用哈希的话，`衣` 会算到苔绿、`食` 也会算到绿 —— 用户看到的第一屏
  /// 还是一片绿，等于白做。这里把最常见的几个按语义钉死：
  /// 吃=暖橙、穿=紫、住=蓝、行=苔绿，一眼能对上。
  /// 用户自己起的名字走哈希，也能拿到稳定的颜色。
  static const _kCategoryHints = <String, Color>{
    '食': Color(0xFFE0A458),
    '餐饮': Color(0xFFE0A458),
    '衣': Color(0xFF7B6BB5),
    '购物': Color(0xFFC77B9E),
    '住': Color(0xFF3E9DBF),
    '行': Color(0xFF5B8C5A),
    '交通': Color(0xFF5B8C5A),
    '医': Color(0xFFC94F45),
    '学': Color(0xFF6B8CAE),
    '玩': Color(0xFFB8894A),
    '工资': Color(0xFF5B8C5A),
    '兼职': Color(0xFF3E9DBF),
    '红包': Color(0xFFC94F45),
    '其他': Color(0xFF8A9C8E),
  };

  /// 稳定的字符串散列（不能用 `String.hashCode`：它没有跨版本承诺，
  /// 换个 Flutter 版本可能全 App 的色都变一遍）。
  static int _stableHash(String s) {
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  /// 取某分类的固定色。[label] 用分类名（不是 id）。
  ///
  /// 用名字而不是 id 的原因：`Slice`（图表的扇区）只有 label 没有 id，
  /// 而让图表颜色和流水行图标颜色对上，比"改名后颜色跟着变"重要得多。
  /// 改名是低频操作，改完换个颜色也不影响理解。
  ///
  /// 深色模式下同一色相提亮 18% —— 这十色是按浅底调的，直接铺在 #0E1512 上会发闷。
  static Color categoryColor(BuildContext context, String label) {
    // 先查常见分类的语义色，没命中再按名字哈希
    final base = _kCategoryHints[label] ??
        kCategoryColors[_stableHash(label) % kCategoryColors.length];
    if (!isDark(context)) return base;
    final hsl = HSLColor.fromColor(base);
    return hsl.withLightness((hsl.lightness + 0.18).clamp(0.0, 0.72)).toColor();
  }

  /// 支出红。
  ///
  /// 2026-10-28 从 #D0524A 加深到 #C6473F：原来在白卡上只有 4.21:1，
  /// 而金额普遍是 14~18px semibold，够不上 WCAG 的"大字号"豁免（要 18.66px bold）。
  /// 现在 4.80:1，色相不变。
  static const expense = Color(0xFFC6473F);

  /// 收入绿。同理从 #178A68（4.31:1）加深到 #12795C（5.36:1）。
  static const income = Color(0xFF12795C);

  /// 提醒色（预算接近上限、额度紧张）。原来各页面自己写 0xFFE0A458，
  /// 改一处得改多处，统一到令牌。
  static const warn = Color(0xFFE0A458);

  /// 信息色（信用卡还款提示这类"说明"）。之前是账户详情页里裸写的
  /// 0xFF3E7BB6 —— 全 App 唯一的蓝色，收进令牌免得再抄一遍。
  static const info = Color(0xFF3E7BB6);

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// 纸张底色。
  ///
  /// 2026-10-27 从冷灰 (#F4F6F5) 换成**薄荷白**：比纯白多一点绿，
  /// 大面积铺开是"干净的浅色"而不是"灰"。玻璃条压在这上面才透得出薄荷味。
  static Color paper(BuildContext context) =>
      isDark(context) ? const Color(0xFF0E1512) : const Color(0xFFF2F8F5);

  /// 卡片
  static Color card(BuildContext context) =>
      isDark(context) ? const Color(0xFF171D1A) : Colors.white;

  /// 玻璃：压在滚动内容上的条带 / 面板底（必须配合 BackdropFilter 用）。
  ///
  /// 不透明的话就是一块塑料板；透明度太低又会把下面的字透出来。
  /// 0.62~0.72 是「看得出有东西在动、但读不清内容」的区间。
  static Color glass(BuildContext context) => isDark(context)
      ? const Color(0xFF151C18).withValues(alpha: 0.66)
      : Colors.white.withValues(alpha: 0.66);

  /// 玻璃的高光边：上缘一条比底色更亮的 0.5~1px，是"玻璃有厚度"的关键。
  static Color glassEdge(BuildContext context) => isDark(context)
      ? Colors.white.withValues(alpha: 0.10)
      : Colors.white.withValues(alpha: 0.9);

  /// 浅色强调底：底部导航选中块、chip 选中态、图标底。
  ///
  /// 2026-11-05：从写死的薄荷绿改成**由主色淡化**。四套配色里两套是紫/橙，
  /// 固定薄荷会在「薰衣草湖」下出现一块绿药丸，像上错了色。
  /// 薄荷主题下算出来是 #E7F2F0，和原来的 #E3F4EE 几乎一样。
  static Color mint(BuildContext context) {
    final b = brand(context);
    return isDark(context)
        ? Color.alphaBlend(b.withValues(alpha: 0.22), const Color(0xFF0E1512))
        : Color.alphaBlend(b.withValues(alpha: 0.10), Colors.white);
  }

  /// 分隔线
  static Color hairline(BuildContext context) =>
      isDark(context) ? const Color(0xFF26302B) : const Color(0xFFDEEAE5);

  /// 卡片阴影：**两层**，替代原来那圈 1px 硬边框。
  ///
  /// 2026-10-28：卡片一直用 `Border.all(hairline)` 收边，问题是 1px 实线会让卡片
  /// 看起来"贴"在纸面上（像表格格线），而没有"浮起来"的体积感。
  /// 现在改成两层：
  /// - 近距小阴影（blur 5 / y1）负责**界定边界**，干原来边框的活；
  /// - 远距大阴影（blur 18 / y5）负责**体积**，卡片才像一张纸压在另一张纸上。
  ///
  /// 浅色下阴影带一点绿（0x1A2E28）而不是纯黑 —— 纯黑配薄荷底会发灰发脏。
  static List<BoxShadow> cardShadow(BuildContext context) => isDark(context)
      ? [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.34),
              blurRadius: 5,
              offset: const Offset(0, 1)),
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.26),
              blurRadius: 18,
              offset: const Offset(0, 5)),
        ]
      : [
          BoxShadow(
              color: const Color(0xFF1A2E28).withValues(alpha: 0.055),
              blurRadius: 5,
              offset: const Offset(0, 1)),
          BoxShadow(
              color: const Color(0xFF1A2E28).withValues(alpha: 0.07),
              blurRadius: 18,
              offset: const Offset(0, 5)),
        ];

  static Color ink(BuildContext context) =>
      isDark(context) ? const Color(0xFFEDF1EF) : const Color(0xFF16211D);

  static Color inkSoft(BuildContext context) =>
      isDark(context) ? const Color(0xFFA5B0AA) : const Color(0xFF5E6E68);

  /// 最弱一级的文字：说明、副标题、时间戳。
  ///
  /// 2026-10-28 从 #87958F 加深到 #687771。原来它在白卡上只有 3.12:1、
  /// 在纸面上 2.90:1，而这一级承载的正是全 App 最小的一批字（10.5~11px），
  /// 阳光下基本读不了。现在白卡 4.70:1（达标）、纸面 4.37:1（差 0.13）。
  /// **这一级不要再往浅了调**：要更弱的信息用字号/字重表达，别退回浅灰。
  /// 落在纸面上的说明文字（不在 Panel 里的）请用 [inkSoft]，它在纸面上是 5.0:1。
  static Color inkFaint(BuildContext context) =>
      isDark(context) ? const Color(0xFF89958F) : const Color(0xFF687771);

  /// 旧代码用 Palette.primary（常量松石绿）。要让「配色方案」真正生效，
  /// 新代码统一用 brand(context) 取当前主题主色。
  static Color get primary => seed;

  static Color brand(BuildContext context) =>
      Theme.of(context).colorScheme.primary;

  /// 当前配色方案的大卡渐变（含深浅色压制）。
  static AppPaletteTheme paletteTheme(BuildContext context) =>
      Theme.of(context).extension<AppPaletteTheme>() ?? AppPaletteTheme.fallback;

  static LinearGradient gradient(BuildContext context) =>
      paletteTheme(context).gradient;

  /// 铺在渐变上的文字色：浅渐变是深墨、深渐变是白。
  /// **大卡里的所有字都要用它**，别再写死 `Colors.white`。
  static Color onGradient(BuildContext context) =>
      paletteTheme(context).onGradient;
}

/// 统一尺寸令牌。页面边距优先 12，组件间距优先 4/8/12。
class AppSpace {
  const AppSpace._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

class AppRadius {
  const AppRadius._();

  static const double control = 8;
  static const double card = 8;
  static const double sheet = 16;
  static const double pill = 999;

  /// 图标格的圆角，按尺寸给两档（2026-10-28）。
  ///
  /// 以前三种写法并存：40×40 的格子写死 10、34×34 的按 `size * 0.24` 算
  /// （34→8.2、40→9.6）、色条写 18。同样大小的格子在不同页面弧度不一样，
  /// 并排看不出，来回切页面就能感觉到"边缘软硬度"在变。
  static const double tileLg = 10; // 36 ~ 40 的图标格
  static const double tileSm = 8; // 28 ~ 34 的图标格

  /// 同心圆角：**嵌在圆角容器里、且距边 [inset] 的元素**，该用多大半径。
  ///
  /// 两个圆角不是「外层比内层大就行」——它们的圆心必须重合，
  /// 否则内层那圈会在四个角跟外层"错开"一点，看着像没对齐的抽屉。
  /// 数学上就是 `外层半径 - 间距`。
  ///
  /// 用在：底栏胶囊（外 24）+ 选中块（距边 7）→ 17；
  /// 弹层（外 16）+ 内卡片（距边 8）→ 8。
  static double inside(double outer, double inset) =>
      (outer - inset).clamp(0.0, outer);
}

/// 品牌字体族：抖音美好体（Douyin Sans Bold）。
///
/// ⚠️ 用之前先知道它的两个硬伤，别把整个 App 都换过去：
/// 1. **只有一个字重（700/Bold）**。正文用它，整页都是粗的，层次全丢，
///    而且小字号（10~12px）会糊成一团。
/// 2. **数字宽度不等**（'1' 是 415、'0' 是 585，差 40%），字体也没有
///    `tnum` 特性可以修正。金额列一旦用它，小数点会对不齐、滚动时数字会"跳"。
///
/// 所以只在大字号用（见 [buildTheme] 的 fontStyle 三档：
/// system / display（默认，标题用）/ all（全局，用户坚持时才开））。
class AppFont {
  const AppFont._();

  static const display = 'DouyinSans';
}

/// 排版刻度：照参考版的字号 / 字重 / 行高来定，全 App 一套。
///
/// 不再到处写 `fontSize: 13.5` 这种散值——散值会导致同类文字在不同页面
/// 差 0.5～1px，整体就显得毛糙。
///
/// [display] 非空时，给**标题级**的四个样式换上品牌字体：
/// displaySmall / headlineSmall / titleLarge / titleMedium。
/// 正文（body*）和标签（label*）故意不换 —— 见 [AppFont] 的说明。
TextTheme _typography(TextTheme base, {String? display}) {
  TextStyle s(TextStyle? src, double size, FontWeight w,
          {double height = 1.4, String? family}) =>
      (src ?? const TextStyle()).copyWith(
        fontSize: size,
        fontWeight: w,
        height: height,
        letterSpacing: 0,
        // 等宽数字（2026-10-28 全局加）：数字字形宽度一致，金额从 9 变 10、
        // 从 99 变 100 时不会整体左右"跳"一下。中文不受影响。
        // 之前只有 51 处手写了 tabularFigures，散落的计数/百分比会抖。
        fontFeatures: const [FontFeature.tabularFigures()],
        // family 为 null 时 copyWith 保持不变（不会清掉 base 上的字体）
        fontFamily: family,
      );

  return base.copyWith(
    displaySmall:
        s(base.displaySmall, 28, FontWeight.w700, height: 1.18, family: display),
    headlineSmall: s(base.headlineSmall, 20, FontWeight.w700,
        height: 1.25, family: display),
    titleLarge:
        s(base.titleLarge, 17, FontWeight.w600, height: 1.3, family: display),
    titleMedium: s(base.titleMedium, 14, FontWeight.w600,
        height: 1.32, family: display),
    bodyLarge: s(base.bodyLarge, 14, FontWeight.w400, height: 1.42),
    bodyMedium: s(base.bodyMedium, 13, FontWeight.w400, height: 1.4),
    bodySmall: s(base.bodySmall, 12, FontWeight.w400, height: 1.36),
    labelLarge: s(base.labelLarge, 12, FontWeight.w600, height: 1.3),
    labelSmall: s(base.labelSmall, 10.5, FontWeight.w500, height: 1.3),
  );
}

ThemeData buildTheme(
  Brightness brightness, {
  String paletteId = 'teal',
  Color? seedOverride,
  String fontStyle = 'display',
}) {
  final scheme = ColorScheme.fromSeed(
    // seedOverride 来自首页封面的取色（见 core/cover_palette.dart）；
    // 有它就优先，没有就回到用户手选的配色方案。
    seedColor: seedOverride ?? (kPalettes[paletteId] ?? kPalettes['teal']!).seed,
    brightness: brightness,
    // fidelity：让 primary 尽量贴近 seed。默认的 tonalSpot 会把种色洗淡
    // （松石绿在默认变体下会变成发灰的蓝绿，四套配色看着都一样）。
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final isDark = brightness == Brightness.dark;
  // fontStyle：
  // - 'system'  系统字体（Roboto / PingFang），数字最规整
  // - 'display' 标题用美好体、正文和金额用系统（默认，推荐）
  // - 'all'     全局美好体（单字重 + 数字不等宽，只在用户坚持时用）
  final allBrand = fontStyle == 'all';
  final brandOnTitles = fontStyle == 'display' || allBrand;
  final baseTheme = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    // 全局 fontFamily：只有 'all' 档才设，其余为 null（系统字体）
    fontFamily: allBrand ? AppFont.display : null,
  );
  final paper = isDark ? const Color(0xFF0E1512) : const Color(0xFFF2F8F5);

  // 大卡 / 按钮用的渐变。
  // - 封面取色优先（seedOverride）：用封面主色到它的加深版
  // - 深色模式：整体压暗，否则浅紫/薄荷在大黑底上是一块发光的塑料
  final def = kPalettes[paletteId] ?? kPalettes['teal']!;
  var stops = List<Color>.from(def.gradient);
  if (seedOverride != null) {
    stops = [seedOverride, Color.lerp(seedOverride, Colors.black, 0.35)!];
  }
  if (isDark) {
    // 0.55 而不是 0.45：薄荷那条青柠端压 45% 时白字只有 4.33:1，
    // 差一点点不达标（大卡上 28px 金额看着就会发虚）。
    stops = [for (final c in stops) Color.lerp(c, Colors.black, 0.55)!];
  }
  final paletteTheme = AppPaletteTheme(
    paletteId: def.name,
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: stops,
    ),
    onGradient: _onGradient(stops),
  );

  return baseTheme.copyWith(
    extensions: [paletteTheme],
    textTheme: _typography(
      baseTheme.textTheme,
      display: brandOnTitles ? AppFont.display : null,
    ),
    scaffoldBackgroundColor: paper,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      // 48 和四个 tab 的 TabHeader（也是 48）对齐。
      // 以前是 52：从 tab 点进账户详情时标题会往下跳 4px，属于那种
      // "说不上哪里变了但感觉晃了一下"的细节。
      toolbarHeight: 48,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        // AppBar 标题始终是"标题级"，跟着品牌字体走
        fontFamily: brandOnTitles ? AppFont.display : null,
        color: isDark ? const Color(0xFFEDF1EF) : const Color(0xFF16211D),
      ),
    ),
    cardTheme: CardThemeData(
      color: isDark ? const Color(0xFF171D1A) : Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: isDark ? const Color(0xFF26302B) : const Color(0xFFDEEAE5),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      // 输入框底也带一点薄荷，和整体纸色是一个色系
      fillColor: isDark ? const Color(0xFF222925) : const Color(0xFFEDF5F2),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
        borderSide: BorderSide.none,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.all(8),
        visualDensity: VisualDensity.compact,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        // 底色交给 backgroundBuilder 画渐变，这里必须是透明的。
        // 前景色跟渐变走：浅渐变用深墨字，深渐变用白字，否则按钮上的字读不出来。
        backgroundColor: Colors.transparent,
        foregroundColor: paletteTheme.onGradient,
        disabledBackgroundColor: Colors.transparent,
        disabledForegroundColor: scheme.onSurface.withValues(alpha: 0.38),
      ).copyWith(
        // 全 App 40 个 FilledButton 一次性拿到渐变，不用逐个改调用点。
        backgroundBuilder: (context, states, child) {
          final disabled = states.contains(WidgetState.disabled);
          final fill = disabled
              ? [
                  scheme.onSurface.withValues(alpha: 0.10),
                  scheme.onSurface.withValues(alpha: 0.10),
                ]
              : stops;
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: fill,
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: child,
          );
        },
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
      ),
    ),
    listTileTheme: const ListTileThemeData(
      visualDensity: VisualDensity.compact,
      minVerticalPadding: 4,
      contentPadding: EdgeInsets.symmetric(horizontal: 12),
    ),
    chipTheme: baseTheme.chipTheme.copyWith(
      // ⚠️ color 必须写：ChipThemeData.labelStyle 一旦非空，就会**整个替换**
      // M3 默认的 labelStyle（默认那条自带颜色）。只剩字号/字重、没有颜色时，
      // Text 就落到引擎的 ui.TextStyle 默认色 —— 白色。
      // 现象：白底白字，选中态浅色底也几乎看不见（搜索页筛选条就是这样瞎的）。
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        color: isDark ? const Color(0xFFEDF1EF) : const Color(0xFF17201C),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(color: isDark ? const Color(0xFF29312D) : const Color(0xFFE3E8E5)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
    ),
  );
}
