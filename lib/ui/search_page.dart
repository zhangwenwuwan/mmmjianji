import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'amount_input.dart';
import 'common.dart';
import 'ledger_page.dart';
import 'recycle_bin_page.dart';
import 'motion.dart';
import 'theme.dart';

/// 搜索：关键词 + 类型 + 分类 + 金额区间 + 日期范围。
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _ctrl = TextEditingController();
  String _keyword = '';
  String? _flow;
  int? _bucketId;
  String? _bucketName;
  int? _minCents;
  int? _maxCents;
  DateTime? _from;
  DateTime? _to;

  /// 多选：账户 / 标签
  List<int> _pocketIds = const [];
  List<String> _pocketNames = const [];
  List<String> _tags = const [];

  /// 报销状态：null 不限 / 1 待报销 / 2 已报销
  int? _reimburse;

  /// 多条件之间是「同时满足」（AND）还是「满足任一」（OR）
  bool _matchAny = false;

  List<Entry> _results = const [];
  // 合计单独查（不带 LIMIT），和列表条数解耦
  int _totalIn = 0;
  int _totalOut = 0;
  bool _loading = false;
  bool _touched = false;
  int _seq = 0;

  /// 关键词输入的防抖。
  ///
  /// 原来是 onChanged 直接 _run()：每敲一个字符就跑一次全表 LIKE
  /// （memo / tags / 分类三列），几千条流水时输入明显跟不上手；
  /// 中文输入法组字阶段触发得更密。260ms 是"停手就出结果"和
  /// "别为半个词查库"的折中。
  Timer? _debounce;

  // ---- 批量模式（对齐原版搜索页的批量删除 / 改分类 / 改备注）----
  bool _batch = false;
  final Set<int> _selected = <int>{};

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  bool get _hasFilter =>
      _flow != null ||
      _bucketId != null ||
      _minCents != null ||
      _maxCents != null ||
      _from != null ||
      _to != null ||
      _pocketIds.isNotEmpty ||
      _tags.isNotEmpty ||
      _reimburse != null;

  Future<void> _run() async {
    final seq = ++_seq;
    setState(() {
      _keyword = _ctrl.text;
      // ⚠️ 只有第一次搜索才铺骨架。之后连续输入时保留上一批结果：
      // 每敲一个字就把整屏换成骨架，观感是"屏幕在抖"，
      // 而结果其实几十毫秒后就回来了。
      if (!_touched) _loading = true;
      _touched = true;
    });
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final list = await store.searchEntriesEx(
      book.id,
      keyword: _keyword,
      flow: _flow,
      bucketId: _bucketId,
      pocketIds: _pocketIds,
      tags: _tags,
      reimburse: _reimburse,
      minCents: _minCents,
      maxCents: _maxCents,
      from: _from,
      to: _to,
      matchAny: _matchAny,
    );
    // 连续输入只认最后一次结果
    if (!mounted || seq != _seq) return;
    setState(() {
      _results = list;
      _loading = false;
      // 结果集变了，之前勾的 id 可能已不在列表里。
      // 不清掉的话「删除选中的 N 条」删的是屏幕上看不见的账单 —— 误删不可恢复。
      if (_selected.isNotEmpty) {
        final alive = {for (final e in list) e.id};
        _selected.removeWhere((id) => !alive.contains(id));
      }
    });

    // 合计必须单独查：列表最多 300 条，拿列表相加会少算。
    // 命中 512 条时旧界面写「共 300 条」、合计也少 212 条的钱。
    final rates =
        ref.read(ratesProvider).valueOrNull ?? const <String, double>{};
    Future<int> sumOf(String flow) async {
      final raw = await store.searchTotals(
        book.id,
        keyword: _keyword,
        flow: flow,
        bucketId: _bucketId,
        pocketIds: _pocketIds,
        tags: _tags,
        reimburse: _reimburse,
        minCents: _minCents,
        maxCents: _maxCents,
        from: _from,
        to: _to,
        matchAny: _matchAny,
      );
      var t = 0;
      for (final r in raw) {
        t += toBaseCents(r.cents, r.currency, book.baseCurrency, rates);
      }
      return t;
    }

    final tin = await sumOf('in');
    final tout = await sumOf('out');
    if (!mounted || seq != _seq) return;
    setState(() {
      _totalIn = tin;
      _totalOut = tout;
    });
  }

  /// 通用多选面板：账户、标签都走它。
  ///
  /// 返回 null = 用户取消（不能和"选了 0 个"混淆，所以用 null 而不是空 list）。
  Future<List<String>?> _multiPick({
    required String title,
    required List<({String label, String value})> items,
    required Set<String> selected,
  }) {
    final picked = <String>{...selected};
    return showAppSheet<List<String>>(
      context: context,
      title: title,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final it in items)
                    CheckboxListTile(
                      value: picked.contains(it.value),
                      title: Text(it.label),
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      onChanged: (v) => setSheet(() {
                        if (v == true) {
                          picked.add(it.value);
                        } else {
                          picked.remove(it.value);
                        }
                      }),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, picked.toList()),
                  child: Text(picked.isEmpty ? '不限' : '确定（${picked.length}）'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickPockets() async {
    final rows = ref.read(balancesProvider).valueOrNull ?? const [];
    if (rows.isEmpty) {
      _toast('这个账本还没有账户');
      return;
    }
    final picked = await _multiPick(
      title: '选择账户',
      items: [
        for (final r in rows)
          (label: '${glyphLabel(r.pocket.glyph)} ${r.pocket.title}',
              value: '${r.pocket.id}'),
      ],
      selected: _pocketIds.map((e) => '$e').toSet(),
    );
    if (picked == null || !mounted) return;
    final ids = picked.map(int.parse).toList();
    setState(() {
      _pocketIds = ids;
      _pocketNames = [
        for (final id in ids)
          for (final r in rows)
            if (r.pocket.id == id) r.pocket.title,
      ];
    });
    _run();
  }

  Future<void> _pickTags() async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final tags = await store.allTags(book.id);
    if (!mounted) return;
    if (tags.isEmpty) {
      _toast('还没有用过标签');
      return;
    }
    final picked = await _multiPick(
      title: '选择标签',
      items: [for (final t in tags) (label: t, value: t)],
      selected: _tags.toSet(),
    );
    if (picked == null || !mounted) return;
    setState(() => _tags = picked);
    _run();
  }

  Future<void> _pickReimburse() async {
    const options = <(String, int?)>[
      ('不限', null),
      ('待报销', 1),
      ('已报销', 2),
    ];
    final picked = await showAppSheet<int?>(
      context: context,
      title: '报销状态',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            ListTile(
              title: Text(o.$1),
              trailing: _reimburse == o.$2 ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, o.$2),
            ),
        ],
      ),
    );
    // 取消（返回 null）与「不限」同值，这里按"不做改动"处理
    if (picked == null && _reimburse == null) return;
    setState(() => _reimburse = picked);
    _run();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).toast(msg);
  }

  Future<void> _pickBucket() async {
    final buckets = <Bucket>[
      ...?ref.read(bucketsProvider('out')).valueOrNull,
      ...?ref.read(bucketsProvider('in')).valueOrNull,
    ];
    final picked = await showAppSheet<Bucket?>(
      context: context,
      title: '选择分类',
      builder: (ctx) => ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.clear, size: 18),
            title: const Text('不限分类'),
            onTap: () => Navigator.pop(ctx, null),
          ),
          for (final b in buckets)
            ListTile(
              leading: AppGlyph(b.glyph, size: 18),
              title: Text(b.title),
              selected: b.id == _bucketId,
              onTap: () => Navigator.pop(ctx, b),
            ),
        ],
      ),
    );
    // 用户取消时 bottom sheet 返回 null，与「不限分类」同值：
    // 这里简化处理——取消等同于不清空（重新点一次即可）
    setState(() {
      _bucketId = picked?.id;
      _bucketName = picked?.title;
    });
    _run();
  }

  Future<void> _pickAmount() async {
    final minCtrl = TextEditingController(
        text: _minCents == null ? '' : (_minCents! / 100).toStringAsFixed(2));
    final maxCtrl = TextEditingController(
        text: _maxCents == null ? '' : (_maxCents! / 100).toStringAsFixed(2));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('金额区间'),
        content: Row(
          children: [
            Expanded(
              child: AppTextField(
                label: '最小',
                controller: minCtrl,
                hint: '不限',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: const [AmountInputFormatter()],
                textAlign: TextAlign.end,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: AppTextField(
                label: '最大',
                controller: maxCtrl,
                hint: '不限',
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: const [AmountInputFormatter()],
                textAlign: TextAlign.end,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              minCtrl.clear();
              maxCtrl.clear();
              Navigator.pop(ctx, true);
            },
            child: const Text('不限'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() {
      _minCents = parseAmountToCents(minCtrl.text);
      _maxCents = parseAmountToCents(maxCtrl.text);
    });
    _run();
  }

  Future<void> _pickDates() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _from != null && _to != null
          ? DateTimeRange(start: _from!, end: _to!)
          : null,
    );
    if (range == null) return;
    setState(() {
      _from = range.start;
      _to = range.end;
    });
    _run();
  }

  /// 搜索结果按日分组（一组一张卡 + 一行日期头）。
  ///
  /// 结果可能横跨好几个月，平铺的话「这笔是哪天的」只能靠猜 ——
  /// 首页的日分组头已经证明这个信息量是刚需。
  List<Widget> _groupedResults(BuildContext context, AppSettings settings) {
    final groups = <String, List<Entry>>{};
    for (final e in _results) {
      groups.putIfAbsent(dayKey(e.day), () => []).add(e);
    }
    final keys = groups.keys.toList()..sort((a, b) => b.compareTo(a));
    final out = <Widget>[];
    for (final key in keys) {
      final list = groups[key]!;
      final day = list.first.day;
      out.add(Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 6, left: 2),
        child: Row(
          children: [
            Text('${day.year}/${_pad(day.month)}/${_pad(day.day)}',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Palette.inkSoft(context))),
            const SizedBox(width: 6),
            Text(
              '${list.length} 笔',
              style:
                  TextStyle(fontSize: 12, color: Palette.inkFaint(context)),
            ),
          ],
        ),
      ));
      out.add(Panel(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (var i = 0; i < list.length; i++) ...[
              if (i > 0) const Divider(height: 1, indent: 56),
              EntryRow(
                entry: list[i],
                selected: _batch ? _selected.contains(list[i].id) : null,
                onTap: _batch
                    ? () => setState(() {
                          final id = list[i].id;
                          if (!_selected.add(id)) _selected.remove(id);
                        })
                    : null,
              ),
            ],
          ],
        ),
      ));
    }
    return out;
  }

  static String _pad(int v) => v < 10 ? '0$v' : '$v';

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 260), _run);
          },
          decoration: const InputDecoration(
            hintText: '搜备注、标签、分类…',
            filled: false,
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_ctrl.text.isNotEmpty || _hasFilter)
            IconButton(
              tooltip: '清空',
              onPressed: () {
                // 清空前先掐掉待触发的防抖：否则 260ms 后会用空关键词
                // 再查一次，界面从「空态」跳成「全部流水」。
                _debounce?.cancel();
                _ctrl.clear();
                setState(() {
                  _flow = null;
                  _bucketId = null;
                  _bucketName = null;
                  _minCents = null;
                  _maxCents = null;
                  _from = null;
                  _to = null;
                  _pocketIds = const [];
                  _pocketNames = const [];
                  _tags = const [];
                  _reimburse = null;
                  _matchAny = false;
                  _results = const [];
                });
              },
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: Column(
        children: [
          // 筛选条
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _pill('全部', _flow == null, () {
                  setState(() => _flow = null);
                  _run();
                }),
                _pill('支出', _flow == 'out', () {
                  setState(() => _flow = 'out');
                  _run();
                }),
                _pill('收入', _flow == 'in', () {
                  setState(() => _flow = 'in');
                  _run();
                }),
                _pill('转账', _flow == 'transfer', () {
                  setState(() => _flow = 'transfer');
                  _run();
                }),
                const SizedBox(width: 2),
                _pill(
                  _bucketName ?? '分类',
                  _bucketId != null,
                  _pickBucket,
                  icon: Icons.sell_outlined,
                ),
                _pill(
                  _minCents != null || _maxCents != null
                      ? '${_minCents == null ? '' : (settings.symbol) + (_minCents! / 100).toStringAsFixed(0)}'
                          '-${_maxCents == null ? '' : settings.symbol + (_maxCents! / 100).toStringAsFixed(0)}'
                      : '金额',
                  _minCents != null || _maxCents != null,
                  _pickAmount,
                  icon: Icons.paid_outlined,
                ),
                _pill(
                  _from == null ? '日期' : '${dayKey(_from!)}~',
                  _from != null,
                  _pickDates,
                  icon: Icons.date_range,
                ),
                _pill(
                  _pocketNames.isEmpty
                      ? '账户'
                      : (_pocketNames.length == 1
                          ? _pocketNames.first
                          : '账户 ${_pocketNames.length}'),
                  _pocketIds.isNotEmpty,
                  _pickPockets,
                  icon: Icons.account_balance_wallet_outlined,
                ),
                _pill(
                  _tags.isEmpty
                      ? '标签'
                      : (_tags.length == 1 ? _tags.first : '标签 ${_tags.length}'),
                  _tags.isNotEmpty,
                  _pickTags,
                  icon: Icons.local_offer_outlined,
                ),
                _pill(
                  _reimburse == null
                      ? '报销'
                      : (_reimburse == 1 ? '待报销' : '已报销'),
                  _reimburse != null,
                  _pickReimburse,
                  icon: Icons.receipt_long_outlined,
                ),
                // 条件之间的连接方式。默认「同时满足」，多个条件时才需要切换
                _pill(
                  _matchAny ? '满足任一' : '同时满足',
                  _matchAny,
                  () {
                    setState(() => _matchAny = !_matchAny);
                    if (_touched) _run();
                  },
                  icon: _matchAny ? Icons.merge_type : Icons.join_full,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const SkeletonList()
                : !_touched
                    ? const EmptyView(
                        icon: Icons.search,
                        title: '输入关键词，或点上面的筛选',
                        hint: '标签可以直接搜，如「报销」')
                    : _results.isEmpty
                        ? const EmptyView(
                            icon: Icons.search_off, title: '没有找到相关记录')
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                            children: [
                              Row(
                                children: [
                                  Text(
                                      _batch
                                          ? '已选 ${_selected.length} 条'
                                          // SQL 带 LIMIT 300，打到上限时不能再写「共 N 条」，
                                          // 否则下面的合计会少算，用户拿去对账就是错的。
                                          : (_results.length >= 300
                                              ? '前 300 条（还有更多）'
                                              : '共 ${_results.length} 条'),
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Palette.inkFaint(context))),
                                  const Spacer(),
                                  if (_batch) ...[
                                    PressScale(
                                      scale: 0.94,
                                      onTap: () => setState(() {
                                        if (_selected.length ==
                                            _results.length) {
                                          _selected.clear();
                                        } else {
                                          _selected
                                            ..clear()
                                            ..addAll(_results.map((e) => e.id));
                                        }
                                      }),
                                      child: Text(
                                        _selected.length == _results.length
                                            ? '取消全选'
                                            : '全选',
                                        style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Palette.brand(context)),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    PressScale(
                                      scale: 0.94,
                                      onTap: () => setState(() {
                                        _batch = false;
                                        _selected.clear();
                                      }),
                                      child: Text('退出批量',
                                          style: TextStyle(
                                              fontSize: 12,
                                              color: Palette.inkSoft(context))),
                                    ),
                                  ] else ...[
                                    PressScale(
                                      scale: 0.94,
                                      onTap: () =>
                                          setState(() => _batch = true),
                                      child: Text('批量',
                                          style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                              color: Palette.brand(context))),
                                    ),
                                    const SizedBox(width: 12),
                                    Text(
                                      '支出 ${settings.symbol}${centsToText(_totalOut)}'
                                      ' · 收入 ${settings.symbol}${centsToText(_totalIn)}',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Palette.inkFaint(context)),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 8),
                              // 按日分组：搜索结果是跨月的历史流水，
                              // 平铺 300 条时只能靠每行数字猜是哪天的。
                              ..._groupedResults(context, settings),
                            ],
                          ),
          ),
          // 批量操作条（选中后才可点）
          if (_batch)
            Container(
              decoration: BoxDecoration(
                color: Palette.card(context),
                border:
                    Border(top: BorderSide(color: Palette.hairline(context))),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                  child: Row(
                    children: [
                      _batchButton(context, Icons.category_outlined, '改分类',
                          _selected.isEmpty ? null : _batchChangeBucket),
                      const SizedBox(width: 8),
                      _batchButton(context, Icons.edit_note, '改备注',
                          _selected.isEmpty ? null : _batchSetMemo),
                      const SizedBox(width: 8),
                      _batchButton(context, Icons.delete_outline, '删除',
                          _selected.isEmpty ? null : _batchDelete,
                          danger: true),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _batchButton(
      BuildContext context, IconData icon, String label, VoidCallback? onTap,
      {bool danger = false}) {
    final color = onTap == null
        ? Palette.inkFaint(context)
        : (danger ? Palette.expense : Palette.brand(context));
    return Expanded(
      child: PressScale(
        scale: 0.95,
        onTap: onTap,
        child: Container(
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: onTap == null
                ? Palette.hairline(context).withValues(alpha: 0.35)
                : color.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: color)),
            ],
          ),
        ),
      ),
    );
  }

  List<int> get _ids => _selected.toList();

  Future<void> _batchDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除选中的 ${_selected.length} 条？'),
        content: const Text('会移入回收站，可随时恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('删除', style: TextStyle(color: Palette.expense))),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(storeProvider.future);
    final count = await store.deleteEntries(_ids);
    bumpRevision(ref);
    if (!mounted) return;
    setState(() {
      _batch = false;
      _selected.clear();
    });
    // 带按钮的 SnackBar 默认永久挂着（persist 默认 = 有 action），
    // 统一走 showActionSnack 才会 5 秒后自己收掉。
    showActionSnack(
      context,
      message: '已移入回收站 $count 条',
      actionLabel: '查看',
      onAction: () => Navigator.of(context)
          .push(AppPageRoute(page: const RecycleBinPage())),
    );
    await _run();
  }

  Future<void> _batchChangeBucket() async {
    final buckets = ref.read(bucketsProvider('out')).valueOrNull ?? const [];
    final picked = await showAppSheet<Object>(
      context: context,
      title: '改到哪个分类',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.clear, size: 18),
            title: const Text('设为未分类'),
            onTap: () => Navigator.pop(ctx, 0),
          ),
          const Divider(height: 1),
          for (final b in buckets)
            ListTile(
              dense: true,
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppGlyph(b.glyph, size: 16),
                  const SizedBox(width: 6),
                  Flexible(
                      child: Text(b.title, overflow: TextOverflow.ellipsis)),
                ],
              ),
              onTap: () => Navigator.pop(ctx, b.id),
            ),
        ],
      ),
    );
    if (picked == null) return;
    // 转账没有分类概念。把它们一起 UPDATE 会在 entries 里留下
    // 「转账 + bucket_id」的脏数据，之后按分类统计就会出鬼账。
    final transferIds = _results
        .where((e) => _selected.contains(e.id) && e.isTransfer)
        .map((e) => e.id)
        .toSet();
    final targets = _ids.where((id) => !transferIds.contains(id)).toList();
    if (targets.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).toast('选中的都是转账，转账没有分类');
      return;
    }
    final store = await ref.read(storeProvider.future);
    final count = await store.updateEntriesBucket(
        targets, picked == 0 ? null : picked as int);
    bumpRevision(ref);
    if (!mounted) return;
    setState(() {
      _batch = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context).toast(transferIds.isEmpty
          ? '已修改 $count 条'
          : '已修改 $count 条，跳过 ${transferIds.length} 条转账');
    await _run();
  }

  Future<void> _batchSetMemo() async {
    final ctrl = TextEditingController();
    final memo = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('给选中的 ${_selected.length} 条设同一备注'),
        content: AppTextField(
          label: '备注',
          controller: ctrl,
          hint: '留空 = 清空备注',
          autofocus: true,
          maxLength: 60,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (memo == null) return;
    final store = await ref.read(storeProvider.future);
    final count = await store.updateEntriesMemo(_ids, memo);
    bumpRevision(ref);
    if (!mounted) return;
    setState(() {
      _batch = false;
      _selected.clear();
    });
    ScaffoldMessenger.of(context)
        .toast('已修改 $count 条');
    await _run();
  }


  /// 筛选条上的胶囊。
  ///
  /// 为什么不用 ChoiceChip / ActionChip：
  /// 1. 两者的默认配色来自 M3 内部，选中态是淡紫底 + 白字（chipTheme 的
  ///    labelStyle 少了 color，字直接变成白色），白底白字根本看不见；
  /// 2. 一条筛选里混着两种 chip，字号/圆角/内边距都不一样，看着像两套控件。
  /// 现在统一自绘：选中 = 品牌色淡底 + 品牌色字，未选 = 白底 + 主文字色。
  Widget _pill(String label, bool active, VoidCallback onTap,
      {IconData? icon}) {
    final brand = Palette.brand(context);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: PressScale(
        scale: 0.95,
        onTap: onTap,
        child: Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color:
                active ? brand.withValues(alpha: 0.13) : Palette.card(context),
            borderRadius: BorderRadius.circular(15),
            border: Border.all(
              color: active
                  ? brand.withValues(alpha: 0.42)
                  : Palette.hairline(context),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon,
                    size: 13,
                    color: active ? brand : Palette.inkSoft(context)),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.15,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: active ? brand : Palette.ink(context),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
