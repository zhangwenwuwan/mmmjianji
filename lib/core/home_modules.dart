/// 首页模块目录。
///
/// 为什么把「模块清单」做成一个 enum 而不是散在 ledger_page 里的 if 链：
/// 1. 用户自定义顺序需要**稳定的 id** 落盘，改代码里的 widget 名不能影响存档；
/// 2. 新增模块时能统一出现在「首页模块」设置页里，不用同时改两处；
/// 3. 顺序归一化（[normalizeOrder]）需要一个统一的"全集"来补漏。
enum HomeModule {
  /// 2026-10-26 起「固定」：永远渲染在首页最上面，不参与排序、不可隐藏。
  /// 用户要求「本月概览固定显示」，删掉顶栏那条重复的收支三段后，
  /// 它就是首页唯一的数据概览。
  hero('hero', '本月概览', '本月支出 / 收入 / 结余的大字卡', fixed: true),
  addEntry('addEntry', '记一笔', '首页主入口按钮（不可隐藏）'),
  safeToSpend('safeToSpend', '今天还能花', '按剩余天数均摊的每日可用额度'),
  budgetHint('budgetHint', '预算提醒', '接近或超出预算时的提示条'),
  backupHint('backupHint', '备份提醒', '从未备份或超过 7 天没备份时的提示条'),
  lastMonth('lastMonth', '上月对比', '上个月花了多少、是增还是减'),
  annualReport('annualReport', '年度报告', '今年累计与月度走势入口');

  const HomeModule(this.id, this.label, this.hint, {this.fixed = false});

  /// 落盘用的稳定标识。**不要随改名改这里**。
  final String id;
  final String label;
  final String hint;

  /// 位置与显隐都不可调（现在只有「本月概览」）。设置页里显示为锁定项。
  final bool fixed;

  /// 「记一笔」是唯一不能隐藏的模块。
  ///
  /// 理由：这是全 App 唯一的记账入口（没有悬浮球、没有底部 + 号）。
  /// 允许隐藏等于给用户一个「把记账按钮藏起来」的开关，
  /// 藏完只能靠搜索页或详情页绕进去，属于自断手脚。
  bool get canHide => this != HomeModule.addEntry && !fixed;

  static HomeModule? byId(String id) {
    for (final m in HomeModule.values) {
      if (m.id == id) return m;
    }
    return null;
  }

  static List<String> get defaultOrder =>
      [for (final m in HomeModule.values) m.id];
}

/// 把落盘的顺序字符串归一化成一条**完整且无重复**的 id 列表。
///
/// 三种脏数据都要吃掉：
/// - 空（老用户没存过）→ 用默认顺序；
/// - 未知 id（用户降级 / 我们删掉了某个模块）→ 丢掉；
/// - 缺失 id（我们**新加了**模块，老存档里没有）→ 补到末尾。
///
/// 最后一条最关键：不补的话，新版本加的模块对所有老用户永久不可见，
/// 而且设置页里也看不到它，排查起来很折磨。
List<HomeModule> normalizeOrder(String? stored) {
  final seen = <HomeModule>{};
  final out = <HomeModule>[];
  for (final raw in (stored ?? '').split(',')) {
    final id = raw.trim();
    if (id.isEmpty) continue;
    final m = HomeModule.byId(id);
    if (m == null || seen.contains(m)) continue;
    seen.add(m);
    out.add(m);
  }
  for (final m in HomeModule.values) {
    if (!seen.contains(m)) out.add(m);
  }
  return out;
}

/// 解析隐藏集合，同样丢掉未知 id。
Set<HomeModule> parseHidden(String? stored) {
  final out = <HomeModule>{};
  for (final raw in (stored ?? '').split(',')) {
    final id = raw.trim();
    if (id.isEmpty) continue;
    final m = HomeModule.byId(id);
    if (m != null && m.canHide) out.add(m);
  }
  return out;
}

/// 可见模块 = 顺序里过滤掉隐藏项。「记一笔」永远保留。
List<HomeModule> visibleModules(
        List<HomeModule> order, Set<HomeModule> hidden) =>
    [
      for (final m in order)
        if (!hidden.contains(m) || !m.canHide) m
    ];
