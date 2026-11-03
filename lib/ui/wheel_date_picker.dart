import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/rules.dart';
import 'motion.dart';
import 'theme.dart';

/// 滚轮能选到的最大年份。
///
/// 2026-10-26 用户要求：原来只到「明年」（2027），选不了更远的日期。
/// 记账里远期并不常见（还贷、储蓄目标、预收房租会用到），
/// 但**选不到**比"多滚两下"难受得多，所以直接给到 2099。
/// 滚轮是懒加载的 builder，项数从 32 涨到 104 不会有任何性能代价。
const int kWheelMaxYear = 2099;

/// 年 / 月 /（可选）日 三列滚轮选择器。
///
/// 为什么换掉原来那套「年份胶囊网格 + 月份网格」：
/// 原来年份是一排胶囊，从 2026 排到 1999 共 28 个，**要滚动好几屏**才能找到
/// 2019 年；月份又是另一个 4×3 网格，两块割裂，还得按「确定」。
/// 滚轮是 iOS/Android 通用的心智模型：上下滚、当前项停在中间放大。
///
/// 年份轮的范围是 [minYear]~[maxYear]（默认今年 -30 ~ 2099，见 [kWheelMaxYear]），
/// 打开就直接停在当前选中的年份上，不用先滚过去。
///
/// 日轮只在 [includeDay] 时出现，且**天数跟着年月联动**：
/// 1 月 31 日切到 2 月要变成 28 日，2 月 29 日切到平年要变成 28 日。
class WheelDateSheet extends StatefulWidget {
  const WheelDateSheet({
    super.key,
    required this.initial,
    this.includeDay = false,
    this.title,
    this.minYear,
    this.maxYear,
  });

  final DateTime initial;

  /// 是否显示「日」轮
  final bool includeDay;
  final String? title;
  final int? minYear;
  final int? maxYear;

  @override
  State<WheelDateSheet> createState() => _WheelDateSheetState();
}

class _WheelDateSheetState extends State<WheelDateSheet> {
  late int _year = widget.initial.year;
  late int _month = widget.initial.month;
  late int _day = widget.initial.day;

  late final int _minYear;
  late final int _maxYear;
  late final FixedExtentScrollController _yearCtl;
  late final FixedExtentScrollController _monthCtl;
  late final FixedExtentScrollController _dayCtl;

  /// 年份轮项数
  int get _yearCount => _maxYear - _minYear + 1;

  /// 月份轮项数：整个年份区间 × 12，月份才能跨年连着滚。
  int get _monthCount => _yearCount * 12;

  /// 当前年月在连续月份轴上的下标
  int get _monthIndex =>
      monthAxisIndex(_year, _month, _minYear).clamp(0, _monthCount - 1);

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _minYear = widget.minYear ?? now.year - 30;
    _maxYear = widget.maxYear ?? kWheelMaxYear;
    _yearCtl = FixedExtentScrollController(
        initialItem: (_year - _minYear).clamp(0, _yearCount - 1));
    _monthCtl = FixedExtentScrollController(initialItem: _monthIndex);
    _dayCtl = FixedExtentScrollController(initialItem: _day - 1);
  }

  @override
  void dispose() {
    _yearCtl.dispose();
    _monthCtl.dispose();
    _dayCtl.dispose();
    super.dispose();
  }

  int get _maxDay => daysInMonth(DateTime(_year, _month));

  /// 年或月变了，先把「日」夹到合法范围，再重建日轮。
  ///
  /// 顺序很重要：jumpToItem 必须在 setState **之前**调用 ——
  /// 那一刻旧轮子的项数还是多的，跳到合法下标不会越界；
  /// 换完再 setState，日轮按新天数重建。
  void _clampDay() {
    final newDay = clampDayOfMonth(_day, _year, _month);
    if (newDay != _day) {
      _day = newDay;
      // includeDay=false 时没有「日」轮，控制器从未挂载；这时候 jumpToItem
      // 会抛 "ScrollController not attached"。只更新 _day 就够了。
      if (_dayCtl.hasClients) _dayCtl.jumpToItem(newDay - 1);
    }
  }

  void _onYear(int index) {
    final y = _minYear + index;
    if (y == _year) return;
    setState(() {
      _year = y;
      _clampDay();
    });
    // 月份轮按绝对下标定位，切年份时必须把它挪到同年同月的位置，
    // 否则月份轮会停在旧年份的那一格（显示出来的月份和 _month 对不上）。
    _syncMonthWheel();
  }

  /// 月份轮滚动：下标是连续的，滚过 12 月就自然进下一年。
  void _onMonth(int index) {
    final at = monthAxisAt(index, _minYear);
    if (at.year == _year && at.month == _month) return;
    setState(() {
      _year = at.year;
      _month = at.month;
      _clampDay();
    });
    // 年份轮跟着跳。用 jumpToItem 而不是 animateToItem：
    // 用户手指还在月份轮上，年份这时做动画会两边都抖。
    final yi = (at.year - _minYear).clamp(0, _yearCount - 1);
    if (_yearCtl.selectedItem != yi) _yearCtl.jumpToItem(yi);
  }

  /// 把月份轮挪到当前 _year/_month 对应的位置。
  ///
  /// ⚠️ jumpToItem 会走一遍滚动回调，_onMonth 里「年月都没变就 return」的
  /// 判断正好挡住回环 —— 别把那句删了。
  void _syncMonthWheel() {
    final mi = _monthIndex;
    if (_monthCtl.selectedItem != mi) _monthCtl.jumpToItem(mi);
  }

  void _onDay(int index) {
    final d = index + 1;
    if (d == _day) return;
    setState(() => _day = d);
  }

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    final hairline = Palette.hairline(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: brand.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.event_outlined, size: 16, color: brand),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title ?? '选择日期',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: brand),
                  ),
                ),
                Text(
                  widget.includeDay
                      ? '$_year 年 $_month 月 $_day 日'
                      : '$_year 年 $_month 月',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700, color: brand),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 180,
            decoration: BoxDecoration(
              color: Palette.paper(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: hairline),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _WheelColumn(
                    controller: _yearCtl,
                    count: _yearCount,
                    selectedIndex: _year - _minYear,
                    labelBuilder: (i) => '${_minYear + i} 年',
                    onChanged: _onYear,
                  ),
                ),
                Container(width: 1, height: 120, color: hairline),
                Expanded(
                  child: _WheelColumn(
                    controller: _monthCtl,
                    count: _monthCount,
                    selectedIndex: _monthIndex,
                    // 连续月份轴：只显示 1~12，但下标是跨年连续的，
                    // 所以 26 年 12 月往下滚一格就是 27 年 1 月。
                    labelBuilder: (i) => '${monthAxisAt(i, _minYear).month} 月',
                    onChanged: _onMonth,
                  ),
                ),
                if (widget.includeDay) ...[
                  Container(width: 1, height: 120, color: hairline),
                  Expanded(
                    child: _WheelColumn(
                      controller: _dayCtl,
                      count: _maxDay,
                      selectedIndex: _day - 1,
                      labelBuilder: (i) => '${i + 1} 日',
                      onChanged: _onDay,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(
                widget.includeDay
                    ? DateTime(_year, _month, _day)
                    : DateTime(_year, _month),
              ),
              child: const Text('确定'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一列滚轮。控制器由父级持有 —— 日轮的天数会变，
/// 控制器在重建时复用（靠 jumpToItem 夹下标），不重新创建。
///
/// 2026-10-26 体验增强：从 `CupertinoPicker.builder` 换成 `ListWheelScrollView`。
/// 理由：CupertinoPicker 把 3D 参数（perspective 等）写死，做不出明显的圆柱弯曲；
/// ListWheelScrollView 能直接调 diameterRatio / perspective / squeeze，
/// 再配合逐项 AnimatedBuilder 做「越远离中心越小越透明」。
///
/// 手指拖动跟手、松手惯性减速、吸附到最近一格，都是 `FixedExtentScrollPhysics`
/// 自带的；「咔哒感」靠 onSelectedItemChanged 里补一次 HapticFeedback。
///
/// ⚠️ 用 `ListWheelChildBuilderDelegate(childCount: count)` 明确给定项数，
/// 结构上就杜绝了当年「滚出 13 月」的无限列表问题（CupertinoPicker.builder
/// 没有 childCount，越界还会继续渲，只能靠 return null 掐断）。
class _WheelColumn extends StatelessWidget {
  const _WheelColumn({
    required this.controller,
    required this.count,
    required this.selectedIndex,
    required this.labelBuilder,
    required this.onChanged,
  });

  /// 一行的高度。3D 圆柱直径、选中带高度都以它为基准。
  static const double itemExtent = 40;

  final FixedExtentScrollController controller;
  final int count;
  final int selectedIndex;
  final String Function(int index) labelBuilder;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    final faint = Palette.inkFaint(context);

    // 用 CupertinoPicker：选中带（selectionOverlay）由框架画在文字**底下**，
    // 选中项由框架按真实几何判定，不会出现「自绘带子盖住选中行 / 高亮错一格」。
    // 3D 圆柱靠 diameterRatio（越小越弯）+ squeeze/magnification 体现；
    // 跟手、惯性、吸附到最近一格由 CupertinoPicker 内部的
    // FixedExtentScrollPhysics 提供；咔哒感我们在 onSelectedItemChanged 里补。
    return CupertinoPicker.builder(
      scrollController: controller,
      itemExtent: itemExtent,
      diameterRatio: 1.05,
      squeeze: 1.08,
      magnification: 1.14,
      useMagnifier: true,
      selectionOverlay: CupertinoPickerDefaultSelectionOverlay(
        background: brand.withValues(alpha: 0.08),
      ),
      onSelectedItemChanged: (i) {
        if (i < 0 || i >= count) return;
        HapticFeedback.selectionClick();
        onChanged(i);
      },
      itemBuilder: (ctx, i) {
        // CupertinoPicker.builder 是无限列表，越界必须 return null 掐断，
        // 否则会渲染出「13 月」那种鬼东西。
        if (i < 0 || i >= count) return null;
        final sel = i == selectedIndex;
        return Center(
          child: Text(
            labelBuilder(i),
            style: TextStyle(
              fontSize: 14,
              height: 1.2,
              fontWeight: sel ? FontWeight.w700 : FontWeight.w400,
              color: sel ? brand : faint,
            ),
          ),
        );
      },
    );
  }
}

/// 弹出滚轮日期选择器。返回 null = 用户取消。
Future<DateTime?> pickDateWheel(
  BuildContext context,
  DateTime initial, {
  bool includeDay = false,
  String? title,
}) async {
  return showAppSheet<DateTime>(
    context: context,
    title: title,
    scrollable: false,
    builder: (ctx) => WheelDateSheet(
      initial: initial,
      includeDay: includeDay,
      title: title,
    ),
  );
}

/// 日期快捷选择：**今天 / 昨天 / 前天 / 其它（滚轮）**。返回 null = 取消。
///
/// 为什么要有：早上补记「昨天」是最常见的场景之一，以前点日期就弹滚轮，
/// 从今天滑到昨天要滑两三下；跨月、跨年时更远。
/// 三行快捷 + 一行「其它日期」兜住剩下的情况，滚轮只在真需要时才出现。
Future<DateTime?> pickDayQuick(
  BuildContext context,
  DateTime current, {
  String title = '选择日期',
}) async {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  String sub(DateTime d) =>
      '${d.month} 月 ${d.day} 日 · 周${'一二三四五六日'[d.weekday - 1]}';

  final choice = await showAppSheet<int>(
    context: context,
    title: title,
    builder: (ctx) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++)
          ListTile(
            dense: true,
            title: Text(['今天', '昨天', '前天'][i]),
            subtitle: Text(sub(today.subtract(Duration(days: i))),
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(ctx))),
            trailing: dayKey(current) ==
                    dayKey(today.subtract(Duration(days: i)))
                ? const Icon(Icons.check, size: 18)
                : null,
            onTap: () => Navigator.pop(ctx, i),
          ),
        ListTile(
          dense: true,
          leading: const Icon(Icons.calendar_month_outlined, size: 18),
          title: const Text('其它日期…'),
          onTap: () => Navigator.pop(ctx, -1),
        ),
      ],
    ),
  );
  if (choice == null || !context.mounted) return null;
  if (choice < 0) {
    return pickDateWheel(context, current, includeDay: true, title: title);
  }
  return today.subtract(Duration(days: choice));
}

/// 只选年份的单列滚轮（统计页「年」口径用）。返回 null = 取消。
Future<int?> pickWheelYear(
  BuildContext context,
  int initial, {
  String? title,
  int? minYear,
  int? maxYear,
}) async {
  final now = DateTime.now();
  final lo = minYear ?? now.year - 30;
  final hi = maxYear ?? kWheelMaxYear;
  return showAppSheet<int>(
    context: context,
    title: title,
    scrollable: false,
    builder: (ctx) => _YearSheet(
      initial: initial.clamp(lo, hi),
      minYear: lo,
      maxYear: hi,
      title: title,
    ),
  );
}

class _YearSheet extends StatefulWidget {
  const _YearSheet({
    required this.initial,
    required this.minYear,
    required this.maxYear,
    this.title,
  });

  final int initial;
  final int minYear;
  final int maxYear;
  final String? title;

  @override
  State<_YearSheet> createState() => _YearSheetState();
}

class _YearSheetState extends State<_YearSheet> {
  late int _year = widget.initial;
  late final FixedExtentScrollController _ctl =
      FixedExtentScrollController(initialItem: _year - widget.minYear);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    final count = widget.maxYear - widget.minYear + 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: brand.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Icon(Icons.event_outlined, size: 16, color: brand),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title ?? '选择年份',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: brand),
                  ),
                ),
                Text('$_year 年',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: brand)),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            height: 180,
            decoration: BoxDecoration(
              color: Palette.paper(context),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Palette.hairline(context)),
            ),
            child: _WheelColumn(
              controller: _ctl,
              count: count,
              selectedIndex: _year - widget.minYear,
              labelBuilder: (i) => '${widget.minYear + i} 年',
              onChanged: (i) => setState(() => _year = widget.minYear + i),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.of(context).pop(_year),
              child: const Text('确定'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 年月滚轮（保持旧名字，调用点零改动）。
Future<DateTime?> pickWheelYearMonth(BuildContext context, DateTime initial) =>
    pickDateWheel(context, initial, includeDay: false, title: '选择年月');

/// 供外部复用：把「选择年月」的默认年份范围收窄到最近 N 年。
int yearOptionsFrom(int now) => math.max(1, now - 30);

/// 年月 → **连续月份轴**的下标。
///
/// 2026-10-26 修的 bug：月份轮原来只有 12 项、死循环式地显示 `i+1`，
/// 而 `CupertinoPicker.builder` 是**无限列表**（它没有 childCount 参数），
/// 于是能一路滚出「13 月」「20 月」。
///
/// 现在月份轮按"从 minYear 年 1 月开始的第几个月"连续编号：
/// 2026 年 12 月再往下滑 = 2027 年 1 月（年份自动 +1），
/// 2026 年 1 月往上滑 = 2025 年 12 月（年份自动 -1）。
int monthAxisIndex(int year, int month, int minYear) =>
    (year - minYear) * 12 + (month - 1);

/// 轴下标 → 年月（[monthAxisIndex] 的逆运算）。月份为 1~12。
({int year, int month}) monthAxisAt(int index, int minYear) =>
    (year: minYear + index ~/ 12, month: index % 12 + 1);
