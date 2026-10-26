import 'package:flutter/services.dart';

/// 金额输入限制：只能数字、最多一个小数点、小数点后最多两位、整数部分最多 7 位。
///
/// 抽成独立文件是为了能单测：输入过滤是「用户碰得到的第一道关」，
/// 之前只过滤字符集，用户能敲出 "1.2.3"，再被后端判成无效金额，体验很差。
///
/// ⚠️ 这个类之前只被测试引用、**没有任何输入框真的挂上**，
/// 等于「写了但没用」。现在所有金额输入框都必须带 `inputFormatters`。
class AmountInputFormatter extends TextInputFormatter {
  const AmountInputFormatter();

  static final _pattern = RegExp(r'^\d{0,7}(\.\d{0,2})?$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.isEmpty) return newValue;
    return _pattern.hasMatch(newValue.text) ? newValue : oldValue;
  }
}
