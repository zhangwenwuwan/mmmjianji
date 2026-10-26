import 'app_glyph.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'account_detail_page.dart';
import 'book_manage_page.dart';
import 'charts.dart';
import 'common.dart';
import 'goals_page.dart';
import 'illustrations.dart';
import 'loans_page.dart';
import 'motion.dart';
import 'pocket_manage_page.dart' show showPocketEditor;
import 'reimburse_page.dart';
import 'theme.dart';

/// 一行账户余额（provider 返回的记录类型）
typedef _BalanceRow = ({Pocket pocket, int balanceCents});

/// 资产：净资产 = 资产 − 负债；下面是账户卡片和储蓄目标。
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

  @override
  Widget build(BuildContext context) {
    final balancesAsync = ref.watch(balancesProvider);
    final bookAsync = ref.watch(activeBookProvider);
    final settings = ref.watch(settingsProvider);
    final base = bookAsync.valueOrNull?.baseCurrency ?? 'CNY';
    final rates = ref.watch(ratesProvider).valueOrNull ?? const {};
    final goals = ref.watch(goalsProvider).valueOrNull ?? const [];
    // 待报销（应收）：不属于任何账户余额，但要算进「手头到底有多少」
    final pendingReimburse =
        ref.watch(pendingReimburseProvider).valueOrNull ?? 0;

    return balancesAsync.when(
      skipLoadingOnReload: true,
      loading: () => ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
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
          ref.invalidate(goalsProvider);
        },
      ),
      data: (list) {
        // 净资产要把外币折算成主币
        var assets = 0;
        var liabilities = 0;
        for (final b in list) {
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
          hiddenTotal +=
              toBaseCents(b.balanceCents, b.pocket.currency, base, rates);
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
          children: [
            // 净资产
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
                          Text('净资产',
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
                                        fontSize: 11,
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
                              : '$base ${centsToText(net)}'
                                  .replaceFirst('$base ', settings.symbol),
                          maxLines: 1,
                          softWrap: false,
                          style: const TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          _mini('普通资产', assets, settings, base),
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
                          size: 17, color: Palette.brand(context)),
                      const SizedBox(width: 8),
                      Text('待报销（应收）',
                          style: TextStyle(
                              fontSize: 12.5,
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
                      accounts: visible,
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
                                fontSize: 13.5,
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
                for (final kind in PocketKind.values) {
                  final rows =
                      visible.where((b) => b.pocket.kind == kind).toList();
                  if (rows.isEmpty) continue;
                  var subtotal = 0;
                  for (final r in rows) {
                    subtotal += toBaseCents(
                        r.balanceCents, r.pocket.currency, base, rates);
                  }
                  blocks.add(_kindGroup(
                    context,
                    kind.label,
                    rows,
                    base,
                    subtotal,
                    settings,
                    Duration(milliseconds: 80 + 40 * i),
                    liability: kind.isLiability,
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
                            size: 20, color: Palette.inkFaint(context)),
                        title: Text('已隐藏 ${hidden.length} 个账户',
                            style: TextStyle(
                                fontSize: 13, color: Palette.inkSoft(context))),
                        subtitle: Text(
                          '合计 ${settings.hideAmounts ? '****' : '${settings.symbol}${centsToText(hiddenTotal)}'}',
                          style: TextStyle(
                              fontSize: 11, color: Palette.inkFaint(context)),
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
                                style: const TextStyle(fontSize: 13.5)),
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
              const SizedBox(height: 18),
            ],
            SectionLabel(
              '储蓄目标',
              trailing: TextButton(
                onPressed: () => Navigator.of(context)
                    .push(AppPageRoute(page: const GoalsPage())),
                style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 0),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                child: const Text('管理', style: TextStyle(fontSize: 12)),
              ),
            ),
            if (goals.isEmpty)
              Panel(
                child: Row(
                  children: [
                    Icon(Icons.flag_outlined,
                        size: 20, color: Palette.inkFaint(context)),
                    const SizedBox(width: 10),
                    Text('给想买的东西攒钱',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.of(context)
                          .push(AppPageRoute(page: const GoalsPage())),
                      child: const Text('新建'),
                    ),
                  ],
                ),
              )
            else
              Column(
                children: [
                  for (final g in goals.take(3)) ...[
                    Panel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              AppGlyph(g.glyph, size: 15),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(g.title,
                                    style: const TextStyle(
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w500)),
                              ),
                              Text(
                                '${(g.savedCents / (g.targetCents <= 0 ? 1 : g.targetCents) * 100).clamp(0, 100).round()}%',
                                style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Palette.brand(context)),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: g.targetCents <= 0
                                  ? 0
                                  : (g.savedCents / g.targetCents)
                                      .clamp(0.0, 1.0),
                              minHeight: 6,
                              backgroundColor: Palette.hairline(context),
                              valueColor: AlwaysStoppedAnimation(
                                  Palette.brand(context)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
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
                      fontSize: 12.5,
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
                style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
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

  Widget _accountCard(BuildContext context, _BalanceRow row, String base) {
    final p = row.pocket;
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
                  const Icon(Icons.credit_card,
                      size: 16, color: Colors.white70),
                  const SizedBox(width: 6),
                  // 账户名没有 maxLength，不限宽的话长名字会把这一行撑溢出
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
                    child: const Text('信用卡',
                        style: TextStyle(fontSize: 9, color: Colors.white70)),
                  ),
                  Text(nameOf(p.currency),
                      style:
                          const TextStyle(fontSize: 10, color: Colors.white54)),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('还欠 ',
                      style: TextStyle(
                          fontSize: 11,
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
                    Text('额度 ${centsToText(limit)}',
                        style: TextStyle(
                            fontSize: 10,
                            color: Colors.white.withValues(alpha: 0.62))),
                    const Spacer(),
                    Text(
                      '可用 ${available == null ? '-' : centsToText(available)}',
                      style: TextStyle(
                          fontSize: 10,
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
                          fontSize: 10,
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
                  child: const Icon(Icons.account_balance,
                      size: 18, color: Color(0xFF3E7BB6)),
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
                                            fontSize: 13.5,
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
                                    child: const Text('储蓄卡',
                                        style: TextStyle(
                                            fontSize: 9,
                                            color: Color(0xFF3E7BB6))),
                                  ),
                                ],
                              ),
                              if (p.currency != base)
                                Text(p.currency,
                                    style: TextStyle(
                                        fontSize: 10,
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
              Icon(Icons.trending_down, size: 18, color: Palette.expense),
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
                                  fontSize: 13.5, fontWeight: FontWeight.w600)),
                        ),
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: Palette.expense.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('负债',
                              style: TextStyle(
                                  fontSize: 9, color: Palette.expense)),
                        ),
                      ],
                    ),
                    Text('还欠',
                        style: TextStyle(
                            fontSize: 10, color: Palette.inkFaint(context))),
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
            AppGlyph(p.glyph, size: 16),
            const SizedBox(width: 10),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(p.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w500)),
                  ),
                  const SizedBox(width: 5),
                  Text('现金',
                      style: TextStyle(
                          fontSize: 9.5, color: Palette.inkFaint(context))),
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
                fontSize: 10, color: Colors.white.withValues(alpha: 0.65))),
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
                  fontSize: 12.5,
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
        color: a.pocket.kind.isLiability
            ? Palette.expense
            : kSliceColors[i % kSliceColors.length],
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
                style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
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
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Palette.inkSoft(context),
                          fontFeatures: const [FontFeature.tabularFigures()]),
                    ),
                    const SizedBox(width: 6),
                    Text('${(it.cents / total * 100).round()}%',
                        style: TextStyle(
                            fontSize: 11, color: Palette.inkFaint(context))),
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
                      fontSize: 11, color: Palette.inkFaint(context))),
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
    final async = ref.watch(netWorthSeriesProvider(6));
    return Panel(
      child: async.when(
        skipLoadingOnReload: true,
        loading: () => const Skeleton(height: 96, radius: 16),
        error: (e, _) => ErrorRetryView(
          message: '读取失败',
          detail: '$e',
          onRetry: () async => ref.invalidate(netWorthSeriesProvider(6)),
        ),
        data: (points) {
          // 只有一两个月有数据时画出来就是几根平线，不如直说
          final withData = points.where((p) => p.netCents != 0).toList();
          if (withData.length < 2) {
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
          final maxAbs = points.fold<int>(1, (m, p) {
            final v = p.netCents.abs();
            return v > m ? v : m;
          });
          final first = points.first.netCents;
          final last = points.last.netCents;
          final diff = last - first;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('净资产走势',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkSoft(context))),
                  const Spacer(),
                  Text(
                    '${diff >= 0 ? '↑' : '↓'} ${centsToText(diff.abs())}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: diff >= 0 ? Palette.income : Palette.expense,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 74,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (final p in points)
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TweenAnimationBuilder<double>(
                              tween: Tween<double>(
                                begin: 0,
                                end: (p.netCents.abs() / maxAbs * 52)
                                    .clamp(3, 52)
                                    .toDouble(),
                              ),
                              duration: Motion.d(context, Motion.panel),
                              curve: XCurve.easeOut,
                              builder: (context, v, _) => Container(
                                height: v,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 5),
                                decoration: BoxDecoration(
                                  color: p.netCents >= 0
                                      ? Palette.brand(context)
                                          .withValues(alpha: 0.8)
                                      : Palette.expense.withValues(alpha: 0.8),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text('${p.month.month}',
                                style: TextStyle(
                                    fontSize: 9,
                                    color: Palette.inkFaint(context))),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 资产页快捷入口：报销 / 借贷 / 理财目标（参考版资产 tab 的三宫格）。
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
    String money(int cents) => hide ? '****' : '$sym${centsToText(cents)}';

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

    // 理财目标：目标总额 + 已存
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
            label: '理财',
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
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
