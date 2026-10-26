/// 币种表与折算。
///
/// 约定：rates 里存的是「1 单位外币 = rate 单位主币」。
/// 折算只发生在展示/统计层，数据库里的分永远是原币种。
library;

/// 常用币种：代码 → (符号, 中文名)
const Map<String, (String, String)> kCurrencies = {
  'CNY': ('¥', '人民币'),
  'USD': (r'$', '美元'),
  'EUR': ('€', '欧元'),
  'GBP': ('£', '英镑'),
  'JPY': ('¥', '日元'),
  'HKD': (r'HK$', '港币'),
  'MOP': (r'MOP$', '澳门元'),
  'TWD': (r'NT$', '新台币'),
  'KRW': ('₩', '韩元'),
  'SGD': (r'S$', '新加坡元'),
  'AUD': (r'A$', '澳元'),
  'CAD': (r'C$', '加元'),
  'CHF': (r'CHF', '瑞士法郎'),
  'THB': ('฿', '泰铢'),
  'MYR': (r'RM', '马来西亚林吉特'),
  'VND': ('₫', '越南盾'),
};

String symbolOf(String code) => kCurrencies[code]?.$1 ?? code;

String nameOf(String code) => kCurrencies[code]?.$2 ?? code;

/// 原币种分 → 主币种分。
///
/// [rates] 缺这个币种时按 1:1 折算（宁可显示个大概，也不能让统计崩掉），
/// 调用方可以用 [hasRate] 提前判断并提示用户补汇率。
int toBaseCents(
  int cents,
  String fromCode,
  String baseCode,
  Map<String, double> rates,
) {
  if (fromCode == baseCode) return cents;
  final rate = rates[fromCode] ?? 1.0;
  // 分 → 外币单位 → 主币单位 → 分。round 保证整数分。
  return (cents * rate).round();
}

bool hasRate(String fromCode, String baseCode, Map<String, double> rates) =>
    fromCode == baseCode || rates.containsKey(fromCode);

/// 拼展示符号：外币账户在金额后缀代码，避免两套 ¥ 打架（JPY 也是 ¥）。
String amountSuffix(String code, String baseCode) =>
    code == baseCode ? '' : ' $code';
