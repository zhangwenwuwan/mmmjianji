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
  static const expense = Color(0xFFD0524A);
  static const income = Color(0xFF178A68);

  /// 提醒色（预算接近上限、额度紧张）。原来各页面自己写 0xFFE0A458，
  /// 改一处得改多处，统一到令牌。
  static const warn = Color(0xFFE0A458);

  static bool isDark(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark;

  /// 纸张底色（浅灰，衬托纯白卡片）
  static Color paper(BuildContext context) =>
      isDark(context) ? const Color(0xFF0F1412) : const Color(0xFFF4F6F5);

  /// 卡片
  static Color card(BuildContext context) =>
      isDark(context) ? const Color(0xFF171D1A) : Colors.white;

  /// 分隔线
  static Color hairline(BuildContext context) =>
      isDark(context) ? const Color(0xFF29312D) : const Color(0xFFE3E8E5);

  static Color ink(BuildContext context) =>
      isDark(context) ? const Color(0xFFEDF1EF) : const Color(0xFF17201C);

  static Color inkSoft(BuildContext context) =>
      isDark(context) ? const Color(0xFFA5B0AA) : const Color(0xFF64716B);

  static Color inkFaint(BuildContext context) =>
      isDark(context) ? const Color(0xFF89958F) : const Color(0xFF87928C);

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
}

/// 排版刻度：照参考版的字号 / 字重 / 行高来定，全 App 一套。
///
/// 不再到处写 `fontSize: 13.5` 这种散值——散值会导致同类文字在不同页面
/// 差 0.5～1px，整体就显得毛糙。字体族沿用系统默认（Android Roboto /
/// iOS PingFang），CJK 由系统回落，避免为了换字形打包几 MB 字体。
TextTheme _typography(TextTheme base) {
  TextStyle s(TextStyle? src, double size, FontWeight w,
          {double height = 1.4}) =>
      (src ?? const TextStyle()).copyWith(
        fontSize: size,
        fontWeight: w,
        height: height,
        letterSpacing: 0,
      );

  return base.copyWith(
    displaySmall: s(base.displaySmall, 28, FontWeight.w700, height: 1.18),
    headlineSmall: s(base.headlineSmall, 20, FontWeight.w700, height: 1.25),
    titleLarge: s(base.titleLarge, 17, FontWeight.w600, height: 1.3),
    titleMedium: s(base.titleMedium, 14, FontWeight.w600, height: 1.32),
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
  final baseTheme = ThemeData(useMaterial3: true, colorScheme: scheme);
  return baseTheme.copyWith(
    textTheme: _typography(baseTheme.textTheme),
    scaffoldBackgroundColor:
        isDark ? const Color(0xFF0F1412) : const Color(0xFFF4F6F5),
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor:
          isDark ? const Color(0xFF0F1412) : const Color(0xFFF4F6F5),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      toolbarHeight: 52,
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: isDark ? const Color(0xFFEDF1EF) : const Color(0xFF17201C),
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
      color: isDark ? const Color(0xFF29312D) : const Color(0xFFE3E8E5),
      thickness: 1,
      space: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: isDark ? const Color(0xFF222925) : const Color(0xFFF0F3F1),
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
