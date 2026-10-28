import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../services/icon_service.dart';
import '../state/settings.dart';
import 'app_glyph.dart';
import 'motion.dart';
import 'theme.dart';
import 'wheel_date_picker.dart';

/// 金额 → 文本的唯一出口。
///
/// MoneyText 和 RollingMoney 共用它：滚动数字和普通金额必须逐字一致，
/// 否则「滚动时显示 1,234、停下变成 1,235」这种差一位的错很难发现。
String moneyLabel(
  int cents, {
  required String symbol,
  required bool compact,
  required bool alwaysTwoDecimals,
  String flow = '',
  String suffix = '',
}) {
  final abs = cents.abs();
  final body = (compact && abs >= 1000000)
      // 一万以上缩写成 1.2万，列表里省地方；点进去看详情仍是完整数字
      ? '${(abs / 1000000).toStringAsFixed(abs % 1000000 == 0 ? 0 : 1)}万'
      : centsToText(abs, alwaysTwoDecimals: alwaysTwoDecimals);
  // 注意：flow 为空时也要处理负数（结余、账户余额可能是负的）。
  // 原来只按 flow 决定符号，导致 -50 显示成 50 —— 记账 App 里这是致命错误。
  // 0 值一律不带正负号：「+¥0」看着像没算对。
  final sign = cents == 0
      ? ''
      : switch (flow) {
          'out' => '-',
          'in' => '+',
          _ => cents < 0 ? '-' : '',
        };
  return '$sign$symbol$body$suffix';
}

/// 短提示：先收掉当前那条，再弹一条 2 秒的。
///
/// 为什么不直接 `showSnackBar`：
/// 1. 它会**排队** —— 连点两次保存，第一条要播满（默认 4 秒）才轮到第二条，
///    用户看到的是"上一条还没走、又冒一条"，像卡住了；全 App 原来 47 处弹提示，
///    只有 8 处会先收掉上一条。
/// 2. 默认 4 秒对「已保存 / 已移入回收站」这种确认太久了。
///
/// 用法就是把 `showSnackBar(SnackBar(content: Text(x)))` 换成 `toast(x)`，
/// receiver 不用动（`ScaffoldMessenger.of(context).toast(...)`、
/// `messenger.toast(...)`、级联 `..toast(...)` 都成立）。
///
/// 需要「撤销」这类按钮的提示**不要**用它 —— 那条要留 4 秒给人点，
/// 见 ledger_page 的删除提示。
extension ToastMessenger on ScaffoldMessengerState {
  void toast(String message) {
    // clearSnackBars 而不是 hideCurrentSnackBar：后者只是开始退场动画，
    // 新的一条要排队等它退完；连续提示时会明显慢半拍。
    clearSnackBars();
    showSnackBar(SnackBar(
      content: Text(message),
      duration: const Duration(seconds: 2),
    ));
  }
}

/// 金额文字。统一处理：整数分 → 文本、隐藏金额打码、收支配色、等宽数字。
class MoneyText extends ConsumerWidget {
  const MoneyText(
    this.cents, {
    super.key,
    this.flow,
    this.style,
    this.alwaysTwoDecimals = false,
    this.suffix = '',
    this.showSymbol = true,
  });

  final int cents;

  /// 'in' / 'out'；为空时不染色
  final String? flow;
  final TextStyle? style;
  final bool alwaysTwoDecimals;
  final String suffix;

  /// 是否带币种符号（¥/$）。流水列表行不需要符号，带符号又占位又显重。
  final bool showSymbol;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final base = style ??
        TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: Palette.ink(context),
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    if (settings.hideAmounts) {
      return Text('****', style: base);
    }
    final color = switch (flow) {
      'out' => Palette.expense,
      'in' => Palette.income,
      _ => base.color,
    };
    final money = Text(
      moneyLabel(
        cents,
        symbol: showSymbol ? settings.symbol : '',
        compact: settings.compactAmounts,
        alwaysTwoDecimals: alwaysTwoDecimals,
        flow: flow ?? '',
        suffix: suffix,
      ),
      // 金额一律单行：超长时省略而不是撑破 Row（字体放大到 1.3× 时尤其明显）
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: base.copyWith(color: color),
    );
    // 大字号金额（净资产、余额、预算剩余这类「主角数字」）改成缩放适配：
    // 宁可字变小，也不要把数字截断——截断过的金额会误导人。
    final big = (base.fontSize ?? 16) >= 20;
    return big ? FittedBox(fit: BoxFit.scaleDown, child: money) : money;
  }
}

/// 滚动金额：数值变化时从旧值滚到新值，而不是硬跳。
///
/// 用在时会随月份/筛选而变的汇总数字上（如头部的「收入 / 支出 / 结余」）。
/// 两个不要用它的地方：
/// - **列表行**：几十行一起滚会闪成一片，而且每行都在跑动画，滚动必掉帧。
/// - **≥20px 的主角数字**：MoneyText 对大字号会套 FittedBox 缩放，但滚动时
///   内容宽度一直在变，FittedBox 会跟着不停改缩放倍率（数字变大字反而变小），
///   看着像在抖动。真要给大字加滚动，得先固定住宽度。
/// 另外它不套 FittedBox，超长时走 ellipsis——所以字号别用太大。
class RollingMoney extends ConsumerStatefulWidget {
  const RollingMoney(
    this.cents, {
    super.key,
    this.flow,
    this.style,
    this.alwaysTwoDecimals = false,
    this.suffix = '',
    this.duration = const Duration(milliseconds: 420),
  });

  final int cents;
  final String? flow;
  final TextStyle? style;
  final bool alwaysTwoDecimals;
  final String suffix;
  final Duration duration;

  @override
  ConsumerState<RollingMoney> createState() => _RollingMoneyState();
}

class _RollingMoneyState extends ConsumerState<RollingMoney>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  /// 滚动起点 / 终点。**必须自己存**，不能直接在 [_current] 里读 widget.cents：
  /// didUpdateWidget 被调用时 widget.cents 已经是新值了，那时再算「当前显示到哪」
  /// 会把终点算进来，结果起点 == 终点，滚动直接变成瞬间跳变（而且是静默的）。
  int _from = 0;
  int _to = 0;

  @override
  void initState() {
    super.initState();
    _from = _to = widget.cents;
    _ctrl = AnimationController(vsync: this, duration: widget.duration)
      // 首帧直接显示终值，不做入场滚动（否则每次切页面都要无意义地爬一遍）
      ..value = 1.0;
  }

  int get _current => _from + ((_to - _from) * _ctrl.value).round();

  @override
  void didUpdateWidget(covariant RollingMoney old) {
    super.didUpdateWidget(old);
    if (old.cents == widget.cents) return;
    // 从**当前滚动位置**接着走，而不是每次都从 0 滚起：
    // 连点下一月时数字才不会先掉回零再爬上来。
    _from = _from + ((_to - _from) * _ctrl.value).round();
    _to = widget.cents;
    if (MediaQuery.of(context).disableAnimations) {
      _ctrl.value = 1.0;
    } else {
      _ctrl.duration = widget.duration;
      _ctrl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final base = widget.style ??
        TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          color: Palette.ink(context),
          fontFeatures: const [FontFeature.tabularFigures()],
        );
    if (settings.hideAmounts) return Text('****', style: base);
    final color = switch (widget.flow) {
      'out' => Palette.expense,
      'in' => Palette.income,
      _ => base.color,
    };
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Text(
          moneyLabel(
            _current,
            symbol: settings.symbol,
            compact: settings.compactAmounts,
            alwaysTwoDecimals: widget.alwaysTwoDecimals,
            flow: widget.flow ?? '',
            suffix: widget.suffix,
          ),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: base.copyWith(color: color),
        );
      },
    );
  }
}

/// 通用卡片容器
class Panel extends StatelessWidget {
  const Panel(
      {super.key,
      required this.child,
      this.padding = const EdgeInsets.all(AppSpace.md)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Palette.card(context),
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: Border.all(color: Palette.hairline(context)),
      ),
      // 必须夹一层透明 Material：Panel 自己用 Container 画了底色，而 ListTile /
      // InkWell 的墨水涟漪是画在最近的 Material 上的。缺这一层时 debug 直接断言
      // 失败（红屏），release 则表现为「点了没有任何反馈」。
      child: Material(
        type: MaterialType.transparency,
        child: child,
      ),
    );
  }
}

/// 表单字段：标签在上、输入框在下，间距固定。
///
/// 为什么不再用 `TextField(labelText: ...)`：
/// Material 的浮动标签在空值时**占住输入区**，这时 `hintText` 根本不可见
/// （只有聚焦后才浮起来），看起来就像「提示词被吃掉了 / 错位了」。
/// 把标签拿到上面、输入框里只留 hint，语义清楚，也不会和内容打架。
class AppField extends StatelessWidget {
  const AppField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
    this.trailing,
  });

  final String label;
  final Widget child;

  /// 字段下方的补充说明（一行小字）
  final String? helper;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Palette.inkSoft(context),
              ),
            ),
            const Spacer(),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        child,
        if (helper != null) ...[
          const SizedBox(height: 5),
          Text(
            helper!,
            style: TextStyle(
              fontSize: 10.5,
              height: 1.4,
              color: Palette.inkFaint(context),
            ),
          ),
        ],
      ],
    );
  }
}

/// 统一文本输入：米纸底、无描边、圆角 12，聚焦时才出现主色细边。
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.label,
    this.controller,
    this.hint,
    this.helper,
    this.keyboardType,
    this.inputFormatters,
    this.maxLines = 1,
    this.autofocus = false,
    this.onChanged,
    this.textAlign = TextAlign.start,
    this.suffixText,
    this.maxLength,
    this.obscureText = false,
  });

  final String label;
  final TextEditingController? controller;
  final String? hint;
  final String? helper;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final int maxLines;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final TextAlign textAlign;
  final String? suffixText;
  final int? maxLength;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(AppRadius.control);
    return AppField(
      label: label,
      helper: helper,
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        maxLines: maxLines,
        maxLength: maxLength,
        obscureText: obscureText,
        autofocus: autofocus,
        onChanged: onChanged,
        textAlign: textAlign,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: Palette.ink(context),
        ),
        decoration: InputDecoration(
          hintText: hint,
          counterText: '',
          hintStyle: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            color: Palette.inkFaint(context),
          ),
          suffixText: suffixText,
          suffixStyle: TextStyle(
            fontSize: 12,
            color: Palette.inkFaint(context),
          ),
          filled: true,
          fillColor: Palette.paper(context),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          border: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: radius,
            borderSide: BorderSide(
              color: Palette.brand(context),
              width: 1.3,
            ),
          ),
        ),
      ),
    );
  }
}

/// 统一下拉选择：外观和 [AppTextField] 一致，标签同样在上方。
class AppDropdown<T> extends StatelessWidget {
  const AppDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.helper,
    this.hint,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final String? helper;

  /// 值为 null 时显示的占位文案
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return AppField(
      label: label,
      helper: helper,
      child: Container(
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: Palette.paper(context),
          borderRadius: BorderRadius.circular(AppRadius.control),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            hint: hint == null
                ? null
                : Text(hint!,
                    style: TextStyle(
                        fontSize: 14, color: Palette.inkFaint(context))),
            items: items,
            onChanged: onChanged,
            isExpanded: true,
            isDense: true,
            borderRadius: BorderRadius.circular(AppRadius.control),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: Palette.ink(context),
            ),
          ),
        ),
      ),
    );
  }
}

/// 图标选择：一排紧凑方块。
///
/// 之前每个对话框都自己写一遍 ChoiceChip —— ChoiceChip 选中会带勾选标记，
/// 用在 emoji 上很怪，而且默认内边距会把一排放不下。统一成方块：
/// 选中 = 主色淡底 + 主色描边。
///
/// 2026-10-25：第一个格子是「相册」入口（自定义图标）。
/// 选中自定义图标后，它会以缩略图形式出现在网格最前面；**长按**它可以移除
/// （回到 emoji）。自定义图标的渲染统一走 [AppGlyph]。
class GlyphPicker extends StatelessWidget {
  const GlyphPicker({
    super.key,
    required this.glyphs,
    required this.value,
    required this.onChanged,
    this.label = '图标',
  });

  final List<String> glyphs;
  final String value;
  final ValueChanged<String> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    final custom = IconService.isImage(value);

    Widget box({required Widget child, required bool selected, VoidCallback? onTap,
        VoidCallback? onLongPress}) {
      return PressScale(
        scale: 0.9,
        onTap: onTap,
        child: GestureDetector(
          onLongPress: onLongPress,
          child: AnimatedContainer(
            duration: Motion.d(context, Motion.small),
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? brand.withValues(alpha: 0.12)
                  : Palette.paper(context),
              borderRadius: BorderRadius.circular(AppRadius.control),
              border: Border.all(
                color: selected ? brand : Palette.hairline(context),
              ),
            ),
            child: child,
          ),
        ),
      );
    }

    return AppField(
      label: label,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          // 相册入口：选一张图当图标
          box(
            selected: custom,
            onTap: () async {
              final g = await IconService.pickFromGallery();
              if (g != null) onChanged(g);
            },
            // 36×36 的格子：自定义图片要撑满（fill），
            // 否则 20×20 缩在中间一块，看着像没生效。
            child: custom
                ? AppGlyph(value, size: 20, fill: true, radius: 8)
                : Icon(Icons.add_photo_alternate_outlined,
                    size: 18, color: Palette.inkFaint(context)),
          ),
          for (final g in glyphs)
            box(
              selected: value == g,
              onTap: () => onChanged(g),
              child: Text(g, style: const TextStyle(fontSize: 17)),
            ),
        ],
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 2),
      child: Row(
        children: [
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Palette.inkSoft(context),
            ),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// 紧凑表头里的动作按钮（「管理」「立即备份」这类）。
///
/// 为什么单独包一层：原来都是 `TextButton + minimumSize(0,0) + shrinkWrap`，
/// 把按钮压到只剩 20 来 dp 高 —— 视觉是紧凑了，但手指点上去经常没反应
/// （Material 的最小可点尺寸是 48dp，低于这个值就是在赌用户点得准）。
/// 这里保留 12px 的小字，只把**点击区**撑到 48×48：左右各补 8，
/// 因为「管理」两个字本身只有 24dp 宽。
///
/// 注意 `tapTargetSize` 仍要 shrinkWrap：它只负责「额外加的那圈 Material 内边距」，
/// 不加才不会在父 Row 里凭空多出 8dp；高度由 minimumSize 决定，正好 48。
class HeaderAction extends StatelessWidget {
  const HeaderAction(
      {super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: Palette.brand(context),
      ),
      child: Text(label, style: const TextStyle(fontSize: 12)),
    );
  }
}

class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.title,
    this.hint,
    this.icon = Icons.receipt_long_outlined,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? hint;
  final IconData icon;

  /// 空状态引导（Empty State CTA）：给一个「从这开始」的入口。
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(icon, size: 30, color: Palette.inkFaint(context)),
          const SizedBox(height: 8),
          Text(title,
              style: TextStyle(fontSize: 14, color: Palette.inkSoft(context))),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(hint!,
                textAlign: TextAlign.center,
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          ],
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 12),
            // 第一条内容从入口飞进来：按钮本身有按下反馈
            PressScale(
              scale: 0.96,
              onTap: onAction,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Palette.brand(context).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppRadius.control),
                  border: Border.all(color: Palette.brand(context)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 16, color: Palette.brand(context)),
                    const SizedBox(width: 4),
                    Text(actionLabel!,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Palette.brand(context))),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 加载失败重试（Error → Retry）。
///
/// 失败只发生在内容区：导航和标签栏都留着；重试按钮本身要回应
/// （缩成小转圈），内容回来再浮现，不是只摆一句「读取失败」。
/// 读取失败时的统一提示。
///
/// 之前有 12 处直接 `Text('读取失败：$e')`，用户看到的是
/// 「DatabaseException(no such column: fee_cents)」这种东西 ——
/// 既看不懂，也不知道下一步该干嘛。这里给人话，技术细节折叠起来。
class LoadError extends StatelessWidget {
  const LoadError({super.key, required this.error, this.compact = false});

  final Object error;

  /// 紧凑模式：嵌在卡片里用（不带大段留白）
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: compact ? 10 : 28,
        horizontal: compact ? 4 : 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 16, color: Palette.expense),
              const SizedBox(width: 6),
              Text('数据读取失败',
                  style: TextStyle(
                      fontSize: compact ? 12 : 14,
                      fontWeight: FontWeight.w600,
                      color: Palette.inkSoft(context))),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '退出这一页再进来通常就好了。一直失败请到「我的 → 数据管理 → 日志中心」复制日志反馈。',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 10.5, height: 1.5, color: Palette.inkFaint(context)),
          ),
          Theme(
            // 去掉 ExpansionTile 上下的分隔线，否则嵌在卡片里很脏
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 6),
              dense: true,
              title: Text('技术详情',
                  style: TextStyle(
                      fontSize: 10.5, color: Palette.inkFaint(context))),
              children: [
                SelectableText(
                  '$error',
                  style:
                      TextStyle(fontSize: 10.5, color: Palette.inkFaint(context)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class ErrorRetryView extends StatefulWidget {
  const ErrorRetryView({
    super.key,
    required this.message,
    required this.onRetry,
    this.detail,
  });

  final String message;
  final String? detail;
  final Future<void> Function() onRetry;

  @override
  State<ErrorRetryView> createState() => _ErrorRetryViewState();
}

class _ErrorRetryViewState extends State<ErrorRetryView> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      child: Column(
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 32, color: Palette.inkFaint(context)),
          const SizedBox(height: 10),
          Text(widget.message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Palette.inkSoft(context))),
          if (widget.detail != null) ...[
            const SizedBox(height: 4),
            Text(widget.detail!,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          ],
          const SizedBox(height: 16),
          SizedBox(
            height: 36,
            child: AnimatedContainer(
              duration: Motion.d(context, Motion.small),
              curve: XCurve.smooth,
              width: _busy ? 36 : 108,
              decoration: BoxDecoration(
                color: Palette.brand(context),
                borderRadius:
                    BorderRadius.circular(_busy ? 18 : AppRadius.control),
              ),
              child: Center(
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : PressScale(
                        scale: 0.95,
                        onTap: _run,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.refresh,
                                  size: 16, color: Colors.white),
                              SizedBox(width: 6),
                              Text('重试',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white)),
                            ],
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 年月选择面板：年 / 月两列滚轮，底部「确定」。
///
/// 明细页折叠头部和 MonthBar 共用这一份，保证两处手感一致。
///
/// 2026-10-25 换掉原来的「年份胶囊网格 + 月份 4×3 网格」：年份从 2026 排到
/// 1999 有 28 个胶囊，要滚好几屏才找得到 2019 年，两块还割裂。滚轮把
/// 年份收窄成最近 31 年并直接停在当前选中项上。
Future<DateTime?> pickYearMonth(BuildContext context, DateTime initial) =>
    pickWheelYearMonth(context, initial);

/// 月份条（对齐参考版）：‹ 上个月 ｜ 年月大字 + 下拉 ｜ 下个月 ›
///
/// 点中间弹「选择年月」面板；不是本月时，月份下方给一行「点此回到本月」。
/// 明细 / 洞察 / 预算 / 日历共用同一个组件，保证视觉一致。
/// 横向月份条（对齐一木统计页）：本月 / 上月 / 8月 / 7月 / 6月 / 5月 / 4月。
///
/// 原来只有 `< 2026年10月 >` 前后翻页，要看 3 个月前得点 3 次；
/// 一木是一屏横排、一眼看全、一键跳转。信息密度的差距，改造成本却很低。
///
/// [lite] 模式（2026-10-25 用户要求，统计页用）：7 个胶囊收成 3 个 ——
/// 「本月」「上月」+ 一个「选月份」按钮（弹滚轮）。原因：那 5 个「N 月」在
/// 统计页头部糊成一片，视觉杂乱，而且点错一个就跳到半年多以前，反而不如
/// 一个明确的滚轮选择器。其它页面保持 7 个的快跳能力不变。
class MonthStrip extends ConsumerWidget {
  const MonthStrip({
    super.key,
    required this.month,
    required this.onChanged,
    this.lite = false,
  });

  final DateTime month;
  final ValueChanged<DateTime> onChanged;
  final bool lite;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final brand = Palette.brand(context);

    Widget chip(String label, DateTime m) {
      final sel = m.year == month.year && m.month == month.month;
      return PressScale(
        scale: 0.94,
        onTap: () => onChanged(m),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: sel ? brand.withValues(alpha: 0.12) : Palette.card(context),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: sel ? brand : Palette.hairline(context)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
              color: sel ? brand : Palette.inkSoft(context),
            ),
          ),
        ),
      );
    }

    if (lite) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            chip('本月', DateTime(now.year, now.month)),
            const SizedBox(width: 6),
            chip('上月', DateTime(now.year, now.month - 1)),
            const SizedBox(width: 6),
            // 滚轮选择：想看哪个月直接挑，不用在胶囊里盲点
            PressScale(
              scale: 0.94,
              onTap: () async {
                final m = await pickYearMonth(context, month);
                if (m != null) onChanged(m);
              },
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Palette.card(context),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: Palette.hairline(context)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.calendar_month_outlined,
                        size: 14, color: Palette.inkSoft(context)),
                    const SizedBox(width: 3),
                    Text('选月份',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkSoft(context))),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }

    final items = <({String label, DateTime m})>[
      (label: '本月', m: DateTime(now.year, now.month)),
      (label: '上月', m: DateTime(now.year, now.month - 1)),
    ];
    // 再往前用「N 月」标注（同一年的前提下）
    for (var i = 2; i <= 6; i++) {
      final m = DateTime(now.year, now.month - i);
      items.add((label: '${m.month}月', m: m));
    }

    return SizedBox(
      height: 32,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, i) {
          final e = items[i];
          return chip(e.label, e.m);
        },
      ),
    );
  }
}

class MonthBar extends ConsumerWidget {
  const MonthBar({super.key, required this.month, required this.onChanged});

  final DateTime month;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = DateTime.now();
    final isCurrent = month.year == now.year && month.month == now.month;
    return Row(
      children: [
        IconButton(
          tooltip: '上个月',
          onPressed: () => onChanged(shiftMonth(month, -1)),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: PressScale(
            scale: 0.97,
            onTap: () async {
              final m = await pickYearMonth(context, month);
              if (m != null) onChanged(m);
            },
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        '${month.year} 年',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Palette.inkFaint(context)),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        '${month.month} 月',
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Palette.ink(context)),
                      ),
                    ),
                    const SizedBox(width: 2),
                    Icon(Icons.keyboard_arrow_down,
                        size: 18, color: Palette.inkFaint(context)),
                  ],
                ),
                if (!isCurrent)
                  Text('点此回到本月',
                      style: TextStyle(
                          fontSize: 10.5, color: Palette.inkFaint(context))),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: '下个月',
          onPressed: () => onChanged(shiftMonth(month, 1)),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}
