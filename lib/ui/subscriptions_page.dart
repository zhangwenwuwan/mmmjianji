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
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
            itemCount: list.length + 1,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              if (i == list.length) return _footer(context);
              return _card(context, ref, list[i], today);
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

  Widget _card(
      BuildContext context, WidgetRef ref, Subscription s, DateTime today) {
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
                      '${ymdText(s.startDate)} 开卡 · ${s.months} 个月'
                      '${s.feeCents > 0 ? ' · ${centsToText(s.feeCents)}' : ''}',
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
class _SubscriptionEditor extends StatefulWidget {
  const _SubscriptionEditor({required this.initial, required this.bookId});

  final Subscription? initial;
  final int bookId;

  @override
  State<_SubscriptionEditor> createState() => _SubscriptionEditorState();
}

class _SubscriptionEditorState extends State<_SubscriptionEditor> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _monthsCtrl;
  late final TextEditingController _feeCtrl;
  late final TextEditingController _remindCtrl;
  late final TextEditingController _noteCtrl;
  late String _glyph;
  late DateTime _start;
  late bool _autoRenew;
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
        feeCents: parseAmountToCents(_feeCtrl.text.trim()) ?? 0,
        autoRenew: _autoRenew,
        note: _noteCtrl.text.trim(),
        remindDays: (int.tryParse(_remindCtrl.text) ?? 0).clamp(0, 365),
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
