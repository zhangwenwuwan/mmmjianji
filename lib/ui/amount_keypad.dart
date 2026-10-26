library;

import 'package:flutter/material.dart';

import '../core/rules.dart';
import 'common.dart' show AppField;
import 'motion.dart' show PressScale;
import 'theme.dart' show Palette;

/// 计算器式金额键盘：**全 App 金额输入的唯一入口**。
///
/// 为什么要抽出来：之前记账页有自己的计算器键盘，而借贷 / 目标 / 预算 / 账户期初
/// 这些表单用的是系统数字键盘 —— 同一个 App 里两种输入手感，而且系统键盘上
/// 没法做「12 + 5 × 2」这种连算。现在统一走这里。
///

/// 键盘的运算状态。**单位是分**，和库里的金额一致。
class AmountKeypadController extends ChangeNotifier {
  AmountKeypadController({int initialCents = 0}) {
    if (initialCents > 0) {
      _amount = initialCents % 100 == 0
          ? (initialCents ~/ 100).toString()
          : (initialCents / 100).toStringAsFixed(2);
    }
  }

  String _amount = '';
  int _acc = 0;
  String? _op;

  int get _curCents => parseAmountToCents(_amount) ?? 0;

  /// 表达式当前值（分）。刚按完运算符、下一个数还没输时返回累加值本身，
  /// 否则会显示「17 − 0 = 0」，用户以为金额被清空了（真计算器也是这么处理的）。
  int get cents {
    if (_op == null) return _curCents;
    if (_amount.isEmpty) return _acc;
    return applyAmountOp(_acc, _op!, _curCents);
  }

  /// 上方过程行，如「17 −」；没有运算符时为 null。
  String? get expression =>
      _op == null ? null : '${centsToText(_acc)} ${_labelOf(_op!)}';

  /// 金额区显示文本：有运算符时显示实时结果，否则显示正在输入的数字。
  String get display =>
      _op != null ? centsToText(cents) : (_amount.isEmpty ? '0.00' : _amount);

  /// 是否一个数字都还没输入（决定「确定」能不能点）
  bool get isEmpty => _amount.isEmpty && _op == null;

  void press(String key) {
    if (const ['+', '-', '×', '÷'].contains(key)) {
      final cur = _curCents;
      _acc = _op == null ? cur : applyAmountOp(_acc, _op!, cur);
      _op = key;
      _amount = '';
      notifyListeners();
      return;
    }
    if (key == 'del') {
      if (_amount.isNotEmpty) {
        _amount = _amount.substring(0, _amount.length - 1);
        notifyListeners();
      }
      return;
    }
    if (key == 'clear') {
      _amount = '';
      _acc = 0;
      _op = null;
      notifyListeners();
      return;
    }
    if (!RegExp(r'^[\d.]$').hasMatch(key)) return;
    final next = _amount + key;
    if (!RegExp(r'^\d{0,7}(\.\d{0,2})?$').hasMatch(next)) return;
    _amount = next;
    notifyListeners();
  }

  void clear() => press('clear');

  static String _labelOf(String op) => switch (op) {
        '-' => '−', // 显示用排版减号（U+2212），但**判定一律用 ASCII '-'**
        _ => op,
      };
}

/// 计算器式键盘：4 列 5 行，运算符固定右列，没有 `=` 键。
///
/// 一按运算符，上方金额区就实时显示结果，所以 `=` 是多余的。
///
/// ⚠️ 键位的 value 一律用 **ASCII `+ - × ÷`**（和 [applyAmountOp]、[parseAmountToCents]
/// 的判定保持一致）；只有**显示**时才把 `-` 排成排版减号 `−`。
/// 早期版本把 `−`(U+2212) 当成 value，和判定列表里的 ASCII `-` 对不上，
/// 结果减法键按下去毫无反应 —— 别再犯。
class AmountKeypad extends StatelessWidget {
  const AmountKeypad({super.key, required this.onKey, this.showOperators = true});

  final ValueChanged<String> onKey;
  final bool showOperators;

  @override
  Widget build(BuildContext context) {
    const digits = [
      ['7', '8', '9', '÷'],
      ['4', '5', '6', '×'],
      ['1', '2', '3', '-'],
      ['.', '0', 'del', '+'],
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final row in digits)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Row(
              children: [
                for (final k in row)
                  if (showOperators || !const ['+', '-', '×', '÷'].contains(k))
                    _key(context, k,
                        label: switch (k) {
                          'del' => '⌫',
                          '-' => '−',
                          _ => k,
                        }),
              ],
            ),
          ),
      ],
    );
  }

  Widget _key(BuildContext context, String value, {String? label}) {
    final isAction = value == 'del';
    final isOp = const ['+', '-', '×', '÷'].contains(value);
    final fg = isOp
        ? Palette.brand(context)
        : (isAction ? Palette.inkSoft(context) : Palette.ink(context));
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: SizedBox(
          key: Key('key-$value'),
          height: 46,
          child: Material(
            color: isOp
                ? Palette.brand(context).withValues(alpha: 0.09)
                : (isAction
                    ? Palette.hairline(context).withValues(alpha: 0.45)
                    : Palette.paper(context)),
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: PressScale(
              scale: 0.92,
              onTap: () => onKey(value),
              child: Center(
                child: Text(
                  label ?? value,
                  style: TextStyle(
                    fontSize: isAction ? 16 : 21,
                    fontWeight: isOp ? FontWeight.w700 : FontWeight.w600,
                    color: fg,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部金额键盘面板：大字号金额 + 过程行 + 键盘 + 确定。
///
/// 返回用户确认的**分**；取消/清空后点确定返回 null（0 不作为有效金额，
/// 记账类业务里 0 元是没有意义的）。
Future<int?> showAmountKeypad(
  BuildContext context, {
  int initialCents = 0,
  String title = '输入金额',
  String? symbol,

  /// 允许返回 0。预算类场景需要「0 = 不设预算」，记账类场景 0 没有意义。
  bool allowZero = false,
}) async {
  final ctl = AmountKeypadController(initialCents: initialCents);
  final result = await showModalBottomSheet<int>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: Palette.card(ctx),
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: AnimatedBuilder(
          animation: ctl,
          builder: (ctx, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 13, color: Palette.inkSoft(ctx))),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, null),
                    child: const Text('取消'),
                  ),
                ],
              ),
              // 过程行：如「17 −」
              SizedBox(
                height: 18,
                child: ctl.expression == null
                    ? null
                    : Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          ctl.expression!,
                          style: TextStyle(
                              fontSize: 12, color: Palette.inkFaint(ctx)),
                        ),
                      ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '${symbol ?? ''}${ctl.display}',
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      color: Palette.ink(ctx),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              AmountKeypad(onKey: ctl.press),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: ctl.clear,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 46),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: const Text('清空'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 46,
                      child: FilledButton(
                        onPressed:
                            (!allowZero && (ctl.isEmpty || ctl.cents <= 0))
                                ? null
                                : () => Navigator.pop(ctx, ctl.cents),
                        child: const Text('确定'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return result;
}

/// 表单里的金额字段：点一下弹出自有键盘，**不弹系统键盘**。
///
/// 用法和 AppTextField 一致，只是值从 String 变成 int 分。
class AmountField extends StatelessWidget {
  const AmountField({
    super.key,
    required this.label,
    required this.cents,
    required this.onChanged,
    this.symbol,
    this.hint = '0.00',
    this.helper,
  });

  final String label;
  final int cents;
  final ValueChanged<int> onChanged;
  final String? symbol;
  final String hint;
  final String? helper;

  @override
  Widget build(BuildContext context) {
    final has = cents > 0;
    return AppField(
      label: label,
      helper: helper,
      child: InkWell(
        onTap: () async {
          // 收掉可能还开着的系统键盘，否则两块键盘叠在一起
          FocusManager.instance.primaryFocus?.unfocus();
          final picked = await showAmountKeypad(
            context,
            initialCents: cents,
            title: label,
            symbol: symbol,
          );
          if (picked != null) onChanged(picked);
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          height: 46,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Palette.paper(context),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Palette.hairline(context)),
          ),
          child: Row(
            children: [
              if (symbol != null)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(symbol!,
                      style: TextStyle(
                          fontSize: 14, color: Palette.inkSoft(context))),
                ),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    has ? centsToText(cents) : hint,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: has
                          ? Palette.ink(context)
                          : Palette.inkFaint(context),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Icon(Icons.keyboard_alt_outlined,
                  size: 17, color: Palette.inkFaint(context)),
            ],
          ),
        ),
      ),
    );
  }
}
