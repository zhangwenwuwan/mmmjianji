import 'package:flutter/material.dart';

/// 简记的视觉基调：米纸底 + 松石绿主色 + 朱红支出 / 青绿收入。
/// 全部自己定义，不依赖任何外部设计资源。
/// 配色方案（只换主色，其他语义色不变，保证对比度可控）
const Map<String, ({String name, Color seed, Color expense, Color income})>
    kPalettes = {
  'teal': (
    name: '薄荷',
    seed: Color(0xFF0E7C66),
    expense: Color(0xFFD0524A),
    income: Color(0xFF178A68)
  ),
  'indigo': (
    name: '墨蓝',
    seed: Color(0xFF2B5C8A),
    expense: Color(0xFFC25B54),
    income: Color(0xFF2E8AA6)
  ),
  'ochre': (
    name: '赭石',
    seed: Color(0xFFB4652A),
    expense: Color(0xFFB3402F),
    income: Color(0xFF7A8C3A)
  ),
  'rose': (
    name: '玫红',
    seed: Color(0xFFB23A64),
    expense: Color(0xFFC0392B),
    income: Color(0xFF4E9A7E)
  ),
};

class Palette {
  const Palette._();

  static const seed = Color(0xFF0E7C66);

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

  /// 薄荷浅底：chip 选中态、图标底、强调块的背景。
  static Color mint(BuildContext context) =>
      isDark(context) ? const Color(0xFF14322A) : const Color(0xFFE3F4EE);

  /// 分隔线
  static Color hairline(BuildContext context) =>
      isDark(context) ? const Color(0xFF26302B) : const Color(0xFFDEEAE5);

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
  return baseTheme.copyWith(
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
