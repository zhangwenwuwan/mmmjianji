import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../core/subscription.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'amount_input.dart';
import 'app_glyph.dart';
import 'common.dart';
import 'entry_peek.dart';
import 'motion.dart';
import 'theme.dart';
import 'wheel_date_picker.dart';

/// 新增会员时的图标候选。
///
/// 和分类一样只留一排：找图标比想名字还慢，想用别的走第一个格子的「相册」，
/// 自定义图片不受这个清单限制。
const kSubsGlyphs = ['📺', '🎬', '🎵', '☁️', '📦', '🎮', '📚', '💼', '🛒', '🤖'];

/// 表单里「常用时长」的快捷键。自定义仍然随便填（用户明确要 12 / 15 这类任意月数）。
const _kQuickMonths = [1, 3, 6, 12, 24, 36];

/// 会员订阅管理：一个会员一张卡，按到期日升序（快到期的在最上面）。
///
/// 数据层只存「开卡日期 + 月数」，到期日每次现算（[LedgerStore.addMonths]），
/// 改时长时不用回写日期，也不会出现两者对不上的脏数据。
class SubscriptionsPage extends ConsumerWidget {
  const SubscriptionsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(subscriptionsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('会员订阅管理'),
        actions: [
          IconButton(
            tooltip: '新增会员',
            onPressed: () => _openEditor(context, ref, null),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(),
        error: (e, _) => ErrorRetryView(
          message: '读取失败',
          detail: '$e',
          onRetry: () async => ref.invalidate(subscriptionsProvider),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.event_available_outlined,
                        size: 40, color: Palette.inkFaint(context)),
                    const SizedBox(height: 12),
                    Text('还没有会员订阅',
                        style: TextStyle(
                            fontSize: 14, color: Palette.inkSoft(context))),
                    const SizedBox(height: 6),
                    Text('点右上角 + 添加一个，到期前会提醒你',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                  ],
                ),
              ),
            );
          }
          final today = DateTime.now();
          // 关联的那笔账：一次取齐，取不到（已永久删除）就不在 Map 里。
          final links = ref.watch(subscriptionEntriesProvider).valueOrNull ??
              const <int, Entry>{};
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            itemCount: list.length + 1,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              if (i == list.length) return _footer(context);
              return _card(context, ref, list[i], today, links);
            },
          );
        },
      ),
    );
  }

  Widget _footer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
      child: Text(
        '到期提醒需要先在「我的 → 记账提醒」里打开「到期提醒」；'
        '每个会员可以单独设提前几天提醒，填 0 表示不提醒。',
        style: TextStyle(fontSize: 12, color: Palette.inkFaint(context)),
      ),
    );
  }

  Widget _card(BuildContext context, WidgetRef ref, Subscription s,
      DateTime today, Map<int, Entry> links) {
    final cd = countdownOf(s, today);
    final color = switch (cd.state) {
      SubscriptionState.expired || SubscriptionState.today => Palette.expense,
      SubscriptionState.soon => Palette.expense.withValues(alpha: 0.82),
      SubscriptionState.normal => Palette.inkSoft(context),
    };
    return Panel(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: () => _openEditor(context, ref, s),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 42,
                height: 42,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Palette.brand(context).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: AppGlyph(s.glyph, size: 21),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                        if (s.autoRenew) ...[
                          const SizedBox(width: 6),
                          _pill(context, '自动续费'),
                        ],
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      // 关联了账单就不再显示填的费用：金额只有一个真相，
                      // 两处并存时用户改了一边没改另一边，自己都分不清信谁。
                      '${ymdText(s.startDate)} 开卡 · ${s.months} 个月'
                      '${(!s.linked && s.feeCents > 0) ? ' · ${centsToText(s.feeCents)}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkFaint(context)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${ymdText(s.dueDate)} 到期',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkFaint(context)),
                    ),
                    if (s.linked) ...[
                      const SizedBox(height: 6),
                      _linkRow(context, ref, s, links[s.entryId]),
                    ],
                    if (s.note.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        s.note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkSoft(context)),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    cd.text,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: color),
                  ),
                  const SizedBox(height: 4),
                  PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    icon: Icon(Icons.more_horiz,
                        size: 18, color: Palette.inkFaint(context)),
                    onSelected: (v) async {
                      if (v == 'edit') {
                        await _openEditor(context, ref, s);
                      } else if (v == 'delete') {
                        await _delete(context, ref, s);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑')),
                      PopupMenuItem(
                          value: 'delete',
                          child: Text('删除',
                              style: TextStyle(color: Palette.expense))),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 卡片上的「关联账单」行：点一下看那笔账。
  ///
  /// 显示的是**那笔账自己**的日期和金额，不是表单里填的费用 —— 关联之后
  /// 金额只留一个真相，卡片上两处数字打架比没有数字更糟。
  Widget _linkRow(
      BuildContext context, WidgetRef ref, Subscription s, Entry? entry) {
    final symbol = ref.watch(settingsProvider).symbol;
    final removed = entry != null && entry.deletedAt != null;
    final brand = Palette.brand(context);
    final color = removed || entry == null ? Palette.inkFaint(context) : brand;

    final String text;
    if (entry == null) {
      text = '关联的账单已经不在了';
    } else {
      final memo = entry.memo.isEmpty ? '' : ' · ${entry.memo}';
      text = '${removed ? '已删除 · ' : ''}${_mmdd(entry.day)} · '
          '$symbol${centsToText(entry.amountCents)}$memo';
    }

    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        // 永久删除（查不到）就没得看，只剩一句说明。
        onTap: entry == null ? null : () => showEntryPeek(context, entry),
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 3, 6, 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                  removed || entry == null
                      ? Icons.link_off
                      : Icons.receipt_long_outlined,
                  size: 13,
                  color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: color),
                ),
              ),
              if (entry != null)
                Icon(Icons.chevron_right, size: 14, color: color),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pill(BuildContext context, String text) {
    final brand = Palette.brand(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: brand.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10, color: brand, height: 1.4)),
    );
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, Subscription s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${s.name}」？'),
        content: const Text('只删掉这条订阅记录，不会影响已经记过的流水。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('删除', style: TextStyle(color: Palette.expense))),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(storeProvider.future);
    await store.deleteSubscription(s.id);
    bumpRevision(ref);
  }

  /// 新增 / 编辑。
  ///
  /// 用底部面板而不是整页：字段就七八个，弹层能保留列表上下文
  /// （用户刚看到「还差 3 天」才想起来要改时长）。
  ///
  /// 表单本身是独立的 StatefulWidget（[_SubscriptionEditor]）——
  /// controller 必须由它自己 dispose。之前在方法里建 controller、
  /// `showAppSheet` 返回后立刻 dispose，会在面板关闭动画还在跑的那几帧
  /// 抛「A TextEditingController was used after being disposed」直接红屏。
  Future<void> _openEditor(
      BuildContext context, WidgetRef ref, Subscription? s) async {
    final book = await ref.read(activeBookProvider.future);
    if (!context.mounted) return;

    final draft = await showAppSheet<Subscription>(
      context: context,
      title: s == null ? '新增会员' : '编辑会员',
      builder: (_) => _SubscriptionEditor(
        initial: s,
        bookId: s?.bookId ?? book.id,
      ),
    );
    if (draft == null) return;

    final store = await ref.read(storeProvider.future);
    if (s == null) {
      await store.addSubscription(draft);
    } else {
      await store.updateSubscription(draft);
    }
    bumpRevision(ref);

    // 设置了提醒但全局「到期提醒」没开：通知永远不会弹，得说一句。
    if (draft.remindDays > 0 && !ref.read(settingsProvider).dueReminderEnabled) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).toast(
            '已保存。到期提醒还没打开（我的 → 记账提醒），打开后才会推送');
      }
    }
  }
}

/// 新增 / 编辑会员的底部表单。
///
/// 独立成一个 StatefulWidget 只为一件事：controller 的创建与释放必须成对，
/// 且要晚于面板的关闭动画（详见 [SubscriptionsPage._openEditor] 的注释）。
class _SubscriptionEditor extends ConsumerStatefulWidget {
  const _SubscriptionEditor({required this.initial, required this.bookId});

  final Subscription? initial;
  final int bookId;

  @override
  ConsumerState<_SubscriptionEditor> createState() => _SubscriptionEditorState();
}

class _SubscriptionEditorState extends ConsumerState<_SubscriptionEditor> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _monthsCtrl;
  late final TextEditingController _feeCtrl;
  late final TextEditingController _remindCtrl;
  late final TextEditingController _noteCtrl;
  late String _glyph;
  late DateTime _start;
  late bool _autoRenew;

  /// 关联的那笔账。null = 没关联（编辑模式下可能是「关联的账已永久删除」，
  /// 那种情况保存时会自动解绑，不会把死指针写回库）。
  Entry? _linked;

  String? _error;

  @override
  void initState() {
    super.initState();
    final s = widget.initial;
    _nameCtrl = TextEditingController(text: s?.name ?? '');
    _monthsCtrl = TextEditingController(text: '${s?.months ?? 12}');
    _feeCtrl = TextEditingController(
        text: (s == null || s.feeCents <= 0) ? '' : centsToText(s.feeCents));
    _remindCtrl = TextEditingController(text: '${s?.remindDays ?? 7}');
    _noteCtrl = TextEditingController(text: s?.note ?? '');
    _glyph = s?.glyph ?? kSubsGlyphs.first;
    _start = s?.startDate ?? DateTime.now();
    _autoRenew = s?.autoRenew ?? true;
    if (s != null && s.linked) _loadLinked(s.entryId);
  }

  Future<void> _loadLinked(int id) async {
    final store = await ref.read(storeProvider.future);
    final map = await store.entriesByIds([id]);
    if (!mounted) return;
    setState(() => _linked = map[id]);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _monthsCtrl.dispose();
    _feeCtrl.dispose();
    _remindCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  int get _months => int.tryParse(_monthsCtrl.text) ?? 0;

  void _save() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写会员名称');
      return;
    }
    final months = _months;
    if (months < 1 || months > 120) {
      setState(() => _error = '订阅时长请填 1~120 个月');
      return;
    }
    final s = widget.initial;
    Navigator.pop(
      context,
      Subscription(
        id: s?.id ?? 0,
        bookId: s?.bookId ?? widget.bookId,
        name: name,
        glyph: _glyph,
        startDay: ymdText(_start),
        months: months,
        // 关联了账单就以那笔账的金额为准：卡片上只留一个真相，
        // 两处并存时用户改了一边没改另一边，自己都分不清该信谁。
        feeCents: _linked?.amountCents ??
            parseAmountToCents(_feeCtrl.text.trim()) ??
            0,
        autoRenew: _autoRenew,
        note: _noteCtrl.text.trim(),
        remindDays: (int.tryParse(_remindCtrl.text) ?? 0).clamp(0, 365),
        entryId: _linked?.id ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final due = _months > 0 ? LedgerStore.addMonths(_start, _months) : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppTextField(
            label: '会员名称',
            controller: _nameCtrl,
            hint: '例如 Netflix、网易云音乐',
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 14),
          GlyphPicker(
            glyphs: kSubsGlyphs,
            value: _glyph,
            onChanged: (g) => setState(() => _glyph = g),
          ),
          const SizedBox(height: 14),
          // 开卡日期 + 到期日预览：改日期或月数时立刻能看到算出来的到期日，
          // 不用保存后再回来核对。
          Row(
            children: [
              Expanded(
                child: _dateField(
                  label: '开卡日期',
                  value: ymdText(_start),
                  onTap: () async {
                    final picked =
                        await pickDayQuick(context, _start, title: '开卡日期');
                    if (picked != null) setState(() => _start = picked);
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('到期日',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                    const SizedBox(height: 6),
                    Container(
                      height: 40,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        color: Palette.paper(context),
                        borderRadius: BorderRadius.circular(AppRadius.control),
                      ),
                      child: Text(
                        due == null ? '—' : ymdText(due),
                        style: TextStyle(
                            fontSize: 13, color: Palette.inkSoft(context)),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          AppTextField(
            label: '订阅时长（月）',
            controller: _monthsCtrl,
            hint: '12',
            suffixText: '个月',
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          // 常用时长一点就好，省得手输；自定义仍然随便填。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in _kQuickMonths)
                _quickChip(
                  label: '$m 个月',
                  selected: _monthsCtrl.text == '$m',
                  onTap: () => setState(() => _monthsCtrl.text = '$m'),
                ),
            ],
          ),
          const SizedBox(height: 14),
          AppTextField(
            label: '会员费用',
            controller: _feeCtrl,
            hint: '0.00',
            suffixText: '元',
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: const [AmountInputFormatter()],
          ),
          const SizedBox(height: 10),
          _linkField(),
          const SizedBox(height: 6),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('自动续费', style: TextStyle(fontSize: 13)),
            subtitle: Text('到期自动扣款，别忘了卡里有余额',
                style: TextStyle(
                    fontSize: 11, color: Palette.inkFaint(context))),
            value: _autoRenew,
            onChanged: (v) => setState(() => _autoRenew = v),
          ),
          const SizedBox(height: 6),
          AppTextField(
            label: '到期前提醒',
            controller: _remindCtrl,
            hint: '7',
            suffixText: '天',
            helper: '填 0 = 不提醒',
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(3),
            ],
          ),
          const SizedBox(height: 14),
          AppTextField(
            label: '备注',
            controller: _noteCtrl,
            hint: '选填，例如「和家人共用」「年付更划算」',
            maxLines: 2,
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(fontSize: 12, color: Palette.expense)),
          ],
          const SizedBox(height: 18),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: FilledButton(onPressed: _save, child: const Text('保存')),
          ),
        ],
      ),
    );
  }

  /// 「关联账单」选择行。
  ///
  /// 会员费到底记在哪笔流水上？不关联的话，卡上的金额和账本里的流水分家，
  /// 对账时只能靠回忆。关联后点卡片上的金额就能看到那笔账。
  Widget _linkField() {
    final e = _linked;
    final brand = Palette.brand(context);
    final symbol = ref.watch(settingsProvider).symbol;
    final gone = e != null && e.deletedAt != null;
    final text = e == null
        ? '选一笔已有的支出'
        : '${_mmdd(e.day)} · $symbol${centsToText(e.amountCents)}'
            '${e.memo.isEmpty ? '' : ' · ${e.memo}'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('关联账单',
                style:
                    TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
            const Spacer(),
            if (e != null)
              GestureDetector(
                onTap: () => setState(() => _linked = null),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text('取消关联',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkSoft(context))),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: _pickEntry,
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Palette.paper(context),
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Row(
              children: [
                Icon(
                    gone
                        ? Icons.link_off
                        : (e == null
                            ? Icons.add_link
                            : Icons.receipt_long_outlined),
                    size: 15,
                    color: e == null ? Palette.inkFaint(context) : brand),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    gone ? '关联的账单已删除' : text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        color: e == null
                            ? Palette.inkFaint(context)
                            : Palette.ink(context)),
                  ),
                ),
                Text(e == null ? '选一笔' : '更换',
                    style: TextStyle(fontSize: 12, color: brand)),
                Icon(Icons.chevron_right, size: 16, color: brand),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('关联后，会员卡上的金额就是这笔账的金额',
            style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
      ],
    );
  }

  Future<void> _pickEntry() async {
    final picked = await showAppSheet<_EntryPick>(
      context: context,
      title: '挑一笔账',
      // 长列表自己管滚动：外层再包一层 SingleChildScrollView 会和外层抢手势，
      // 而且 fillsHeight 下 Expanded 需要一个能撑满的 ListView。
      scrollable: false,
      fillsHeight: true,
      builder: (_) => _EntryPicker(bookId: widget.bookId),
    );
    // ⚠️ null = 划掉面板 / 按返回键，**什么都别改**；
    // 明确「不关联」走的是 `_EntryPick(null)`。两者混成 null，
    // 用户划一下面板就会把刚选好的关联悄悄清空。
    if (picked == null || !mounted) return;
    setState(() {
      _linked = picked.entry;
      if (picked.entry != null) {
        // 费用框跟着那笔账走：留着旧数字，两个金额在库里就会打架。
        _feeCtrl.text = centsToText(picked.entry!.amountCents);
      }
    });
  }

  Widget _dateField(
      {required String label,
      required String value,
      required VoidCallback onTap}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
        const SizedBox(height: 6),
        InkWell(
          borderRadius: BorderRadius.circular(AppRadius.control),
          onTap: onTap,
          child: Container(
            height: 40,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: Palette.paper(context),
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Row(
              children: [
                Icon(Icons.calendar_today_outlined,
                    size: 14, color: Palette.inkFaint(context)),
                const SizedBox(width: 6),
                Text(value,
                    style:
                        TextStyle(fontSize: 13, color: Palette.ink(context))),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _quickChip(
      {required String label,
      required bool selected,
      required VoidCallback onTap}) {
    final brand = Palette.brand(context);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.pill),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color:
              selected ? brand.withValues(alpha: 0.12) : Palette.paper(context),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border:
              Border.all(color: selected ? brand : Palette.hairline(context)),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12,
                color: selected ? brand : Palette.inkSoft(context))),
      ),
    );
  }
}

/// `yyyy-MM-dd`：存库格式，也是卡片上显示的格式（中国用户对这个写法最熟）。
String ymdText(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// `MM-dd`：关联账单那一行只显示月日 —— 年份在「开卡日期」里已经出现过了，
/// 一行里放两个年份会把备注挤没。
String _mmdd(DateTime d) =>
    '${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 选账单的返回值。
///
/// 为什么要包一层：`showAppSheet` 被划掉/返回键也返回 null，而「明确选择
/// 不关联」同样是「没有 Entry」。两者混成一个 null，用户划一下面板就会把
/// 刚选好的关联悄悄清空（搜索页的筛选弹层踩过这个坑）。
class _EntryPick {
  const _EntryPick(this.entry);

  /// null = 明确选择「不关联」。
  final Entry? entry;
}

/// 从已有流水里挑一笔来关联。
///
/// 只列支出、近 400 天：会员费不会记成收入；400 天能覆盖年付，再往前的
/// 账单连用户自己都想不起来是哪笔，关联了也核不了账。
class _EntryPicker extends ConsumerStatefulWidget {
  const _EntryPicker({required this.bookId});

  final int bookId;

  @override
  ConsumerState<_EntryPicker> createState() => _EntryPickerState();
}

class _EntryPickerState extends ConsumerState<_EntryPicker> {
  late final Future<List<Entry>> _future = _load();
  final _searchCtrl = TextEditingController();
  String _kw = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<List<Entry>> _load() async {
    final store = await ref.read(storeProvider.future);
    final rows = await store.entriesRecent(widget.bookId, days: 400);
    final out = [for (final e in rows) if (e.flow == 'out') e];
    // 新的在前：刚交完的会员费一定在最近，不用翻。
    out.sort((a, b) {
      final c = b.day.compareTo(a.day);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final buckets =
        ref.watch(allBucketsProvider).valueOrNull ?? const <Bucket>[];
    final pockets =
        ref.watch(allPocketsProvider).valueOrNull ?? const <Pocket>[];
    final bucketById = {for (final b in buckets) b.id: b};
    final pocketById = {for (final p in pockets) p.id: p};
    final symbol = ref.watch(settingsProvider).symbol;
    final kw = _kw.trim().toLowerCase();

    return FutureBuilder<List<Entry>>(
      future: _future,
      builder: (context, snap) {
        final all = snap.data ?? const <Entry>[];
        final list = [
          for (final e in all)
            if (kw.isEmpty ||
                e.memo.toLowerCase().contains(kw) ||
                (bucketById[e.bucketId]?.title.toLowerCase().contains(kw) ??
                    false) ||
                (pocketById[e.pocketId]?.title.toLowerCase().contains(kw) ??
                    false) ||
                centsToText(e.amountCents).contains(kw))
              e
        ];

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
              child: TextField(
                controller: _searchCtrl,
                onChanged: (v) => setState(() => _kw = v),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜备注 / 分类 / 账户 / 金额',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.control)),
                ),
              ),
            ),
            if (snap.connectionState != ConnectionState.done)
              const Expanded(
                child: Center(
                    child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2))),
              )
            else if (list.isEmpty)
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      snap.hasError
                          ? '读取失败，回去再试一次'
                          : (all.isEmpty
                              ? '这个账本还没有支出记录'
                              : '没找到匹配的账单'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13, color: Palette.inkSoft(context)),
                    ),
                  ),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                  itemCount: list.length + 1,
                  itemBuilder: (context, i) {
                    if (i == 0) {
                      return ListTile(
                        dense: true,
                        leading: Icon(Icons.link_off,
                            size: 18, color: Palette.inkFaint(context)),
                        title: const Text('不关联账单',
                            style: TextStyle(fontSize: 13)),
                        onTap: () =>
                            Navigator.pop(context, const _EntryPick(null)),
                      );
                    }
                    final e = list[i - 1];
                    final b = bucketById[e.bucketId];
                    final p = pocketById[e.pocketId];
                    final memo = e.memo.isEmpty ? '' : ' · ${e.memo}';
                    return ListTile(
                      dense: true,
                      leading: SizedBox(
                        width: 30,
                        child: Center(
                            child: AppGlyph(b?.glyph ?? '🏷️', size: 17)),
                      ),
                      title: Text(b?.title ?? '未分类',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        '${_mmdd(e.day)} · ${p?.title ?? '已删除账户'}$memo',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: Palette.inkFaint(context)),
                      ),
                      trailing: Text(
                        '$symbol${centsToText(e.amountCents)}',
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Palette.expense),
                      ),
                      onTap: () =>
                          Navigator.pop(context, _EntryPick(e)),
                    );
                  },
                ),
              ),
          ],
        );
      },
    );
  }
}
