import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/currency.dart';
import '../core/loan.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'amount_keypad.dart';
import 'common.dart';
import 'ledger_page.dart';
import 'motion.dart';
import 'pocket_manage_page.dart';
import 'theme.dart';

/// 账户详情。
///
/// 设计原则（这次按类型当成四个不同对象来做，不是一套模板套四种）：
/// - **信用卡**：本质是「额度 + 欠款 + 还款周期」。所以首屏必须是
///   已用/额度/可用 + 额度使用率 + 距还款日天数，账单日和还款日缺一不可。
/// - **银行卡**：本质是「余额 + 收支流水」。首屏就是余额，并标明是储蓄卡。
/// - **负债**：本质是「还欠多少」，红系强调，不显示额度进度。
/// - **现金**：本质是「钱包里有多少」，最简。
class AccountDetailPage extends ConsumerStatefulWidget {
  const AccountDetailPage({super.key, required this.pocket});

  final Pocket pocket;

  @override
  ConsumerState<AccountDetailPage> createState() => _AccountDetailPageState();
}

class _AccountDetailPageState extends ConsumerState<AccountDetailPage> {
  late Pocket _pocket = widget.pocket;
  List<Entry>? _entries;
  ({int outCents, int inCents, int transferOut, int transferIn})? _month;

  /// 只看校准流水（对过几次账之后，普通流水会把校准记录冲散）。
  bool _onlyAdjustment = false;
  int _adjustmentCount = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = await ref.read(storeProvider.future);
    // 详情页要能一路「再显示」到最早一笔：突破默认 200 条上限。
    // UI 仍按 60 条/页渲染（_shownCount），不会一次全建。
    final list = await store.entriesOfPocket(_pocket.id,
        onlyAdjustment: _onlyAdjustment, limit: 1000000);
    // 账户跨账本共享：本月合计也不按账本过滤，否则会和余额对不上
    final month = await store.pocketMonthTotals(_pocket.id, DateTime.now());
    final adjCount = await store.adjustmentCountOf(_pocket.id);
    final all = await store.allPockets();
    if (!mounted) return;
    setState(() {
      _entries = list;
      _month = month;
      _adjustmentCount = adjCount;
      // 编辑完账户后，本页要显示新改的额度/账单日，不能还拿旧的 widget 参数
      for (final p in all) {
        if (p.id == _pocket.id) _pocket = p;
      }
    });
  }

  Future<void> _edit() async {
    await showPocketEditor(context, ref, _pocket);
    await _load();
  }

  /// 余额校准：把账户余额对齐到真实余额。
  ///
  /// 关键取舍：**生成一条「不计入收支 / 不计入预算」的调整流水**，而不是改期初余额。
  /// 改期初会连历史月份的统计一起改写，而且看不出"什么时候对过账"；
  /// 调整流水既修正了余额，又留下审计痕迹（回收站里也能撤）。
  ///
  /// 负债账户同样支持，但符号是反的（见 LedgerStore.reconcileBalance）：
  /// 欠款变多记支出、欠款变少记收入。方向判定只有 store 里那一份，
  /// 这里只负责把预览文案渲染对。
  Future<void> _reconcile(int balance) async {
    final isLiability = _pocket.kind.isLiability;
    final typed = await showAmountKeypad(
      context,
      initialCents: balance.abs(),
      title: isLiability ? '实际还欠' : '实际余额',
      symbol: _pocket.currency,
      allowZero: true,
    );
    if (typed == null) return;

    // 金额键盘没有负号键。负债账户的余额语义本来就是「还欠多少」，
    // 正数足够表达；只有普通账户透支（余额为负）才需要这个开关取反。
    int? confirmed;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        // 当前余额已经是负数时，默认勾上，省得用户每次都要想起来
        var negative = !isLiability && balance < 0;
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final actual = isLiability ? typed : (negative ? -typed : typed);
            final diff = actual - balance;
            final label = isLiability ? '欠款' : '余额';
            final flow = LedgerStore.reconcileFlow(_pocket.kind, diff);
            final content = diff == 0
                ? Text('记录的$label和实际一样，不用校准。')
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '当前记录$label：${_pocket.currency} ${centsToText(balance)}\n'
                        '实际$label：${_pocket.currency} ${centsToText(actual)}\n\n'
                        '会生成一条${flow == 'in' ? '收入' : '支出'} '
                        '${centsToText(diff.abs())} 的'
                        '「${isLiability ? '欠款' : '余额'}校准」流水；'
                        '这笔不计入收支统计，也不占预算。',
                      ),
                      if (!isLiability) ...[
                        const SizedBox(height: 6),
                        SwitchListTile.adaptive(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          title: const Text('余额是负数（透支）',
                              style: TextStyle(fontSize: 13)),
                          value: negative,
                          onChanged: (v) => setLocal(() => negative = v),
                        ),
                      ],
                    ],
                  );
            return AlertDialog(
              title: Text(diff == 0 ? '余额一致' : '确认校准$label？'),
              content: content,
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(diff == 0 ? '知道了' : '取消'),
                ),
                if (diff != 0)
                  FilledButton(
                    onPressed: () {
                      confirmed = actual;
                      Navigator.pop(ctx, true);
                    },
                    child: const Text('校准'),
                  ),
              ],
            );
          },
        );
      },
    );
    if (ok != true) return;
    final actual = confirmed;
    if (actual == null) return;

    final book = await ref.read(activeBookProvider.future);
    final store = await ref.read(storeProvider.future);
    final id = await store.reconcileBalance(
      bookId: book.id,
      pocket: _pocket,
      currentCents: balance,
      targetCents: actual,
    );
    if (id == null) {
      _toast('余额一致，不用校准');
      return;
    }
    bumpRevision(ref);
    await _load();
    if (!mounted) return;
    final label = _pocket.kind.isLiability ? '欠款' : '余额';
    _toast('已校准，$label更新为 ${centsToText(actual)}');
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).toast(msg);
  }

  @override
  Widget build(BuildContext context) {
    final balances = ref.watch(balancesProvider).valueOrNull ?? const [];
    final book = ref.watch(activeBookProvider).valueOrNull;
    final base = book?.baseCurrency ?? 'CNY';
    final settings = ref.watch(settingsProvider);
    final p = _pocket;

    int balance = p.openingCents;
    for (final b in balances) {
      if (b.pocket.id == p.id) balance = b.balanceCents;
    }
    final suffix = amountSuffix(p.currency, base);

    return Scaffold(
      appBar: AppBar(
        title: Text(p.title),
        actions: [
          IconButton(
            tooltip: p.kind.isLiability ? '欠款校准' : '余额校准',
            onPressed: () => _reconcile(balance),
            icon: const Icon(Icons.tune_outlined),
          ),
          IconButton(
            tooltip: '编辑账户',
            onPressed: _edit,
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
        children: [
          _hero(context, p, balance, suffix, settings),
          const SizedBox(height: 14),
          if (p.kind == PocketKind.credit)
            _creditFacts(context, p, balance)
          else
            _basicFacts(context, p),
          const SizedBox(height: 14),
          // 贷款账户：把「年利率 / 期数 / 还款方式」算成人话。
          // 原来这三个字段只在编辑页里实时算，保存后详情页一个字都看不到。
          if (p.kind == PocketKind.debt) _loanPanel(context, p),
          _identityPanel(context, p),
          _monthPanel(context, p, suffix),
          const SizedBox(height: 18),
          // 校准流水混在普通流水里很难找，对过账的账户才给这个开关。
          Row(
            children: [
              Expanded(
                child: SectionLabel(_onlyAdjustment
                    ? '校准流水（$_adjustmentCount 条）'
                    : '流水（最近 200 条）'),
              ),
              if (!_onlyAdjustment && _adjustmentCount > 0)
                FilterChip(
                  label: Text('只看校准 $_adjustmentCount'),
                  selected: false,
                  onSelected: (_) => setState(() {
                    _onlyAdjustment = true;
                    _entries = null;
                    _load();
                  }),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  labelStyle: TextStyle(
                      fontSize: 12, color: Palette.inkSoft(context)),
                  padding: EdgeInsets.zero,
                )
              else if (_onlyAdjustment)
                TextButton(
                  onPressed: () => setState(() {
                    _onlyAdjustment = false;
                    _entries = null;
                    _load();
                  }),
                  child: const Text('看全部流水', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          if (_entries == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 30),
              child: Skeleton(height: 52, radius: 14),
            )
          else if (_entries!.isEmpty)
            EmptyView(
              icon: Icons.receipt_long_outlined,
              title: _onlyAdjustment ? '还没有校准记录' : '这个账户还没有流水',
              hint: _onlyAdjustment
                  ? null
                  : '点右上角 ⚙ 可以对账：填入实际余额，差额会自动补一笔校准流水',
            )
          else ...[
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  // 首屏只建前 60 行：这个列表最多 200 条，一次全建时每行都要
                  // watch 6 个 provider，进页面会有明显顿挫（真机上尤其明显）。
                  for (var i = 0; i < _shownCount(_entries!.length); i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 56),
                    EntryRow(entry: _entries![i]),
                  ],
                ],
              ),
            ),
            // 剩下的用「再显示」按钮接上，不做无限滚动 —— 记账的人翻 200 笔
            // 通常是为了找某一笔，滚动加载反而不如明确点两下。
            if (_shown < _entries!.length)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: TextButton(
                    onPressed: () => setState(() => _shown += _pageSize),
                    child: Text(
                      '还有 ${_entries!.length - _shown} 笔 · 再显示 $_pageSize 笔',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// 列表一次最多显示多少行（首屏 60，之后每点一次加 60）
  static const int _pageSize = 60;
  int _shown = _pageSize;

  int _shownCount(int total) => _shown < total ? _shown : total;

  // ------------------------------------------------------------ 首屏卡面

  Widget _hero(BuildContext context, Pocket p, int balance, String suffix,
      AppSettings settings) {
    switch (p.kind) {
      case PocketKind.credit:
        return _creditHero(context, p, balance, suffix, settings);
      case PocketKind.bank:
        return _bankHero(context, p, balance, suffix);
      case PocketKind.debt:
        return _debtHero(context, p, balance, suffix);
      case PocketKind.cash:
        return _cashHero(context, p, balance, suffix);
    }
  }

  /// 信用卡：深色卡面 + 已用进度 + 还款倒计时
  Widget _creditHero(BuildContext context, Pocket p, int balance, String suffix,
      AppSettings settings) {
    final limit = p.creditLimitCents;
    final used = balance;
    final ratio = limit <= 0 ? 0.0 : (used / limit).clamp(0.0, 1.0);
    final available = p.availableFrom(used);
    final days = p.daysUntilPaymentDue();
    final urgent = days != null && days <= 3;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3B3F58), Color(0xFF23263A)],
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.credit_card, size: 18, color: Colors.white70),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  p.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Colors.white),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  nameOf(p.currency),
                  style: const TextStyle(fontSize: 10.5, color: Colors.white70),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text('已用（还欠）',
              style: TextStyle(
                  fontSize: 12, color: Colors.white.withValues(alpha: 0.62))),
          const SizedBox(height: 4),
          Text(
            settings.hideAmounts ? '****' : '$suffix${centsToText(used)}',
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          if (limit > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 6,
                backgroundColor: Colors.white.withValues(alpha: 0.16),
                valueColor: AlwaysStoppedAnimation(
                  ratio >= 0.9
                      ? const Color(0xFFFF7A6B)
                      : Colors.white.withValues(alpha: 0.92),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('额度 ${_amt(limit)}',
                    style: TextStyle(
                        fontSize: 10.5,
                        color: Colors.white.withValues(alpha: 0.62))),
                const Spacer(),
                Text(
                  '可用 ${available == null ? '-' : _amt(available)}',
                  style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withValues(alpha: 0.9)),
                ),
              ],
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('还没设信用额度，点右上角编辑补上',
                  style: TextStyle(
                      fontSize: 10.5,
                      color: Colors.white.withValues(alpha: 0.55))),
            ),
          if (days != null) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(
                color: urgent
                    ? const Color(0xFFFF7A6B).withValues(alpha: 0.22)
                    : Colors.white.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.event_outlined,
                      size: 12,
                      color: urgent ? const Color(0xFFFFB4AA) : Colors.white70),
                  const SizedBox(width: 5),
                  Text(
                    days == 0 ? '今天还款' : '$days 天后还款（每月 ${p.paymentDueDay} 日）',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: urgent ? FontWeight.w700 : FontWeight.w500,
                      color: urgent
                          ? const Color(0xFFFFB4AA)
                          : Colors.white.withValues(alpha: 0.8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 银行储蓄卡：浅色卡面 + 左侧色条 + 「储蓄卡」标
  Widget _bankHero(BuildContext context, Pocket p, int balance, String suffix) {
    return Container(
      decoration: BoxDecoration(
        color: Palette.card(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.hairline(context)),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Container(
              width: 5,
              decoration: const BoxDecoration(
                color: Palette.info,
                borderRadius:
                    BorderRadius.horizontal(left: Radius.circular(18)),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.account_balance,
                            size: 16, color: Palette.info),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            p.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w600),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color:
                                Palette.info.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(5),
                          ),
                          child: const Text('储蓄卡',
                              style: TextStyle(
                                  fontSize: 10.5, color: Palette.info)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Text('余额',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                    const SizedBox(height: 4),
                    MoneyText(
                      balance,
                      suffix: suffix,
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        color: balance < 0
                            ? Palette.expense
                            : Palette.ink(context),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 负债：红系强调「还欠」
  Widget _debtHero(BuildContext context, Pocket p, int balance, String suffix) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Palette.expense.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Palette.expense.withValues(alpha: 0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.trending_down, size: 16, color: Palette.expense),
              const SizedBox(width: 6),
              Expanded(
                child: Text(p.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Palette.expense.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text('负债',
                    style: TextStyle(fontSize: 10.5, color: Palette.expense)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text('还欠',
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          const SizedBox(height: 4),
          MoneyText(
            balance,
            suffix: suffix,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: Palette.expense,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// 现金：最简
  Widget _cashHero(BuildContext context, Pocket p, int balance, String suffix) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppGlyph(p.glyph, size: 16),
              const SizedBox(width: 8),
              Text(p.title,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('现金',
                  style: TextStyle(
                      fontSize: 10.5, color: Palette.inkFaint(context))),
            ],
          ),
          const SizedBox(height: 12),
          Text('余额',
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          const SizedBox(height: 4),
          MoneyText(
            balance,
            suffix: suffix,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 类型明细

  /// 信用卡专属：额度 / 已用 / 可用 / 账单日 / 还款日
  Widget _creditFacts(BuildContext context, Pocket p, int balance) {
    final available = p.availableFrom(balance);
    return Panel(
      child: Column(
        children: [
          _factRow(
              context,
              '信用额度',
              p.creditLimitCents <= 0 ? '未设置' : _amt(p.creditLimitCents)),
          const Divider(height: 18),
          _factRow(context, '已用额度', _amt(balance)),
          const Divider(height: 18),
          _factRow(context, '可用额度',
              available == null ? '—' : _amt(available)),
          const Divider(height: 18),
          _factRow(context, '账单日',
              p.billingDay == null ? '未设置' : '每月 ${p.billingDay} 日'),
          const Divider(height: 18),
          _factRow(context, '还款日',
              p.paymentDueDay == null ? '未设置' : '每月 ${p.paymentDueDay} 日'),
          if (p.creditLimitCents <= 0 || p.paymentDueDay == null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 14, color: Palette.inkFaint(context)),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(
                    '补上额度和还款日后，这里会显示额度使用率和还款倒计时。',
                    style: TextStyle(
                        fontSize: 10.5, color: Palette.inkFaint(context)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 非信用卡：类型 / 币种 / 期初
  Widget _basicFacts(BuildContext context, Pocket p) {
    return Panel(
      child: Column(
        children: [
          _factRow(context, '账户类型', p.kind.label),
          const Divider(height: 18),
          _factRow(context, '币种', '${p.currency} · ${nameOf(p.currency)}'),
          const Divider(height: 18),
          _factRow(context, p.kind.isLiability ? '期初欠款' : '期初余额',
              _amt(p.openingCents)),
        ],
      ),
    );
  }

  /// 贷款：年利率 / 期数 / 还款方式 → 月供与总利息。
  ///
  /// 文案口径来自 core/loan.dart（编辑页的预览用的是同一份），
  /// 参数不全（没填利率或期数）时整块不显示。
  Widget _loanPanel(BuildContext context, Pocket p) {
    final text = LoanPlan.summary(
      principalCents: p.openingCents,
      annualRatePercent: p.annualRate,
      months: p.periods,
      method: p.repaymentMethod,
      symbol: symbolOf(p.currency),
    );
    if (text.isEmpty) return const SizedBox.shrink();
    final rate = p.annualRate == p.annualRate.roundToDouble()
        ? p.annualRate.toStringAsFixed(0)
        : p.annualRate.toString();
    return Column(
      children: [
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('还款计划',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkSoft(context))),
                  const Spacer(),
                  Text('年利率 $rate% · ${p.periods} 期 · ${LoanPlan.methodName(p.repaymentMethod)}',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkFaint(context))),
                ],
              ),
              const SizedBox(height: 6),
              Text(text,
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                      color: Palette.ink(context))),
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  /// 简称 / 卡号 / 备注。
  ///
  /// 这三项以前**只进数据库、界面上没有任何地方看得到**：用户填了卡号，
  /// 回头在账户详情里翻不到，等于白填。卡号只露后四位 —— 账户详情是
  /// 随手会被人看到的页面，完整卡号留在编辑页里看。
  Widget _identityPanel(BuildContext context, Pocket p) {
    final alias = p.alias.trim();
    final cardNo = p.cardNo.trim();
    final note = p.note.trim();
    if (alias.isEmpty && cardNo.isEmpty && note.isEmpty) {
      return const SizedBox.shrink();
    }
    final rows = <Widget>[
      if (alias.isNotEmpty) _factRow(context, '简称', alias),
      if (cardNo.isNotEmpty)
        _factRow(context, '卡号', _maskCardNo(cardNo)),
      if (note.isNotEmpty) _factRow(context, '备注', note),
    ];
    return Column(
      children: [
        Panel(
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(height: 18),
                rows[i],
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  static String _maskCardNo(String s) =>
      s.length <= 4 ? s : '**** ${s.substring(s.length - 4)}';

  /// 金额文本，**尊重「隐藏金额」开关**。
  ///
  /// 这个页面有大量拼接串（额度条、fact 行、本月合计），都不走 MoneyText，
  /// 直接 centsToText 会在用户开了「隐藏金额」时把数字漏在屏幕上。
  ///
  /// 有意不套的两处：余额校准弹窗（要让你看清"当前记录 vs 实际"才能改）
  /// 和校准成功后的 toast —— 那是用户主动发起的操作，打码反而没法用。
  /// [withSymbol] 默认带上货币符号：同一张卡上「还欠」带 ¥、「额度」不带 ¥
  /// 会让人以为两个数不是一回事。调用方自己已经拼了币种后缀（如 "HKD "）时传 false。
  String _amt(int cents, {bool withSymbol = true}) {
    final s = ref.read(settingsProvider);
    if (s.hideAmounts) return '****';
    return withSymbol ? '${s.symbol}${centsToText(cents)}' : centsToText(cents);
  }

  Widget _factRow(BuildContext context, String label, String value) {
    return Row(
      children: [
        Text(label,
            style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
        const SizedBox(width: 12),
        // 用 Expanded 而不是 Spacer + Text：备注/卡号可能很长，
        // 靠右排的同时要能截断，否则整行溢出黄条。
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Palette.ink(context)),
          ),
        ),
      ],
    );
  }

  /// 本月这个账户的进与出。转账单列，不能混进收支。
  /// 数据来自独立聚合查询（不是从「最近 200 条」里算的）。
  Widget _monthPanel(BuildContext context, Pocket p, String suffix) {
    final m = _month;
    if (m == null) {
      return const Panel(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Skeleton(height: 16, expand: true, radius: 6),
        ),
      );
    }
    return Panel(
      child: Column(
        children: [
          _factRow(context, '本月支出',
              '$suffix${_amt(m.outCents, withSymbol: false)}'),
          const Divider(height: 18),
          _factRow(context, '本月收入',
              '$suffix${_amt(m.inCents, withSymbol: false)}'),
          if (m.transferIn != 0 || m.transferOut != 0) ...[
            const Divider(height: 18),
            _factRow(
              context,
              '本月转账',
              '转入 ${_amt(m.transferIn)} · 转出 ${_amt(m.transferOut)}',
            ),
          ],
        ],
      ),
    );
  }
}
