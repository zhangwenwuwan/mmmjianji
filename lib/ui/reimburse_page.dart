import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'app_glyph.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 报销：待报销 / 已报销两栏，一键标记。
class ReimbursePage extends ConsumerStatefulWidget {
  const ReimbursePage({super.key});

  @override
  ConsumerState<ReimbursePage> createState() => _ReimbursePageState();
}

class _ReimbursePageState extends ConsumerState<ReimbursePage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  List<Entry> _pending = const [];
  List<Entry> _done = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final pending = await store.reimburseEntries(book.id, reimburse: 1);
    final done = await store.reimburseEntries(book.id, reimburse: 2);
    if (!mounted) return;
    setState(() {
      _pending = pending;
      _done = done;
      _loading = false;
    });
  }

  /// 标「已报销」：先让用户选报销到哪个账户，确认后金额自动加到那个账户。
  ///
  /// 2026-10-28 用户要求。以前只改一个标记位，钱不会进任何账户 ——
  /// 报销回来的钱得真的落到某个卡上，否则资产页永远是少的。
  Future<void> _markDone(Entry e) async {
    final book = await ref.read(activeBookProvider.future);
    final pockets =
        (ref.read(allPocketsProvider).valueOrNull ?? const <Pocket>[])
            .where((p) => !p.archived)
            .toList();
    if (!mounted) return;

    // 只列**同币种**账户：这笔钱原样回来，记进别的币种账户就得先折算，
    // 而报销单上没有汇率信息，硬折只会把账搞乱（和记账页同一条规则）。
    final currencyOfPocket = {for (final p in pockets) p.id: p.currency};
    final subject =
        e.currency ?? currencyOfPocket[e.pocketId] ?? book.baseCurrency;
    final candidates =
        pockets.where((p) => p.currency == subject).toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).toast('还没有 $subject 账户，先到资产页建一个再报销');
      return;
    }

    final symbol = ref.read(settingsProvider).symbol;
    // 「隐藏金额」也要挡住确认文案（审计 P2-8）：这是**当面**把手机给
    // 财务/同事看报销单的场景，金额写在提示里就白隐藏了。
    final hideAmounts = ref.read(settingsProvider).hideAmounts;
    final amount = hideAmounts ? '****' : '$symbol${centsToText(e.amountCents)}';
    final picked = await showAppSheet<int>(
      context: context,
      title: '报销到哪个账户',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              '确认后会把 $amount 作为一笔收入记入所选账户，账户余额同步增加。',
              style: TextStyle(fontSize: 12, color: Palette.inkSoft(ctx)),
            ),
          ),
          for (final p in candidates)
            ListTile(
              leading: SizedBox(
                width: 34,
                height: 34,
                child: AppGlyph(p.glyph, size: 20, fill: true, radius: 9),
              ),
              title: Text(p.displayName),
              subtitle: Text(
                p.currency,
                style: const TextStyle(fontSize: 12),
              ),
              trailing: Icon(Icons.chevron_right,
                  size: 18, color: Palette.inkFaint(ctx)),
              onTap: () => Navigator.of(ctx).pop(p.id),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
    if (picked == null || !mounted) return;

    final store = await ref.read(storeProvider.future);
    await store.reimburseTo(e.id, picked);
    bumpRevision(ref);
    await _load();
    if (!mounted) return;
    final name = candidates.firstWhere((p) => p.id == picked).displayName;
    ScaffoldMessenger.of(context).toast('$amount 已记入「$name」，可随时撤回');
  }

  /// 撤回报销：连同当初自动记入的那笔收入一起撤掉（否则余额会多出来）。
  Future<void> _unmark(Entry e) async {
    final store = await ref.read(storeProvider.future);
    await store.unreimburse(e.id);
    bumpRevision(ref);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).toast('已撤回，入账的那笔收入也删掉了');
  }

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(activeBookProvider).valueOrNull;
    final base = book?.baseCurrency ?? 'CNY';
    final rates = ref.watch(ratesProvider).valueOrNull ?? const {};
    final pockets =
        ref.watch(allPocketsProvider).valueOrNull ?? const <Pocket>[];
    final currencyOf = {for (final p in pockets) p.id: p.currency};
    // 报销列表里的都是支出，分类名从支出分类取：没写备注的账显示
    // 分类名，而不是一句没信息量的「未注明」（语音记账常不带备注，
    // 用户会误以为数据丢了 —— 2026-11-07 反馈）。
    final outBuckets =
        ref.watch(bucketsProvider('out')).valueOrNull ?? const <Bucket>[];
    final bucketTitleOf = {for (final b in outBuckets) b.id: b.title};

    int totalOf(List<Entry> list) => list.fold(
        0,
        (s, e) =>
            s +
            toBaseCents(
                e.amountCents, currencyOf[e.pocketId] ?? base, base, rates));

    return Scaffold(
      appBar: AppBar(
        title: const Text('报销'),
        bottom: TabBar(
          controller: _tab,
          tabs: [
            Tab(text: '待报销 ${_pending.length}'),
            Tab(text: '已报销 ${_done.length}'),
          ],
        ),
      ),
      body: _loading
          ? const SkeletonList()
          : TabBarView(
              controller: _tab,
              children: [
                _list(context, _pending, totalOf(_pending), base,
                    bucketTitleOf: bucketTitleOf,
                    actionLabel: '标记已报销', onAction: _markDone),
                _list(context, _done, totalOf(_done), base,
                    bucketTitleOf: bucketTitleOf,
                    actionLabel: '撤回', onAction: _unmark),
              ],
            ),
    );
  }

  /// 列表标题分级：备注 > 分类名 > 未注明。
  ///
  /// 之前只看备注，语音记账这类不带备注的账在待报销/已报销列表里
  /// 全是「未注明」，用户以为报销把数据弄丢了；其实数据一直都在，
  /// 把分类名亮出来就够了。
  String _titleOf(Entry e, Map<int, String> bucketTitleOf) {
    final memo = e.memo.trim();
    if (memo.isNotEmpty) return memo;
    final bucketTitle = e.bucketId == null ? null : bucketTitleOf[e.bucketId];
    if (bucketTitle != null && bucketTitle.isNotEmpty) return bucketTitle;
    return '未注明';
  }

  Widget _list(
    BuildContext context,
    List<Entry> list,
    int total,
    String base, {
    required Map<int, String> bucketTitleOf,
    required String actionLabel,
    required ValueChanged<Entry> onAction,
  }) {
    if (list.isEmpty) {
      return EmptyView(
        icon: Icons.receipt_outlined,
        title: '没有记录',
        hint: actionLabel == '标记已报销' ? '在记支出时打开「等着公司报销」' : null,
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      children: [
        Panel(
          child: Row(
            children: [
              Text('合计',
                  style: TextStyle(
                      fontSize: 12, color: Palette.inkFaint(context))),
              const Spacer(),
              MoneyText(total,
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Panel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < list.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                ListTile(
                  title: Text(_titleOf(list[i], bucketTitleOf)),
                  subtitle: Text(dayLabel(list[i].day),
                      style: const TextStyle(fontSize: 12)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      MoneyText(list[i].amountCents,
                          flow: 'out',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 6),
                      TextButton(
                        onPressed: () => onAction(list[i]),
                        child: Text(actionLabel,
                            style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
