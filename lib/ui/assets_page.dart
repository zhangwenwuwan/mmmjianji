import 'app_glyph.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/pocket_types.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../services/icon_service.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'aa_receivable_page.dart';
import 'account_detail_page.dart';
import 'book_manage_page.dart';
import 'common.dart';
import 'goals_page.dart';
import 'illustrations.dart';
import 'loans_page.dart';
import 'motion.dart';
import 'pocket_manage_page.dart' show showPocketEditor;
import 'reimburse_page.dart';
import 'tab_header.dart';
import 'theme.dart';

/// 一行账户余额（provider 返回的记录类型）
typedef _BalanceRow = ({Pocket pocket, int balanceCents});

/// 资产：净资产 = 资产 − 负债；下面是快捷入口（报销/债务/目标）和账户卡片。
///
/// 对齐参考版：净资产卡下面有「净资产趋势 / 资产构成」分段切换，
/// 账户按「资产账户 / 负债账户」分组。
class AssetsPage extends ConsumerStatefulWidget {
  const AssetsPage({super.key});

  @override
  ConsumerState<AssetsPage> createState() => _AssetsPageState();
}

/// 资产页视图分段
enum _AssetView { trend, composition }

class _AssetsPageState extends ConsumerState<AssetsPage> {
  _AssetView _view = _AssetView.trend;

  /// 「已隐藏账户」分区是否展开（对齐原版 _HiddenAccountsSection）
  bool _showHidden = false;

  /// 微信 / 支付宝在资产页单列分组（用户要求），它们在 PocketKind 里仍是
  /// bank —— 这里只做展示归类，不碰余额/负债/统计口径。
  /// 老账户 typeId 可能为空（1.3.1 之前建的），用名称兜底。
  static bool _isWechat(Pocket p) {
    if (p.typeId == 'wechat' || p.typeId == 'wechatWallet') return true;
    return p.displayName.contains('微信');
  }

  static bool _isAlipay(Pocket p) {
    if (p.typeId == 'alipay') return true;
    return p.displayName.contains('支付宝');
  }

  @override
  Widget build(BuildContext context) {
    final balancesAsync = ref.watch(balancesProvider);
    final bookAsync = ref.watch(activeBookProvider);
    final settings = ref.watch(settingsProvider);
    final base = bookAsync.valueOrNull?.baseCurrency ?? 'CNY';
    final rates = ref.watch(ratesProvider).valueOrNull ?? const {};
    // 待报销（应收）：不属于任何账户余额，但要算进「手头到底有多少」
    final pendingReimburse =
        ref.watch(pendingReimburseProvider).valueOrNull ?? 0;
    // AA 待收：分摊出去、别人还没还我的钱（同样是应收，不进净资产）。
    final aaPending =
        ref.watch(aaReceivableProvider).valueOrNull?.pendingCents ?? 0;

    return balancesAsync.when(
      skipLoadingOnReload: true,
      loading: () => ListView(
        // 顶栏是浮在内容上的，顶部得留出它的高度
        padding: EdgeInsets.fromLTRB(12, TabHeader.heightOf(context) + 8, 12, 88),
        children: const [
          Skeleton(height: 112, radius: 8),
          SizedBox(height: 10),
          Skeleton(height: 86, radius: 8),
          SizedBox(height: 14),
          Skeleton(height: 14, expand: true, radius: 7),
          SizedBox(height: 8),
          Skeleton(height: 52, radius: 8),
          SizedBox(height: 8),
          Skeleton(height: 52, radius: 8),
        ],
      ),
      error: (e, _) => ErrorRetryView(
        message: '读取失败',
        detail: '$e',
        onRetry: () async {
          ref.invalidate(balancesProvider);
          ref.invalidate(netWorthSeriesProvider(6));
          ref.invalidate(netWorthCandlesProvider(6));
          ref.invalidate(goalsProvider);
        },
      ),
      data: (list) {
        // 净资产要把外币折算成主币。
        // 「不计入总资产」的账户仍在列表里（它的余额要能看、能校准），
        // 但**不进任何合计** —— 这是这个开关唯一的语义。
        var assets = 0;
        var liabilities = 0;
        for (final b in list) {
          if (!b.pocket.includeInAssets) continue;
          final baseCents =
              toBaseCents(b.balanceCents, b.pocket.currency, base, rates);
          if (b.pocket.kind.isLiability) {
            liabilities += baseCents;
          } else {
            assets += baseCents;
          }
        }
        final net = assets - liabilities;
        final visible = list.where((b) => !b.pocket.archived).toList();
        final hidden = list.where((b) => b.pocket.archived).toList();
        var hiddenTotal = 0;
        for (final b in hidden) {
          if (!b.pocket.includeInAssets) continue;
          hiddenTotal +=
              toBaseCents(b.balanceCents, b.pocket.currency, base, rates);
        }

        return ListView(
          // 顶栏是浮在内容上的，顶部得留出它的高度
        padding: EdgeInsets.fromLTRB(12, TabHeader.heightOf(context) + 8, 12, 88),
          children: [
            // 主数字放「普通资产」而不是「净资产」。
            // 用户反馈：净资产是大字时，一眼看到的是"扣完负债"的数，感觉账户里没钱；
            // 而"我到底有多少钱"其实该看普通资产。净资产降为下方小字，仍然一眼可见。
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Palette.brand(context),
                    Palette.brand(context).withValues(alpha: 0.78),
                  ],
                ),
                borderRadius: BorderRadius.circular(AppRadius.card),
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      child: CustomPaint(
                        painter: MountainPainter(
                            color: Colors.white.withValues(alpha: 0.12)),
                        size: Size.infinite,
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('普通资产',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white.withValues(alpha: 0.8))),
                          const Spacer(),
                          PressScale(
                            scale: 0.92,
                            onTap: () => Navigator.of(context)
                                .push(AppPageRoute(page: const BookManagePage())),
                            child: Row(
                              children: [
                                Text(
                                    '${glyphLabel(bookAsync.valueOrNull?.glyph ?? '')} '
                                    '${bookAsync.valueOrNull?.title ?? ''}',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color:
                                            Colors.white.withValues(alpha: 0.9))),
                                Icon(Icons.chevron_right,
                                    size: 14,
                                    color: Colors.white.withValues(alpha: 0.7)),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          settings.hideAmounts
                              ? '****'
                              : '$base ${centsToText(assets)}'
                                  .replaceFirst('$base ', settings.symbol),
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _mini('净资产', net, settings, base),
                          const SizedBox(width: 20),
                          _mini('债务', liabilities, settings, base),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // 待报销（应收）：单独一条，不混进净资产 ——
            // 它不计入净资产公式（那笔钱已经从账户里扣掉了），
            // 但用户需要知道「还有多少钱没报销回来」。
            if (pendingReimburse > 0) ...[
              const SizedBox(height: 8),
              PressScale(
                scale: 0.98,
                onTap: () => Navigator.of(context)
                    .push(AppPageRoute(page: const ReimbursePage())),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: Palette.brand(context).withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.receipt_long_outlined,
                          size: 18, color: Palette.brand(context)),
                      const SizedBox(width: 8),
                      Text('待报销（应收）',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Palette.brand(context))),
                      const Spacer(),
                      Text(
                        settings.hideAmounts
                            ? '****'
                            : '${settings.symbol}${centsToText(pendingReimburse)}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Palette.brand(context),
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Icon(Icons.chevron_right,
                          size: 16,
                          color: Palette.brand(context).withValues(alpha: 0.6)),
                    ],
                  ),
                ),
              ),
            ],
            // AA 待收（应收）：AA 垫付后别人还没还的部分，同样不进净资产。
            if (aaPending > 0) ...[
              const SizedBox(height: 8),
              PressScale(
                scale: 0.98,
                onTap: () => Navigator.of(context)
                    .push(AppPageRoute(page: const AaReceivablePage())),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: Palette.income.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.card),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.groups_outlined,
                          size: 18, color: Palette.income),
                      const SizedBox(width: 8),
                      Text('AA 待收（应收）',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Palette.income)),
                      const Spacer(),
                      Text(
                        settings.hideAmounts
                            ? '****'
                            : '${settings.symbol}${centsToText(aaPending)}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Palette.income,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      Icon(Icons.chevron_right,
                          size: 16,
                          color: Palette.income.withValues(alpha: 0.6)),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),

            // 快捷入口：报销 / 借贷 / 理财目标
            const _AssetQuickRow(),
            const SizedBox(height: 10),

            // 分段切换：净资产趋势 / 资产构成
            _SegmentedSwitch(
              value: _view,
              onChanged: (v) => setState(() => _view = v),
            ),
            const SizedBox(height: 8),
            Reveal(
              child: _view == _AssetView.trend
                  ? const NetWorthTrend()
                  : _Composition(
                      settings: settings,
                      base: base,
                      rates: rates,
                      // 构成图也是一张"钱从哪来"的汇总图，
                      // 不计入总资产的账户同样不该出现在里面。
                      accounts: [
                        for (final b in visible)
                          if (b.pocket.includeInAssets) b,
                      ],
                    ),
            ),
            const SizedBox(height: 18),

            // 一个账户都没有（新装 App 的初始状态）：给一个明确的下一步，
            // 别让用户对着一屏空分组发呆。资产页所有数字都来自账户，
            // 这一步绕不过去。
            if (visible.isEmpty && hidden.isEmpty)
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.account_balance_wallet_outlined,
                            size: 18, color: Palette.brand(context)),
                        const SizedBox(width: 8),
                        Text('还没有账户',
                            style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Palette.ink(context))),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '净资产、分类构成都来自账户。先建一个（现金 / 银行卡 / 支付宝 / 信用卡…），再开始记账。',
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: Palette.inkSoft(context)),
                    ),
                    const SizedBox(height: 10),
                    FilledButton(
                      onPressed: () => showPocketEditor(context, ref, null),
                      child: const Text('添加账户'),
                    ),
                  ],
                ),
              ),
            if (visible.isEmpty && hidden.isEmpty) const SizedBox(height: 18),

            // 账户按类型分层：现金 / 银行卡 / 信用卡 / 负债，
            // 每组带自己的小计。一木记账把这一层做成「普通/报销/债务/理财」，
            // 我们先用账户类型分，好处是每一组的钱从哪来一目了然，
            // 也不会把「报销」这种账单属性硬塞进账户体系。
            Builder(
              builder: (context) {
                var i = 0;
                final blocks = <Widget>[];
                // 2026-11-03：微信 / 支付宝从「银行卡」里拆出来单列一组。
                // 它们的 kind 仍是 bank（余额口径、负债语义都不变），
                // 差的只是展示分组 —— 所以只在这个页面按 typeId / 名称细分，
                // 不动 PocketKind，统计、净资产、账户合计全部不受影响。
                final groups = <({String title, bool Function(Pocket) match, bool liability})>[
                  (
                    title: '现金',
                    match: (p) => p.kind == PocketKind.cash,
                    liability: false
                  ),
                  (
                    title: '银行卡',
                    match: (p) =>
                        p.kind == PocketKind.bank &&
                        !_isWechat(p) &&
                        !_isAlipay(p),
                    liability: false
                  ),
                  (
                    title: '微信',
                    match: (p) => p.kind == PocketKind.bank && _isWechat(p),
                    liability: false
                  ),
                  (
                    title: '支付宝',
                    match: (p) => p.kind == PocketKind.bank && _isAlipay(p),
                    liability: false
                  ),
                  (
                    title: '信用卡',
                    match: (p) => p.kind == PocketKind.credit,
                    liability: true
                  ),
                  (
                    title: '负债',
                    match: (p) => p.kind == PocketKind.debt,
                    liability: true
                  ),
                ];
                for (final g in groups) {
                  final rows = visible.where((b) => g.match(b.pocket)).toList();
                  if (rows.isEmpty) continue;
                  var subtotal = 0;
                  for (final r in rows) {
                    if (!r.pocket.includeInAssets) continue;
                    subtotal += toBaseCents(
                        r.balanceCents, r.pocket.currency, base, rates);
                  }
                  blocks.add(_kindGroup(
                    context,
                    g.title,
                    rows,
                    base,
                    subtotal,
                    settings,
                    Duration(milliseconds: 80 + 40 * i),
                    liability: g.liability,
                  ));
                  blocks.add(const SizedBox(height: 18));
                  i++;
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: blocks,
                );
              },
            ),

            // 已隐藏（归档）账户：平时收成一行，点开才展开
            // 主列表小计 + 这里的合计 = 净资产，两边对得上账
            if (hidden.isNotEmpty) ...[
              Panel(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    PressScale(
                      scale: 0.98,
                      onTap: () => setState(() => _showHidden = !_showHidden),
                      child: ListTile(
                        leading: Icon(Icons.visibility_off_outlined,
                            size: 18, color: Palette.inkFaint(context)),
                        title: Text('已隐藏 ${hidden.length} 个账户',
                            style: TextStyle(
                                fontSize: 13, color: Palette.inkSoft(context))),
                        subtitle: Text(
                          '合计 ${settings.hideAmounts ? '****' : '${settings.symbol}${centsToText(hiddenTotal)}'}',
                          style: TextStyle(
                              fontSize: 12, color: Palette.inkFaint(context)),
                        ),
                        trailing: Icon(
                          _showHidden ? Icons.expand_less : Icons.expand_more,
                          size: 20,
                          color: Palette.inkFaint(context),
                        ),
                      ),
                    ),
                    if (_showHidden)
                      for (final b in hidden) ...[
                        const Divider(height: 1, indent: 56),
                        Opacity(
                          opacity: 0.65,
                          child: ListTile(
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            leading: AppGlyph(b.pocket.glyph, size: 15),
                            title: Text(b.pocket.displayName,
                                style: const TextStyle(fontSize: 14)),
                            subtitle: Text('已归档',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: Palette.inkFaint(context))),
                            trailing: MoneyText(
                              b.balanceCents,
                              suffix: amountSuffix(b.pocket.currency, base),
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// 账户列表：**按账户类型给不同的样子**（用户明确要求：银行卡要像银行卡，
  /// 信用卡要像信用卡）。参考原版 _AccountCard 按 type 分色的做法。
  /// 一组同类型账户：标题行（类型名 + 数量 + 小计）+ 账户卡片。
  ///
  /// 为什么要单独做小计：一木记账的资产页把「普通/报销/债务/理财」分层，
  /// 每层的钱是独立的，用户看「我银行卡一共多少」的频率远高于看总数。
  Widget _kindGroup(
    BuildContext context,
    String title,
    List<_BalanceRow> rows,
    String base,
    int subtotalCents,
    AppSettings settings,
    Duration delay, {
    bool liability = false,
  }) {
    return Reveal(
      delay: delay,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Row(
              children: [
                Text(title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Palette.inkSoft(context),
                    )),
                const SizedBox(width: 6),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: Palette.hairline(context),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text('${rows.length}',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: Palette.inkFaint(context))),
                ),
                const Spacer(),
                Text(
                  settings.hideAmounts
                      ? '****'
                      : '${settings.symbol}${centsToText(subtotalCents)}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    // 负债组的数字是「欠款」，标红才不会被当成资产
                    color: liability ? Palette.expense : Palette.inkSoft(context),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          _accountPanel(context, rows, base),
        ],
      ),
    );
  }

  Widget _accountPanel(
      BuildContext context, List<_BalanceRow> rows, String base) {
    if (rows.isEmpty) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('这一类还没有账户',
                style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
            const SizedBox(height: 4),
            Text('点右上角 + 新增一个，之后记账时就能选到它',
                style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          ],
        ),
      );
    }
    return Panel(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _accountCard(context, rows[i], base),
          ],
        ],
      ),
    );
  }

  /// 账户卡上的图标：用户自己换了**图片图标**就显示图片，
  /// 否则退回该 kind 的特征图标（卡面 / 银行 / 负债各有识别度）。
  ///
  /// 之前这里是写死的 `Icon(...)`，用户设了自定义图标在资产页根本看不到——
  /// 只有现金那一支用了 `AppGlyph`，等于「换图只在现金账户生效」。
  Widget _accountIcon(
    Pocket p, {
    required IconData fallback,
    required double size,
    required Color color,
  }) {
    if (!IconService.isImage(p.glyph)) {
      return Icon(fallback, size: size, color: color);
    }
    // 按尺寸分两档，别再按比例算：同样的 34 格子在两页里弧度要一样。
    final radius = size >= 36 ? AppRadius.tileLg : AppRadius.tileSm;
    return SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AppGlyph(p.glyph, size: size, fill: true, radius: radius),
      ),
    );
  }

  /// 账户卡上的小标签：优先显示**账户类型名**（支付宝 / 花呗 / 白条 / 自定义…），
  /// 老账户没有 type 才退回 kind 的通用叫法。
  ///
  /// 之前写死「现金」「储蓄卡」「信用卡」，支付宝账户也顶着「储蓄卡」标签，
  /// 信贷列的自定义账户同样顶着「信用卡」——换类型文案不跟着变。
  String _accountTag(Pocket p) {
    final t = pocketTypeOf(p.typeId);
    final label = t?.label ??
        switch (p.kind) {
          PocketKind.cash => '现金',
          PocketKind.bank => '储蓄卡',
          PocketKind.credit => '信用卡',
          PocketKind.debt => '负债',
        };
    // 「不计入总资产」的账户仍然显示在列表里（余额要能看、能校准），
    // 只是不进任何合计。不标一下的话，用户会以为"它能显示却不参与总计"是 bug。
    return p.includeInAssets ? label : '$label · 不计入';
  }

  Widget _accountCard(BuildContext context, _BalanceRow row, String base) {
    final p = row.pocket;
    final sym = ref.read(settingsProvider).symbol;
    final money = MoneyText(
      row.balanceCents,
      suffix: amountSuffix(p.currency, base),
      style: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w700,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );

    // 信用卡：做成卡面（深色渐变 + 白字 + 额度进度），一眼是信用卡
    if (p.kind == PocketKind.credit) {
      final limit = p.creditLimitCents;
      final owed = row.balanceCents;
      final usedRatio = limit <= 0 ? 0.0 : (owed / limit).clamp(0.0, 1.0);
      final available = limit <= 0 ? null : (limit - owed).clamp(0, limit);
      return PressScale(
        scale: 0.98,
        onTap: () => Navigator.of(context).push(
          AppPageRoute(page: AccountDetailPage(pocket: p)),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                  _accountIcon(p,
                      fallback: Icons.credit_card,
                      size: 16,
                      color: Colors.white70),
                  const SizedBox(width: 6),                  // 账户名没有 maxLength，不限宽的话长名字会把这一行撑溢出
                  Expanded(
                    child: Text(p.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(_accountTag(p),
                        style: const TextStyle(
                            fontSize: 10.5, color: Colors.white70)),                  ),
                  Text(nameOf(p.currency),
                      style:
                          const TextStyle(fontSize: 10.5, color: Colors.white54)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('还欠 ',
                      style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.65))),
                  DefaultTextStyle.merge(
                    style: const TextStyle(color: Colors.white),
                    child: money,
                  ),
                ],
              ),
              if (limit > 0) ...[
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: usedRatio,
                    minHeight: 5,
                    backgroundColor: Colors.white.withValues(alpha: 0.16),
                    valueColor: AlwaysStoppedAnimation(
                      usedRatio > 0.9
                          ? const Color(0xFFFF7A6B)
                          : Colors.white.withValues(alpha: 0.9),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    // 带货币符号：上一行「还欠」是 MoneyText（有 ¥），
                    // 这里裸 centsToText 没有 —— 同一张卡相邻两行一个有一个没有。
                    Text('额度 $sym${centsToText(limit)}',
                        style: TextStyle(
                            fontSize: 10.5,
                            color: Colors.white.withValues(alpha: 0.62))),
                    const Spacer(),
                    Text(
                      '可用 ${available == null ? '-' : '$sym${centsToText(available)}'}',
                      style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.85)),
                    ),
                  ],
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('没设额度，点进账户详情可以补上',
                      style: TextStyle(
                          fontSize: 10.5,
                          color: Colors.white.withValues(alpha: 0.5))),
                ),
            ],
          ),
        ),
      );
    }

    // 银行卡：浅色卡面 + 左侧色条 + 「储蓄卡」标签
    if (p.kind == PocketKind.bank) {
      return PressScale(
        scale: 0.98,
        onTap: () => Navigator.of(context).push(
          AppPageRoute(page: AccountDetailPage(pocket: p)),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(0, 0, 12, 0),
          decoration: BoxDecoration(
            color: Palette.paper(context),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Palette.hairline(context)),
          ),
          child: IntrinsicHeight(
            child: Row(
              children: [
                Container(
                  width: 4,
                  decoration: const BoxDecoration(
                    color: Color(0xFF3E7BB6),
                    borderRadius:
                        BorderRadius.horizontal(left: Radius.circular(14)),
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _accountIcon(p,
                      fallback: Icons.account_balance,
                      size: 18,
                      color: const Color(0xFF3E7BB6)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(p.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w600)),
                                  ),
                                  const SizedBox(width: 5),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF3E7BB6)
                                          .withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(_accountTag(p),
                                        style: const TextStyle(
                                            fontSize: 10.5,
                                            color: Color(0xFF3E7BB6))),
                                  ),
                                ],
                              ),
                              if (p.currency != base)
                                Text(p.currency,
                                    style: TextStyle(
                                        fontSize: 10.5,
                                        color: Palette.inkFaint(context))),
                            ],
                          ),
                        ),
                        money,
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 负债：红系，强调「还欠」
    if (p.kind == PocketKind.debt) {
      return PressScale(
        scale: 0.98,
        onTap: () => Navigator.of(context).push(
          AppPageRoute(page: AccountDetailPage(pocket: p)),
        ),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: Palette.expense.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Palette.expense.withValues(alpha: 0.20)),
          ),
          child: Row(
            children: [
              _accountIcon(p,
                  fallback: Icons.trending_down,
                  size: 18,
                  color: Palette.expense),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(p.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Palette.expense.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(_accountTag(p),
                              style: TextStyle(
                                  fontSize: 10.5, color: Palette.expense)),
                        ),
                      ],
                    ),
                    Text('还欠',
                        style: TextStyle(
                            fontSize: 10.5, color: Palette.inkFaint(context))),
                  ],
                ),
              ),
              money,
            ],
          ),
        ),
      );
    }

    // 现金：最简一行（它本来就不需要特征）
    return PressScale(
      scale: 0.98,
      onTap: () => Navigator.of(context).push(
        AppPageRoute(page: AccountDetailPage(pocket: p)),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: Palette.paper(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Palette.hairline(context)),
        ),
        child: Row(
          children: [
            // 现金没有特征图标，emoji 走 AppGlyph；自定义图片则按圆角方块裁一次，
            // 否则 16px 的方图直接贴上去显得毛边、和别的账户卡不齐。
            IconService.isImage(p.glyph)
                ? _accountIcon(p,
                    fallback: Icons.payments_outlined,
                    size: 16,
                    color: Palette.inkSoft(context))
                : AppGlyph(p.glyph, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(p.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                  ),
                  const SizedBox(width: 5),
                  Text(_accountTag(p),
                      style: TextStyle(
                          fontSize: 10.5, color: Palette.inkFaint(context))),
                ],
              ),
            ),
            money,
          ],
        ),
      ),
    );
  }

  Widget _mini(String label, int cents, AppSettings settings, String base) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 10.5, color: Colors.white.withValues(alpha: 0.65))),
        const SizedBox(height: 2),
        Text(
          settings.hideAmounts
              ? '****'
              : '${settings.symbol}${centsToText(cents)}',
          style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()]),
        ),
      ],
    );
  }
}

/// 资产页分段切换：净资产趋势 / 资产构成。
class _SegmentedSwitch extends StatelessWidget {
  const _SegmentedSwitch({required this.value, required this.onChanged});

  final _AssetView value;
  final ValueChanged<_AssetView> onChanged;

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    Widget seg(_AssetView v, String label) => Expanded(
          child: PressScale(
            scale: 0.95,
            onTap: () => onChanged(v),
            child: AnimatedContainer(
              duration: Motion.d(context, Motion.small),
              curve: XCurve.easeOut,
              padding: const EdgeInsets.symmetric(vertical: 8),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: value == v
                    ? brand.withValues(alpha: 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: value == v ? FontWeight.w700 : FontWeight.w500,
                  color: value == v ? brand : Palette.inkSoft(context),
                ),
              ),
            ),
          ),
        );

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Palette.card(context),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Palette.hairline(context)),
      ),
      child: Row(
        children: [
          seg(_AssetView.trend, '净资产趋势'),
          seg(_AssetView.composition, '资产构成'),
        ],
      ),
    );
  }
}

/// 资产构成：按账户占比画一条堆叠条 + 图例（前 6 个 + 其他）。
class _Composition extends StatelessWidget {
  const _Composition({
    required this.settings,
    required this.base,
    required this.rates,
    required this.accounts,
  });

  final AppSettings settings;
  final String base;
  final Map<String, double> rates;
  final List<_BalanceRow> accounts;

  @override
  Widget build(BuildContext context) {
    final items = <({String label, String glyph, int cents, Color color})>[];
    for (var i = 0; i < accounts.length; i++) {
      final a = accounts[i];
      final cents =
          toBaseCents(a.balanceCents, a.pocket.currency, base, rates).abs();
      items.add((
        label: a.pocket.displayName,
        glyph: a.pocket.glyph,
        cents: cents,
        // 2026-10-28：账户配色也走固定色板（按账户名取），
        // 不再按 i 取 —— 否则排序一变，同一个账户的色就变了。
        // 负债固定用支出红（它是"欠的钱"，不该跟资产混在一个色板里）。
        color: a.pocket.kind.isLiability
            ? Palette.expense
            : Palette.categoryColor(context, a.pocket.displayName),
      ));
    }
    items.sort((x, y) => y.cents.compareTo(x.cents));
    final total = items.fold<int>(0, (s, e) => s + e.cents);

    if (total <= 0) {
      return Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('还没有可统计的余额',
                style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
            const SizedBox(height: 4),
            Text('给账户填上期初余额，这里就会出现占比图',
                style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
          ],
        ),
      );
    }

    final shown = items.take(6).toList();
    final rest = items.skip(6).fold<int>(0, (s, e) => s + e.cents);

    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('资产构成',
              style: TextStyle(fontSize: 12, color: Palette.inkSoft(context))),
          const SizedBox(height: 10),
          // 堆叠条：整体长出来
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: 1),
            duration: Motion.d(context, const Duration(milliseconds: 600)),
            curve: XCurve.easeOut,
            builder: (context, v, _) => Row(
              children: [
                for (final it in shown)
                  if (it.cents > 0)
                    Expanded(
                      flex: math.max(1, (it.cents * v).round()),
                      child: Container(
                        height: 12,
                        margin: const EdgeInsets.only(right: 2),
                        decoration: BoxDecoration(
                          color: it.color,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                if (rest > 0)
                  Expanded(
                    flex: math.max(1, (rest * v).round()),
                    child: Container(
                      height: 12,
                      margin: const EdgeInsets.only(right: 2),
                      decoration: BoxDecoration(
                        color: Palette.inkFaint(context),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          for (final it in shown) ...[
            if (it.cents > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: it.color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 7),
                    AppGlyph(it.glyph, size: 12),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(it.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12, color: Palette.ink(context))),
                    ),
                    Text(
                      settings.hideAmounts
                          ? '****'
                          : '${settings.symbol}${centsToText(it.cents)}',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Palette.inkSoft(context),
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                    const SizedBox(width: 6),
                    Text('${(it.cents / total * 100).round()}%',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                  ],
                ),
              ),
          ],
          if (rest > 0)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                  '其他 ${items.length - shown.length} 个账户合计 '
                  '${settings.hideAmounts ? '****' : '${settings.symbol}${centsToText(rest)}'}',
                  style: TextStyle(
                      fontSize: 12, color: Palette.inkFaint(context))),
            ),
        ],
      ),
    );
  }
}

/// 近 6 个月净资产走势（柱状 + 首尾差额）。
///
/// 公开是为了让统计页复用同一份图表与口径——两处各画一版必然会走样。
class NetWorthTrend extends ConsumerWidget {
  const NetWorthTrend({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(netWorthCandlesProvider(6));
    return Panel(
      child: async.when(
        skipLoadingOnReload: true,
        loading: () => const Skeleton(height: 96, radius: 16),
        error: (e, _) => ErrorRetryView(
          message: '读取失败',
          detail: '$e',
          onRetry: () async => ref.invalidate(netWorthCandlesProvider(6)),
        ),
        data: (candles) {
          // 只有一两个月有数据时画出来就是几根平线，不如直说
          // 有蜡烛可看 = 至少两个月、且其中至少一个月净值真的动过。
          // 全是平线（只有期初、从没记过账）时不画，免得像坏了。
          final moved = candles.where((c) => c.highCents != c.lowCents).length;
          if (candles.length < 2 || moved == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('净资产走势',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context))),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Icon(Icons.show_chart,
                        size: 18, color: Palette.inkFaint(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('数据还不够，再记几个月就能看趋势了',
                          style: TextStyle(
                              fontSize: 12, color: Palette.inkFaint(context))),
                    ),
                  ],
                ),
              ],
            );
          }
          final first = candles.first.openCents;
          final last = candles.last.closeCents;
          final diff = last - first;
          // 涨红跌绿（中国股市习惯）。净资产是「值」，跟涨跌走，不跟收支走 ——
          // 想换回「绿涨红跌」只要把下面两个颜色对调（rise/fall），一处就够。
          final rise = Palette.expense;
          final fall = Palette.income;
          final diffColor = diff >= 0 ? rise : fall;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('净资产走势',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkSoft(context))),
                  const SizedBox(width: 6),
                  Text('月K',
                      style: TextStyle(
                          fontSize: 10.5, color: Palette.inkFaint(context))),
                  const Spacer(),
                  Text(
                    '${diff >= 0 ? '↑' : '↓'} ${centsToText(diff.abs())}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: diffColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 92,
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: 1),
                  duration: Motion.d(context, Motion.panel),
                  curve: XCurve.easeOut,
                  builder: (context, t, _) => CustomPaint(
                    size: Size.infinite,
                    painter: _NetWorthCandlePainter(
                      candles: candles,
                      rise: rise,
                      fall: fall,
                      zeroLine: Palette.hairline(context),
                      progress: t,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (final c in candles)
                    Expanded(
                      child: Center(
                        child: Text('${c.month.month}',
                            style: TextStyle(
                                fontSize: 10.5,
                                color: Palette.inkFaint(context))),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 净资产蜡烛图（月 K）。
///
/// 形态：实体 = 开→收，上下影线 = 当月净值最高/最低。
/// 数据由 [NetWorthTrend] 背后的逐日净值按月切出来，**不是估算的影线**。
///
/// 为什么自定义画而不是用图表库：只有一个序列、一种形态，引一个几百 KB 的
/// 图表库不划算；这里 60 行就能画完，还能跟着 App 的圆角/描边风格走。
class _NetWorthCandlePainter extends CustomPainter {
  const _NetWorthCandlePainter({
    required this.candles,
    required this.rise,
    required this.fall,
    required this.zeroLine,
    required this.progress,
  });

  final List<NetWorthCandle> candles;
  final Color rise;
  final Color fall;
  final Color zeroLine;

  /// 0→1 的入场进度：所有影线从「开盘价」长到最终形态。
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.width <= 0 || size.height <= 0) return;

    var minV = candles.first.lowCents.toDouble();
    var maxV = candles.first.highCents.toDouble();
    for (final c in candles) {
      final lo = c.lowCents.toDouble();
      final hi = c.highCents.toDouble();
      if (lo < minV) minV = lo;
      if (hi > maxV) maxV = hi;
    }
    // 全是同一个值（比如只有期初、没记过账）：撑开一点，否则除零
    if (maxV - minV < 1) {
      maxV += 100;
      minV -= 100;
    }
    // 上下各留 8%：影线不顶到边，看着才像行情图
    final pad = (maxV - minV) * 0.08;
    minV -= pad;
    maxV += pad;

    const inset = 1.0;
    final h = size.height - inset * 2;
    double y(double v) => inset + (maxV - v) / (maxV - minV) * h;

    // 零轴：跨零时给一条细线，正负一眼分得清
    if (minV < 0 && maxV > 0) {
      canvas.drawLine(
        Offset(0, y(0)),
        Offset(size.width, y(0)),
        Paint()
          ..color = zeroLine
          ..strokeWidth = 1,
      );
    }

    final slot = size.width / candles.length;
    final bodyW = (slot * 0.56).clamp(3.0, 18.0);
    final wick = Paint()
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;

    for (var i = 0; i < candles.length; i++) {
      final c = candles[i];
      final cx = slot * (i + 0.5);
      // 入场动画：从开盘价往最终值插值
      double at(int v) => c.openCents + (v - c.openCents) * progress;

      final open = at(c.openCents);
      final close = at(c.closeCents);
      final high = at(c.highCents);
      final low = at(c.lowCents);
      final rising = c.closeCents >= c.openCents;
      final color = rising ? rise : fall;

      wick.color = color;
      canvas.drawLine(Offset(cx, y(high)), Offset(cx, y(low)), wick);

      final top = y(math.max(open, close));
      final bottom = y(math.min(open, close));
      if (bottom - top < 1.2) {
        // 十字星：开收几乎相等，画一根粗横线代替实体
        canvas.drawLine(
          Offset(cx - bodyW / 2, top),
          Offset(cx + bodyW / 2, top),
          Paint()
            ..color = color
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round,
        );
      } else {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(cx - bodyW / 2, top, cx + bodyW / 2, bottom),
            const Radius.circular(1.5),
          ),
          Paint()..color = color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _NetWorthCandlePainter old) =>
      old.progress != progress ||
      !identical(old.candles, candles) ||
      old.rise != rise ||
      old.fall != fall ||
      old.zeroLine != zeroLine;
}

/// 资产页快捷入口：报销 / 债务 / 目标（参考版资产 tab 的三宫格）。
/// 资产页三张入口卡（对齐一木：每张带两个数字）。
///
/// 一木把「报销 / 债务 / 理财」做成三张卡，各带两个关键数字
/// （可报·已报 / 应付·应收 / 总额·盈亏）—— 用户不用点进去就知道有多少。
/// 我们原来只有三个图标入口，数字全藏在二级页面里。
class _AssetQuickRow extends ConsumerWidget {
  const _AssetQuickRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final hide = settings.hideAmounts;
    final sym = settings.symbol;
    final rates = ref.watch(ratesProvider).valueOrNull ?? const {};
    final base =
        ref.watch(activeBookProvider).valueOrNull?.baseCurrency ?? 'CNY';
    int cv(int cents, String cur) => toBaseCents(cents, cur, base, rates);
    // 每张卡只有 1/3 屏宽，完整金额（¥6,000.00）会被 ellipsis 截成「¥6,...」。
    // 所以这里走 compact：一万以上折成「6.0万」，其余仍是完整数字。
    String money(int cents) => hide
        ? '****'
        : moneyLabel(cents,
            symbol: sym, compact: true, alwaysTwoDecimals: false);

    // 报销：待报销金额 + 已报销笔数
    final pending = ref.watch(pendingReimburseProvider).valueOrNull ?? 0;
    final doneCount = ref.watch(reimburseDoneProvider).valueOrNull ?? 0;

    // 债务：应收 / 应付
    final debts = ref.watch(debtsProvider).valueOrNull ?? const [];
    final debtPaid = ref.watch(debtPaidProvider).valueOrNull ?? const {};
    var lend = 0, borrow = 0;
    for (final d in debts) {
      final left = (d.principalCents - (debtPaid[d.id] ?? 0))
          .clamp(0, 1 << 62);
      final cents = cv(left, d.currency);
      if (d.direction == 'lend') {
        lend += cents;
      } else {
        borrow += cents;
      }
    }

    // 目标：目标总额 + 已存（底部那块重复的「储蓄目标」已删，这里是唯一入口）
    final goals = ref.watch(goalsProvider).valueOrNull ?? const [];
    final goalTotal =
        goals.fold<int>(0, (s, g) => s + cv(g.targetCents, base));
    final goalSaved =
        goals.fold<int>(0, (s, g) => s + cv(g.savedCents, base));

    // ⚠️ 不能用 crossAxisAlignment: stretch —— 这个 Row 在可纵向滚动的
    // Column 里，高度是无界的，stretch 会把无限高度传给子节点直接崩
    // （"BoxConstraints forces an infinite height"）。改用最小高度约束，
    // 三张卡视觉上仍然等高。
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _card(
            context,
            icon: Icons.assignment_turned_in_outlined,
            label: '报销',
            top: ('待报销', money(pending)),
            bottom: ('已报销', '$doneCount 笔'),
            page: const ReimbursePage(),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _card(
            context,
            icon: Icons.trending_down,
            label: '债务',
            top: ('应收', money(lend)),
            bottom: ('应付', money(borrow)),
            page: const LoansPage(),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _card(
            context,
            icon: Icons.savings_outlined,
            // 2026-10-28：原来叫「理财」，和页面底部的「储蓄目标」是同一个页面
            // 的两个入口。底部那块已经删掉，这里就是唯一入口，直接把名字改成
            // 用户嘴里的叫法。副标题的两个数字不动（目标总额 / 已存）。
            label: '目标',
            top: ('目标', money(goalTotal)),
            bottom: ('已存', money(goalSaved)),
            page: const GoalsPage(),
          ),
        ),
      ],
    );
  }

  Widget _card(
    BuildContext context, {
    required IconData icon,
    required String label,
    required (String, String) top,
    required (String, String) bottom,
    required Widget page,
  }) {
    final brand = Palette.brand(context);
    return PressScale(
      scale: 0.97,
      onTap: () => Navigator.of(context).push(AppPageRoute(page: page)),
      child: Container(
        // 最小高度：三张卡内容行数不同，靠这个保证视觉等高
        constraints: const BoxConstraints(minHeight: 74),
        padding: const EdgeInsets.fromLTRB(9, 10, 9, 9),
        decoration: BoxDecoration(
          color: Palette.card(context),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: Palette.hairline(context)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: brand),
                const SizedBox(width: 5),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Palette.ink(context))),
              ],
            ),
            const SizedBox(height: 8),
            _line(context, top.$1, top.$2, brand),
            const SizedBox(height: 3),
            _line(context, bottom.$1, bottom.$2, Palette.inkSoft(context)),
          ],
        ),
      ),
    );
  }

  Widget _line(BuildContext context, String label, String value, Color color) {
    return Row(
      children: [
        Text(label,
            style: TextStyle(fontSize: 10.5, color: Palette.inkFaint(context))),
        const Spacer(),
        Flexible(
          // 再长的数字也让它按比例缩一点，而不是截成「¥6,...」——
          // 卡片宽度是固定的 1/3 屏，金额位数却不受控。
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
