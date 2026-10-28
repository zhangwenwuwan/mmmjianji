import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/holiday_calendar.dart';
import '../core/lunar.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'ledger_page.dart';
import 'motion.dart';
import 'theme.dart';

/// 日历视图：一个月一屏，格子里显示当天收支 + 农历，点开看当天明细。
///
/// ## 版式（1.4.5 照一木记账 6.7 重排）
///
/// 上一版被说「丑」，对照一木后发现不是配色问题，是**视觉重心排错了**：
///
/// 1. 一条只有「日历」两个字的 AppBar 白占 56pt，而真正有用的年月被赶到
///    第二行，还带着左右箭头 + 「今天」胶囊，横向三组元素互相抢。
///    → 现在年月直接做页面大标题，AppBar 不要了。
/// 2. 收入/支出/结余做成三个卡格里 14pt 加粗数字，体量压过月份标题，
///    眼睛第一下落在「¥0」上而不是「几月」。
///    → 现在压成标题下一行 11pt 小字，只给一个基准，不抢戏。
/// 3. 格子 `childAspectRatio: 0.72` 又塞了日期 + 农历 + 金额 + 休班角标
///    四层信息，撑得很高（6 行占掉大半屏），行内留白还特别空。
///    → 现在固定 54 高、两行内容：日期 + 一行副标题。
///      **有账时副标题让位给金额**——一木也是这么干的（它 10/24 那格
///      就是日期下面是 -25 / +500，农历被挤掉）。
/// 4. 周一起始。国内日历习惯、一木也是周日起始 → 改周日。
/// 5. 底部一个 Panel 卡片 + 两行说明书式文案（「格子里的数字是当天支出
///    和收入…」）。这是写给开发看的，不是给用户看的 → 删掉。
class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  late DateTime _selectedDay = DateTime.now();

  /// 日历现在是**从首页右上角点进来**的独立页面（不再占一个底部 tab），
  /// 所以每次进来都是一个新实例 → 直接在 initState 里定位到今天。
  ///
  /// 之前放在 tab 里时是"隔天复位"（IndexedStack 保状态，靠 epoch 通知）；
  /// 现在没有保状态的需求了，进来就是今天最符合直觉。
  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(monthProvider.notifier).state = DateTime(now.year, now.month);
    });
  }

  DateTime _effective(DateTime month) =>
      (_selectedDay.year == month.year && _selectedDay.month == month.month)
          ? DateTime(_selectedDay.year, _selectedDay.month, _selectedDay.day)
          : DateTime(month.year, month.month, 1);

  void _goToday() {
    final now = DateTime.now();
    setState(() {
      ref.read(monthProvider.notifier).state = DateTime(now.year, now.month);
      _selectedDay = DateTime(now.year, now.month, now.day);
    });
  }

  void _shiftMonth(int delta) {
    final m = shiftMonth(ref.read(monthProvider), delta);
    ref.read(monthProvider.notifier).state = m;
  }

  Future<void> _pickMonth() async {
    final m = await pickYearMonth(context, ref.read(monthProvider));
    if (m == null || !mounted) return;
    ref.read(monthProvider.notifier).state = m;
  }

  Future<void> _openMenu() async {
    final settings = ref.read(settingsProvider);
    final hide = settings.hideAmounts;
    final action = await showAppSheet<String>(
      context: context,
      title: '日历',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(Icons.today_outlined,
                size: 18, color: Palette.inkSoft(ctx)),
            title: const Text('回到今天'),
            onTap: () => Navigator.pop(ctx, 'today'),
          ),
          ListTile(
            leading: Icon(Icons.event_outlined,
                size: 18, color: Palette.inkSoft(ctx)),
            title: const Text('选择年月'),
            onTap: () => Navigator.pop(ctx, 'month'),
          ),
          ListTile(
            leading: Icon(
                hide ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                size: 20,
                color: Palette.inkSoft(ctx)),
            title: Text(hide ? '显示金额' : '隐藏金额'),
            onTap: () => Navigator.pop(ctx, 'hide'),
          ),
        ],
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'today':
        _goToday();
      case 'month':
        await _pickMonth();
      case 'hide':
        await ref.read(settingsProvider.notifier).setHideAmounts(!hide);
    }
  }

  @override
  Widget build(BuildContext context) {
    final month = ref.watch(monthProvider);
    final dailyAsync = ref.watch(dailyTotalsProvider);
    final monthEntriesAsync = ref.watch(entriesProvider);
    final totals = ref.watch(totalsProvider).valueOrNull ??
        (incomeCents: 0, expenseCents: 0);
    final settings = ref.watch(settingsProvider);
    final selected = _effective(month);
    final selectedEntries = monthEntriesAsync.whenData(
      (entries) => entries
          .where((e) =>
              e.day.year == selected.year &&
              e.day.month == selected.month &&
              e.day.day == selected.day)
          .toList(),
    );

    return Scaffold(
      // 一木整页是浅底 + 白卡，简记的 paper/card 正好同构：
      // 日历自己不套卡片（套了就像"挂在页面上的一个组件"），
      // 只有下方流水是一张白卡。
      backgroundColor: Palette.paper(context),
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context, month, settings, totals),
            const SizedBox(height: 2),
            _weekHeader(context),
            dailyAsync.when(
              skipLoadingOnReload: true,
              loading: () => const SizedBox(
                height: 240,
                child: Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
              error: (e, _) => SizedBox(
                height: 200,
                child: Center(child: LoadError(error: e)),
              ),
              data: (byDay) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  children: _rows(byDay, month, selected, settings),
                ),
              ),
            ),
            Expanded(
              child: _DayEntriesPanel(
                day: selected,
                entriesAsync: selectedEntries,
                incomeCents: dailyAsync.valueOrNull?[dayKey(selected)]
                        ?.incomeCents ??
                    0,
                expenseCents: dailyAsync.valueOrNull?[dayKey(selected)]
                        ?.expenseCents ??
                    0,
                settings: settings,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 头部 ────────────────────────────────────────────────────────────────

  Widget _header(
    BuildContext context,
    DateTime month,
    AppSettings settings,
    ({int incomeCents, int expenseCents}) totals,
  ) {
    final net = totals.incomeCents - totals.expenseCents;
    final brand = Palette.brand(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 4, 6, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _iconBtn(context, Icons.arrow_back_rounded,
                  tooltip: '返回',
                  size: 21,
                  onTap: () => Navigator.of(context).maybePop()),
              const SizedBox(width: 2),
              PressScale(
                scale: 0.97,
                onTap: _pickMonth,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 「2026年10月」不补零，和系统日历/一木一致
                    Text(
                      '${month.year}年${month.month}月',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: Palette.ink(context),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.expand_more,
                        size: 18, color: Palette.inkFaint(context)),
                  ],
                ),
              ),
              const Spacer(),
              _iconBtn(context, Icons.chevron_left,
                  tooltip: '上个月',
                  onTap: () => _shiftMonth(-1)),
              const SizedBox(width: 3),
              _iconBtn(context, Icons.chevron_right,
                  tooltip: '下个月', onTap: () => _shiftMonth(1)),
              const SizedBox(width: 3),
              _iconBtn(context, Icons.today_outlined,
                  tooltip: '回到今天', color: brand, onTap: _goToday),
              _iconBtn(context, Icons.more_horiz,
                  tooltip: '更多', onTap: _openMenu),
            ],
          ),
          // 汇总：一木把它压成标题下一行小字（`收 0.00 支 0.00 余 0.00`）。
          // 上一版是三个卡格里的 14pt 加粗，比月份标题还抢眼。
          Padding(
            padding: const EdgeInsets.only(left: 38, top: 1, bottom: 2),
            child: Wrap(
              spacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _sumText(context, '收', totals.incomeCents, Palette.income,
                    settings, 'in'),
                _sumText(context, '支', totals.expenseCents, Palette.expense,
                    settings, 'out'),
                _sumText(
                    context,
                    '余',
                    net,
                    net >= 0 ? Palette.inkSoft(context) : Palette.expense,
                    settings,
                    ''),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sumText(
    BuildContext context,
    String label,
    int cents,
    Color color,
    AppSettings settings,
    String flow,
  ) {
    // 收/支用正负号表达方向，数值取绝对值；结余本身就是有符号的净额，
    // 必须原样保留 —— 之前这里也套了 abs()，导致「支出 12、结余 -12」
    // 被写成「余 12」，账看着像凭空多了 12 块。
    final String text;
    if (settings.hideAmounts) {
      text = '****';
    } else if (flow.isEmpty) {
      text = centsToText(cents);
    } else if (cents == 0) {
      // 0 前面挂个 +0 / -0 是纯噪音（月初、没收入的日子天天见）
      text = centsToText(0);
    } else {
      text = '${flow == 'in' ? '+' : '-'}${centsToText(cents.abs())}';
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _weekHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
      child: Row(
        children: [
          for (final w in const ['日', '一', '二', '三', '四', '五', '六'])
            Expanded(
              child: Center(
                child: Text(
                  w,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: Palette.inkFaint(context),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── 网格 ────────────────────────────────────────────────────────────────

  List<Widget> _rows(
    Map<String, ({int incomeCents, int expenseCents})> byDay,
    DateTime month,
    DateTime selected,
    AppSettings settings,
  ) {
    final total = daysInMonth(month);
    // 周日起始：DateTime.weekday 里 周日 = 7，取模 7 正好落到 0 列
    final lead = DateTime(month.year, month.month, 1).weekday % 7;
    final rows = <Widget>[];
    var cells = <Widget>[];

    for (var i = 0; i < lead; i++) {
      cells.add(const Expanded(child: SizedBox(height: _cellHeight)));
    }

    for (var d = 1; d <= total; d++) {
      final day = DateTime(month.year, month.month, d);
      final t = byDay[dayKey(day)] ?? (incomeCents: 0, expenseCents: 0);
      final lunar = solarToLunar(day);
      final holiday = holidayOf(day);
      cells.add(Expanded(
        child: _DayCell(
          day: d,
          incomeCents: t.incomeCents,
          expenseCents: t.expenseCents,
          subtitle: _subtitleOf(day, holiday, lunar),
          // 调休上班日：日期数字染橙。上一版是右上角「班」角标，
          // 在 51pt 宽的格子里挤成一小坨，是「脏」的主要来源之一。
          workday: holiday?.kind == HolidayKind.work,
          weekend: day.weekday == DateTime.saturday ||
              day.weekday == DateTime.sunday,
          isToday: _isToday(day),
          selected: _sameDay(day, selected),
          hide: settings.hideAmounts,
          onTap: () => setState(() => _selectedDay = day),
        ),
      ));
      if (cells.length == 7) {
        rows.add(Row(children: cells));
        cells = <Widget>[];
      }
    }

    if (cells.isNotEmpty) {
      while (cells.length < 7) {
        cells.add(const Expanded(child: SizedBox(height: _cellHeight)));
      }
      rows.add(Row(children: cells));
    }
    return rows;
  }

  static const double _cellHeight = 48;

  /// 格子里的那行小字。
  ///
  /// 优先级：假期/节日名 > 节气 > 农历日。但有两个例外，都是为了少点噪音：
  ///
  /// 1. **连续假期只在第一天报名字**。官方表里 10/1–10/7 每天都标着
  ///    `rest '国庆'`，照直渲染就是整排七个「国庆」，一眼看过去像渲染坏了；
  ///    一木也只在 10/1 写「国庆节」，2 号起回到「廿二/廿三」。
  /// 2. **调休上班日不报假期名**。10/10 标的是 `work '国庆'`，但那天是
  ///    去上班的，写「国庆」比不写更误导 —— 日期已经染橙表示调休了。
  static String _subtitleOf(DateTime day, HolidayDay? holiday, LunarDate lunar) {
    final label = calendarLabel(day);
    if (holiday != null && holiday.kind == HolidayKind.rest) {
      final prev = holidayOf(day.subtract(const Duration(days: 1)));
      final firstDay = prev == null ||
          prev.kind != HolidayKind.rest ||
          prev.label != holiday.label;
      if (firstDay) return holiday.label;
    }
    return label ?? lunarDayText(lunar.day);
  }

  static bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _iconBtn(
    BuildContext context,
    IconData icon, {
    VoidCallback? onTap,
    String? tooltip,
    Color? color,
    double size = 20,
  }) {
    final btn = PressScale(
      scale: 0.86,
      onTap: onTap,
      child: SizedBox(
        width: 32,
        height: 34,
        child: Center(
          child: Icon(icon, size: size, color: color ?? Palette.inkSoft(context)),
        ),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip, child: btn);
  }
}

/// 一格。
///
/// 结构固定两行：日期 + **一行副标题**。副标题平时是农历/节日，
/// 当天有账时让位给金额（支出 `-12` 在上、收入 `+300` 在下）。
/// 一木也是这个取舍——它的格子里看不到农历和金额同时出现。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.incomeCents,
    required this.expenseCents,
    required this.subtitle,
    required this.workday,
    required this.weekend,
    required this.isToday,
    required this.selected,
    required this.hide,
    required this.onTap,
  });

  final int day;
  final int incomeCents;
  final int expenseCents;
  final String subtitle;

  /// 调休上班日（本该休息的周末要上班）
  final bool workday;
  final bool weekend;
  final bool isToday;
  final bool selected;
  final bool hide;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    final hasMoney = expenseCents > 0 || incomeCents > 0;

    // 选中：实心品牌色 + 白字（一木的选中态）。
    // 上一版是 14% 透明底 + 55% 描边，在浅灰页面上像一块"脏斑"。
    final Color fg = selected
        ? Colors.white
        : workday
            ? Palette.warn
            : weekend
                ? brand
                : Palette.ink(context);
    final Color subFg = selected
        ? Colors.white.withValues(alpha: 0.85)
        : Palette.inkFaint(context);

    return PressScale(
      scale: 0.9,
      onTap: onTap,
      child: SizedBox(
        height: _CalendarPageState._cellHeight,
        child: Center(
          child: Container(
            width: 44,
            height: 44,
            decoration: selected
                ? BoxDecoration(
                    color: brand,
                    borderRadius: BorderRadius.circular(9),
                  )
                : null,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$day',
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.05,
                    fontWeight: (selected || isToday)
                        ? FontWeight.w700
                        : FontWeight.w500,
                    // 今天没选中时也染品牌色，否则"今天在哪"要靠找
                    color: isToday && !selected ? brand : fg,
                  ),
                ),
                const SizedBox(height: 2.5),
                if (hasMoney)
                  ..._moneyRows(context)
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 10.5,
                          height: 1.1,
                          color: subFg,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _moneyRows(BuildContext context) {
    // 一格里最多两行金额，1.05 行高 + 8.5 字号 ≈ 18pt，加上日期 17pt，
    // 50pt 的块还余 15pt 呼吸，不会把格子撑高。
    Widget row(int cents, bool out) {
      final text = out ? '-${_short(cents)}' : '+${_short(cents)}';
      return Text(
        hide ? '**' : text,
        maxLines: 1,
        style: TextStyle(
          fontSize: 10.5,
          height: 1.1,
          fontWeight: FontWeight.w600,
          color: selected
              ? Colors.white.withValues(alpha: 0.92)
              : (out ? Palette.expense : Palette.income),
        ),
      );
    }

    return [
      if (expenseCents > 0)
        FittedBox(fit: BoxFit.scaleDown, child: row(expenseCents, true)),
      if (incomeCents > 0)
        FittedBox(fit: BoxFit.scaleDown, child: row(incomeCents, false)),
    ];
  }

  /// 格子太窄，超过万就简写成 1.2万
  static String _short(int cents) {
    final yuan = cents / 100;
    if (yuan >= 10000) return '${(yuan / 10000).toStringAsFixed(1)}万';
    if (yuan >= 1000) return '${(yuan / 1000).toStringAsFixed(1)}k';
    return yuan.toStringAsFixed(yuan == yuan.roundToDouble() ? 0 : 1);
  }
}

/// 选中日的流水。
///
/// 一木这里是「日期 + 周几 + 收/支」一行标题，下面是白卡装的流水；
/// 没有账就不给卡片，直接空态插画 + 一句话。照搬。
class _DayEntriesPanel extends StatelessWidget {
  const _DayEntriesPanel({
    required this.day,
    required this.entriesAsync,
    required this.incomeCents,
    required this.expenseCents,
    required this.settings,
  });

  final DateTime day;
  final AsyncValue<List<Entry>> entriesAsync;
  final int incomeCents;
  final int expenseCents;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final hidden = settings.hideAmounts;

    return entriesAsync.when(
      skipLoadingOnReload: true,
      loading: () => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
      error: (error, _) => Center(
        child: Text(
          '读取当天流水失败：$error',
          style: const TextStyle(fontSize: 12, color: Palette.expense),
        ),
      ),
      data: (entries) {
        final head = _DayHead(
          day: day,
          incomeCents: incomeCents,
          expenseCents: expenseCents,
          hidden: hidden,
        );

        if (entries.isEmpty) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              head,
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.event_note_outlined,
                        size: 52,
                        // 不写死颜色：深色主题下固定浅灰会糊成一片
                        color: Palette.inkFaint(context)
                            .withValues(alpha: 0.42),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '这一天你还没有记账',
                        style: TextStyle(
                          fontSize: 13,
                          color: Palette.inkFaint(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
          children: [
            head,
            const SizedBox(height: 6),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0)
                      Divider(
                          height: 1,
                          indent: 56,
                          endIndent: 14,
                          color: Palette.hairline(context)),
                    EntryRow(entry: entries[i]),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 流水区标题行：`10月24日　昨天　周六` ……… `收 +500.00　支 -25.00`
class _DayHead extends StatelessWidget {
  const _DayHead({
    required this.day,
    required this.incomeCents,
    required this.expenseCents,
    required this.hidden,
  });

  final DateTime day;
  final int incomeCents;
  final int expenseCents;
  final bool hidden;

  @override
  Widget build(BuildContext context) {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final target = DateTime(day.year, day.month, day.day);
    final diff = today.difference(target).inDays;
    // 「今天/昨天」和「周X」并存（一木也是 `10月24日 昨天 周六`）：
    // 只给相对日的话，用户还得自己算那天是周几。
    final rel = diff == 0
        ? '今天'
        : diff == 1
            ? '昨天'
            : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Text(
            '${day.month}月${day.day}日',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Palette.ink(context),
            ),
          ),
          if (rel != null) ...[
            const SizedBox(width: 6),
            Text(
              rel,
              style: TextStyle(
                fontSize: 12,
                color: Palette.inkFaint(context),
              ),
            ),
          ],
          const SizedBox(width: 6),
          Text(
            '周${weekdays[day.weekday - 1]}',
            style: TextStyle(
              fontSize: 12,
              color: Palette.inkFaint(context),
            ),
          ),
          const Spacer(),
          if (incomeCents > 0) ...[
            Text(
              hidden ? '收 ****' : '收 +${centsToText(incomeCents)}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Palette.income,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (expenseCents > 0)
            Text(
              hidden ? '支 ****' : '支 -${centsToText(expenseCents)}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Palette.expense,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
        ],
      ),
    );
  }
}
