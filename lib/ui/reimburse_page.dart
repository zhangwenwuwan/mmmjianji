import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
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

  Future<void> _mark(Entry e, int status) async {
    final store = await ref.read(storeProvider.future);
    await store.setReimburse(e.id, status);
    bumpRevision(ref);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(activeBookProvider).valueOrNull;
    final base = book?.baseCurrency ?? 'CNY';
    final rates = ref.watch(ratesProvider).valueOrNull ?? const {};
    final pockets =
        ref.watch(allPocketsProvider).valueOrNull ?? const <Pocket>[];
    final currencyOf = {for (final p in pockets) p.id: p.currency};

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
                    actionLabel: '标记已报销', onAction: (e) => _mark(e, 2)),
                _list(context, _done, totalOf(_done), base,
                    actionLabel: '撤回', onAction: (e) => _mark(e, 1)),
              ],
            ),
    );
  }

  Widget _list(
    BuildContext context,
    List<Entry> list,
    int total,
    String base, {
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
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
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
                      fontSize: 18, fontWeight: FontWeight.w700)),
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
                  title: Text(list[i].memo.isEmpty ? '未注明' : list[i].memo),
                  subtitle: Text(dayLabel(list[i].day),
                      style: const TextStyle(fontSize: 11)),
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
