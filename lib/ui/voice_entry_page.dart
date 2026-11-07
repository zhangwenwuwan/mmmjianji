import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../core/smart_parser.dart';
import '../data/store.dart';
import '../services/app_log.dart';
import '../services/smart_memory.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'app_glyph.dart';
import 'common.dart';
import 'editor_page.dart' show showPocketPicker;
import 'motion.dart';
import 'theme.dart';

/// 语音 / 文本记账的**确认界面**。
///
/// 有两种形态：
/// - [embedded] = false：独立全屏页，普通输入框接输入法语音听写（零权限）。
/// - [embedded] = true：离线识别完成后的确认弹窗，原话已预填并解析成草稿，
///   用户在窗口里核对/修改，点「记一笔」才真正落库。
///
/// 两条输入通道共用同一份 text → BillDraft 解析器（core/smart_parser.dart），
/// 也共用同一份草稿编辑与保存逻辑 —— 换识别引擎不需要动这里。
class VoiceEntryPage extends ConsumerStatefulWidget {
  const VoiceEntryPage({
    super.key,
    this.embedded = false,
    this.initialText = '',
  });

  /// true = 弹窗内容（无 Scaffold / AppBar，不自动弹键盘）。
  final bool embedded;

  /// 识别出的原话，进弹窗时预填并立即解析成草稿。
  final String initialText;

  @override
  ConsumerState<VoiceEntryPage> createState() => _VoiceEntryPageState();

  /// 离线识别完成后弹出的确认窗口：**确认之后才落库**。
  ///
  /// 用底部弹窗而不是全屏页，是为了让用户说完话后仍看得见首页上下文；
  /// 窗口里能改原话、金额、分类、账户，点「记一笔」才写进数据库。
  ///
  /// 高度自适应内容（不再写死 78% 屏高）：精简后的卡片一屏就能看完，
  /// 固定高度反而会在下半截留一大片空白。改原话/备注会弹键盘，
  /// 所以外层要跟着 viewInsets 把整张卡片顶上去，别把「记一笔」盖住。
  static Future<bool?> showAsDraftSheet(
      BuildContext context, String recognized) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetCtx).bottom),
        child: Container(
          decoration: BoxDecoration(
            color: Palette.paper(sheetCtx),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          clipBehavior: Clip.antiAlias,
          // 透明 Material：否则 chip/按钮的水波纹画在背景底下看不见。
          child: Material(
            color: Colors.transparent,
            child: VoiceEntryPage(embedded: true, initialText: recognized),
          ),
        ),
      ),
    );
  }
}

class _VoiceEntryPageState extends ConsumerState<VoiceEntryPage> {
  final _textCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _memoCtrl = TextEditingController();

  /// 「再记一笔」后重新抢焦点，键盘和输入法麦克风不用再点一次。
  final _textFocus = FocusNode();

  BillDraft? _draft;
  String _flow = 'out';
  int? _bucketId;
  int? _pocketId;
  int? _toPocketId;
  late DateTime _day;
  int? _timeMinutes;
  bool _saving = false;

  /// 用户手动改过的字段。改过的字段不再被新一轮解析覆盖，
  /// 否则「把分类改成餐饮」之后补一个字，草稿又跳回去了。
  final Set<String> _edited = {};

  Map<String, int> _categoryHints = {};
  Map<String, int> _accountHints = {};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _day = DateTime(now.year, now.month, now.day);
    _textCtrl.addListener(_reparse);
    _loadHints();
    // 弹窗里的原话要等首帧之后才填：listener 里会 setState，
    // 在 initState 阶段同步触发容易和首帧 build 撞上。
    if (widget.initialText.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _textCtrl.text = widget.initialText;
      });
    }
  }

  @override
  void dispose() {
    _textCtrl.removeListener(_reparse);
    _textCtrl.dispose();
    _amountCtrl.dispose();
    _memoCtrl.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  Future<void> _loadHints() async {
    final cats = await SmartMemory.categoryHints();
    final accs = await SmartMemory.accountHints();
    if (!mounted) return;
    setState(() {
      _categoryHints = cats;
      _accountHints = accs;
    });
  }

  DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  SmartContext _parserContext() {
    final pockets = ref.read(allPocketsProvider).valueOrNull ?? <Pocket>[];
    final outs = ref.read(bucketsProvider('out')).valueOrNull ?? <Bucket>[];
    final ins = ref.read(bucketsProvider('in')).valueOrNull ?? <Bucket>[];
    return SmartContext(
      now: DateTime.now(),
      categories: [
        for (final b in outs)
          SmartCategory(
              id: b.id, title: b.title, flow: b.flow, parentId: b.parentId),
        for (final b in ins)
          SmartCategory(
              id: b.id, title: b.title, flow: b.flow, parentId: b.parentId),
      ],
      accounts: [
        for (final p in pockets)
          SmartAccount(id: p.id, title: p.title, alias: p.displayName),
      ],
      categoryHints: _categoryHints,
      accountHints: _accountHints,
    );
  }

  /// 兜底优先级与记账页一致（2026-11-07）：上次用的账户 > 默认账户 >
  /// 第一个未归档账户。语音弹窗之前只认默认账户，用户明明上一笔在
  /// 语音里选了支付宝，下一笔弹开又跳回微信，体感就是「没记住」。
  int? _fallbackPocket(List<Pocket> pockets) {
    if (pockets.isEmpty) return null;
    final settings = ref.read(settingsProvider);
    // ① 上次记账用的账户。必须校验存在性：账户可能已被归档/删除。
    final last = settings.lastPocketId;
    if (last > 0) {
      for (final p in pockets) {
        if (p.id == last && !p.archived) return last;
      }
    }
    // ② 用户设置的默认账户。
    final def = settings.defaultPocketId;
    if (def != 0 && pockets.any((p) => p.id == def && !p.archived)) {
      return def;
    }
    // ③ 第一个未归档账户。
    for (final p in pockets) {
      if (!p.archived) return p.id;
    }
    return pockets.first.id;
  }

  /// UI 显示和保存共用的「有效账户」。
  ///
  /// 弹窗首帧解析时 `allPocketsProvider` 可能还没加载完，`_reparseWith` 里
  /// 用 `ref.read` 拿到空列表，会把 `_pocketId` 设成 null 且不再回填；
  /// 而 build 里已经用兜底显示出「现金」了 —— 用户看到有账户，点「记一笔」
  /// 却被「先选一个账户」拦住。两边统一走这里，冷启动也不会出现这种自相矛盾。
  int? _effectivePocket(List<Pocket> pockets) {
    if (pockets.any((p) => p.id == _pocketId)) return _pocketId;
    return _fallbackPocket(pockets);
  }

  /// 时分口径与手动记账对齐：原话里明确说了「晚上8点」「8:30」就尊重解析值；
  /// 没说时分时，今天的账记当前时刻，补记历史日期才留空。
  ///
  /// 之前这里只传 `_timeMinutes`，于是「早上吃早餐花了十块钱」这类没报时分的
  /// 语音账全部落成 null，首页时间轴显示 `--:--`，而同一分钟手动记的账有
  /// `00:04`。`--:--` 本意是「没记时分的老账」，不该落在新账上。
  int? _effectiveTimeMinutes() => _timeMinutes ?? saveTimeMinutes(_day);

  void _reparse() => _reparseWith(force: false);

  void _reparseWith({required bool force}) {
    if (force) _edited.clear();
    final text = _textCtrl.text.trim();
    if (text.isEmpty) {
      setState(() {
        _draft = null;
        if (!_edited.contains('amount')) _amountCtrl.text = '';
        if (!_edited.contains('memo')) _memoCtrl.text = '';
      });
      return;
    }
    final draft = parseSmartText(text, _parserContext());
    final pockets = ref.read(allPocketsProvider).valueOrNull ?? <Pocket>[];
    setState(() {
      _draft = draft;
      if (!_edited.contains('flow')) _flow = draft.flow;
      if (!_edited.contains('amount')) {
        _amountCtrl.text = draft.amountCents == null
            ? ''
            : centsToText(draft.amountCents!);
      }
      if (!_edited.contains('bucket')) _bucketId = draft.bucketId;
      if (!_edited.contains('pocket')) {
        _pocketId = draft.pocketId ?? _fallbackPocket(pockets);
      }
      if (!_edited.contains('toPocket')) _toPocketId = draft.toPocketId;
      if (!_edited.contains('day')) _day = draft.day;
      if (!_edited.contains('time')) _timeMinutes = draft.timeMinutes;
      if (!_edited.contains('memo')) _memoCtrl.text = draft.memo;
    });
  }

  void _mark(String field) {
    if (_edited.contains(field)) return;
    setState(() => _edited.add(field));
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).toast(text);
  }

  Future<void> _save({bool again = false}) async {
    final amountCents = parseAmountToCents(_amountCtrl.text);
    if (amountCents == null || amountCents <= 0) {
      _toast('还没填金额，补一句「35 元」试试');
      return;
    }
    final pockets = ref.read(allPocketsProvider).valueOrNull ?? <Pocket>[];
    final pocketId = _effectivePocket(pockets);
    if (pocketId == null) {
      _toast('先选一个账户');
      return;
    }
    if (_flow == 'transfer' && _toPocketId == null) {
      _toast('转账还要选转入账户');
      return;
    }
    setState(() => _saving = true);
    try {
      final store = await ref.read(storeProvider.future);
      final book = await ref.read(activeBookProvider.future);
      await store.addEntry(
        bookId: book.id,
        pocketId: pocketId,
        toPocketId: _flow == 'transfer' ? _toPocketId : null,
        bucketId: _flow == 'transfer' ? null : _bucketId,
        flow: _flow,
        amountCents: amountCents,
        memo: _memoCtrl.text.trim(),
        day: _day,
        timeMinutes: _effectiveTimeMinutes(),
      );
      // 只有用户**手动纠正过**才记，自动识别的结果不写记忆表，
      // 免得把一次误识别固化成长期规则。
      final keyword = _draft?.keyword ?? '';
      if (keyword.isNotEmpty) {
        if (_edited.contains('bucket') && _bucketId != null) {
          await SmartMemory.rememberCategory(keyword, _bucketId!);
        }
        if (_edited.contains('pocket')) {
          await SmartMemory.rememberAccount(keyword, pocketId);
        }
      }
      bumpRevision(ref);
      // 记住这次用的账户，和记账页同口径：下一笔（手动或语音）预选它。
      // 之前只有手动记账页会记，语音通道记完一笔下次弹窗又跳回默认账户。
      await ref.read(settingsProvider.notifier).setLastPocket(pocketId);
      HapticFeedback.lightImpact();
      if (!mounted) return;
      _toast(again ? '已记一笔，继续说下一句' : '已记一笔');
      if (again) {
        _reset();
      } else {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      AppLog.error('voice', '保存流水失败', e);
      _toast('保存失败，详情见日志中心');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _reset() {
    _textCtrl.clear();
    _amountCtrl.clear();
    _memoCtrl.clear();
    _edited.clear();
    setState(() {
      _draft = null;
      _flow = 'out';
      _bucketId = null;
      _toPocketId = null;
      _day = _today();
      _timeMinutes = null;
      _pocketId = _fallbackPocket(
          ref.read(allPocketsProvider).valueOrNull ?? <Pocket>[]);
    });
    // 点「再记一笔」时焦点多半被按钮拿走了，这里叫回来，好接着说下一句。
    if (_textFocus.canRequestFocus) _textFocus.requestFocus();
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _edited.add('day');
      _day = DateTime(picked.year, picked.month, picked.day);
    });
  }

  @override
  Widget build(BuildContext context) {
    // watch 一下，保证用户开始输入时分类/账户已经加载好。
    final pockets = ref.watch(allPocketsProvider).valueOrNull ?? <Pocket>[];
    final outs = ref.watch(bucketsProvider('out')).valueOrNull ?? <Bucket>[];
    final ins = ref.watch(bucketsProvider('in')).valueOrNull ?? <Bucket>[];
    final buckets = _flow == 'in' ? ins : outs;
    final bucketId = buckets.any((b) => b.id == _bucketId) ? _bucketId : null;
    final pocketId = _effectivePocket(pockets);
    final draft = _draft;

    // 语音识别后的确认弹窗走紧凑版；全屏页（输入法听写的零权限备用通道）
    // 保留完整表单 —— 那边是主动录入，字段多反而方便。
    if (widget.embedded) {
      return _compactSheet(context, buckets, pockets, bucketId, pocketId);
    }

    final body = ListView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
      children: [
        if (!widget.embedded) _IntroCard(),
        if (!widget.embedded) const SizedBox(height: AppSpace.md),
        Panel(
          child: AppTextField(
            label: widget.embedded ? '识别到的原话' : '说一句 / 粘贴一句话',
            controller: _textCtrl,
            focusNode: _textFocus,
            hint: '例如：昨天午饭花了 35 元',
            helper: widget.embedded
                ? '识别得不准可以直接改文字，下面的草稿会跟着变'
                : '点输入法的麦克风说话，说出来的是文字，App 不录音、不联网',
            maxLines: 3,
            // 弹窗里话已经说完了，别再弹键盘盖住草稿。
            autofocus: !widget.embedded,
          ),
        ),
        const SizedBox(height: AppSpace.md),
        if (draft == null)
          const EmptyView(
            icon: Icons.mic_none_outlined,
            title: '还没听到内容',
            hint: '支持「今天打车 23.5 块」「支付宝转到微信 15 元」'
                '「上周三买菜 68」这类说法。',
          )
        else
          _draftCard(context, draft, buckets, pockets, bucketId, pocketId),
      ],
    );

    final actions = SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton(
                onPressed: _saving ? null : () => _save(),
                child: Text(widget.embedded ? '记一笔' : '保存这笔'),
              ),
            ),
            if (!widget.embedded) ...[
              const SizedBox(width: AppSpace.sm),
              OutlinedButton(
                onPressed: _saving ? null : () => _save(again: true),
                child: const Text('再记一笔'),
              ),
            ],
          ],
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('语音记账'),
        actions: [
          IconButton(
            tooltip: '重新解析',
            onPressed: _saving ? null : () => _reparseWith(force: true),
            icon: const Icon(Icons.auto_fix_high_outlined),
          ),
        ],
      ),
      body: body,
      bottomNavigationBar: actions,
    );
  }

  // ------------------------------------------------------------ 紧凑确认弹窗

  /// 分类选择器里「自定义分类」这一项的哨兵（真实 id 恒为正整数）。
  static const int _kCustomBucket = -1;

  /// 一屏看完的确认卡片。
  ///
  /// 旧版把完整记账表单塞进 78% 屏高的 ListView：把握百分比、解析依据、
  /// 还需确认红字、三个类型 chip、两个下拉、日期快捷 chip、时间、备注……
  /// 语音场景里用户只想核对「说了什么 / 多少钱 / 记到哪」，于是只留三块：
  /// 可改的原话、大字号金额、一行元信息 chip；低频字段全部收进点击才展开的面板。
  Widget _compactSheet(
    BuildContext context,
    List<Bucket> buckets,
    List<Pocket> pockets,
    int? bucketId,
    int? pocketId,
  ) {
    final ink = Palette.ink(context);
    final soft = Palette.inkSoft(context);
    final faint = Palette.inkFaint(context);
    final brand = Palette.brand(context);
    final hasBucket = bucketId != null;

    final tip = pockets.isEmpty
        ? '还没有账户：先到「资产」页新建一个'
        : (_amountCtrl.text.trim().isEmpty ? '没听出金额，补一个就能记' : null);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 38,
            height: 4,
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            decoration: BoxDecoration(
              color: faint.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 8, 0),
          child: Row(
            children: [
              Text('确认这笔',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: ink)),
              const Spacer(),
              IconButton(
                tooltip: '取消',
                visualDensity: VisualDensity.compact,
                onPressed: () => Navigator.of(context).pop(false),
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
        ),
        // 识别原话：一行淡字，点一下就能改；改完草稿自动重解析。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: TextField(
            controller: _textCtrl,
            focusNode: _textFocus,
            minLines: 1,
            maxLines: 2,
            style: TextStyle(fontSize: 13, height: 1.4, color: soft),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
              prefixIcon: Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.format_quote, size: 15, color: brand),
              ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 0, minHeight: 0),
              hintText: '识别得不准？点这里改',
              hintStyle: TextStyle(fontSize: 12.5, color: faint),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // 金额是这张卡的主视觉。¥ 单独放 Row 里，不用 prefixText ——
        // 后者在「空且未聚焦」时会被 InputDecorator 藏起来。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Row(
            children: [
              _metaChip(
                context,
                icon: _flow == 'in'
                    ? Icons.south_west
                    : _flow == 'transfer'
                        ? Icons.swap_horiz
                        : Icons.north_east,
                label: _flow == 'in'
                    ? '收入'
                    : _flow == 'transfer'
                        ? '转账'
                        : '支出',
                onTap: _pickFlow,
                strong: true,
              ),
              const SizedBox(width: 12),
              Text('¥',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w600,
                      color: soft)),
              const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  controller: _amountCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      color: ink,
                      height: 1.1),
                  decoration: InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: '0',
                    hintStyle: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        color: faint.withValues(alpha: 0.45)),
                  ),
                  onChanged: (_) => _mark('amount'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 分类 / 账户 / 日期 一行搞定，点 chip 才展开选择面板。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (_flow != 'transfer')
                _metaChip(
                  context,
                  icon: hasBucket
                      ? Icons.sell_outlined
                      : Icons.add_circle_outline,
                  label: _bucketLabel(buckets, bucketId),
                  onTap: () => _pickBucket(buckets),
                  // 没分类时不再冷冰冰写着「未分类」，用主色提示「这里能补/新建」。
                  highlight: !hasBucket,
                ),
              _metaChip(
                context,
                icon: Icons.account_balance_wallet_outlined,
                label: _pocketLabel(pockets, pocketId),
                onTap: () => _pickPocket(pockets),
                highlight: pocketId == null,
              ),
              if (_flow == 'transfer')
                _metaChip(
                  context,
                  icon: Icons.call_received,
                  label: _pocketLabel(pockets, _toPocketId, '转入账户'),
                  onTap: () => _pickToPocket(pockets),
                  highlight: _toPocketId == null,
                ),
              _metaChip(
                context,
                icon: Icons.event_outlined,
                label: _dateLabel(),
                onTap: _pickDate,
              ),
            ],
          ),
        ),
        // 备注是低频字段，压成一行 hint，不占标题和边框。
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 6, 18, 0),
          child: TextField(
            controller: _memoCtrl,
            style: TextStyle(fontSize: 12.5, color: soft),
            decoration: InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
              hintText: '备注（可选）',
              hintStyle: TextStyle(fontSize: 12.5, color: faint),
            ),
            onChanged: (_) => _mark('memo'),
          ),
        ),
        if (tip != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 0),
            child: Text(tip,
                style: const TextStyle(fontSize: 11.5, color: Palette.expense)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 14),
          child: FilledButton(
            onPressed: _saving ? null : () => _save(),
            child: const Text('记一笔'),
          ),
        ),
      ],
    );
  }

  /// 元信息 chip：薄荷底的小药丸，点开对应选择面板。
  Widget _metaChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool highlight = false,
    bool strong = false,
  }) {
    final brand = Palette.brand(context);
    final fg = highlight || strong ? brand : Palette.inkSoft(context);
    return Material(
      color: highlight || strong
          ? brand.withValues(alpha: strong ? 0.14 : 0.10)
          : Palette.mint(context),
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 116),
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                        color: fg)),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more,
                  size: 13, color: fg.withValues(alpha: 0.7)),
            ],
          ),
        ),
      ),
    );
  }

  String _bucketLabel(List<Bucket> buckets, int? id) {
    if (id == null) return '选分类';
    for (final b in buckets) {
      if (b.id == id) return b.title;
    }
    return '选分类';
  }

  String _pocketLabel(List<Pocket> pockets, int? id,
      [String empty = '选账户']) {
    if (pockets.isEmpty) return '没有账户';
    if (id == null) return empty;
    for (final p in pockets) {
      if (p.id == id) return p.displayName;
    }
    return empty;
  }

  String _dateLabel() {
    final diff = _day.difference(_today()).inDays;
    final base = diff == 0
        ? '今天'
        : diff == -1
            ? '昨天'
            : diff == -2
                ? '前天'
                : '${_day.month}月${_day.day}日';
    if (_timeMinutes == null) return base;
    return '$base ${pad2(_timeMinutes! ~/ 60)}:${pad2(_timeMinutes! % 60)}';
  }

  Future<void> _pickFlow() async {
    final v = await showAppSheet<String>(
      context: context,
      title: '记成什么',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final f in const [
            ('out', '支出', Icons.north_east),
            ('in', '收入', Icons.south_west),
            ('transfer', '转账', Icons.swap_horiz),
          ])
            ListTile(
              dense: true,
              leading: Icon(f.$3, size: 18),
              title: Text(f.$2),
              trailing: _flow == f.$1
                  ? Icon(Icons.check, size: 18, color: Palette.brand(ctx))
                  : null,
              onTap: () => Navigator.pop(ctx, f.$1),
            ),
        ],
      ),
    );
    if (v == null || v == _flow || !mounted) return;
    setState(() {
      _edited.add('flow');
      _flow = v;
      _bucketId = null;
      _toPocketId = null;
    });
  }

  Future<void> _pickBucket(List<Bucket> buckets) async {
    final v = await showAppSheet<int>(
      context: context,
      title: '选分类',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 「自定义」常驻列表最顶上：识别不到时不用对着「未分类」发呆，
          // 直接造一个，下次同样说法还会被记忆表命中。
          ListTile(
            dense: true,
            leading: Icon(Icons.add_circle_outline,
                size: 20, color: Palette.brand(ctx)),
            title: Text('自定义分类',
                style: TextStyle(
                    color: Palette.brand(ctx),
                    fontWeight: FontWeight.w600)),
            subtitle: (_draft?.keyword ?? '').isEmpty
                ? const Text('新建一个属于这笔的分类')
                : Text('用「${_draft!.keyword}」当名字，可再改'),
            onTap: () => Navigator.pop(ctx, _kCustomBucket),
          ),
          const Divider(height: 8),
          for (final b in buckets)
            ListTile(
              dense: true,
              leading: AppGlyph(b.glyph, size: 18),
              title: Text(b.title),
              trailing: b.id == _bucketId
                  ? Icon(Icons.check, size: 18, color: Palette.brand(ctx))
                  : null,
              onTap: () => Navigator.pop(ctx, b.id),
            ),
        ],
      ),
    );
    if (v == null || !mounted) return;
    if (v == _kCustomBucket) {
      await _createBucket();
      return;
    }
    setState(() {
      _edited.add('bucket');
      _bucketId = v;
    });
  }

  /// 就地新建一个分类并立刻选中。名字默认用解析器挑出的关键词
  /// （「买衣服花了五百块」→「买衣服」），用户可改；同名直接复用。
  Future<void> _createBucket() async {
    final keyword = _draft?.keyword ?? '';
    final name = await _askName(
      title: '自定义分类',
      initial: keyword.length > 10 ? keyword.substring(0, 10) : keyword,
      hint: '例如：衣服、交通、宠物',
    );
    if (name == null || !mounted) return;
    final title = name.trim();
    if (title.isEmpty) return;
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final current = await store.buckets(book.id, _flow);
    final same = current.where((b) => b.title == title).toList();
    int id;
    if (same.isNotEmpty) {
      id = same.first.id;
    } else {
      id = await store.addBucket(
          bookId: book.id,
          title: title,
          glyph: '✨',
          flow: _flow,
          parentId: null);
    }
    if (!mounted) return;
    bumpRevision(ref);
    setState(() {
      _edited.add('bucket');
      _bucketId = id;
    });
    // 手建的分类顺手记进记忆表，下次同样说法直接命中，不必再建一次。
    if (keyword.isNotEmpty) {
      await SmartMemory.rememberCategory(keyword, id);
    }
    _toast('已建分类「$title」');
  }

  /// 输入框 controller 必须交给面板自己的 State 管生命周期：
  /// 在 `_askName` 的 finally 里 dispose，底部弹窗还在放退出动画，
  /// TextField 会 rebuild 并抛「TextEditingController was used after being disposed」。
  Future<String?> _askName({
    required String title,
    required String initial,
    required String hint,
  }) {
    return showAppSheet<String>(
      context: context,
      title: title,
      builder: (_) => _NameSheet(initial: initial, hint: hint),
    );
  }

  /// 选账户：**和记账页共用同一个选择器**，列表里直接带余额。
  ///
  /// 以前这里是一个只有名字的裸列表 —— 语音记完账常要确认"这笔该记哪张卡"，
  /// 看不到余额就得退出去查一遍。共用 showPocketPicker 还能保证两处口径一致
  /// （信用卡显示可用额度、其他负债显示欠款），别各写一份。
  Future<void> _pickPocket(List<Pocket> pockets) => _pickOnePocket(
        pockets,
        title: '选账户',
        selectedId: _pocketId,
        apply: (id) {
          _edited.add('pocket');
          _pocketId = id;
        },
      );

  Future<void> _pickToPocket(List<Pocket> pockets) => _pickOnePocket(
        pockets,
        title: '转入账户',
        selectedId: _toPocketId,
        apply: (id) {
          _edited.add('toPocket');
          _toPocketId = id;
        },
      );

  Future<void> _pickOnePocket(
    List<Pocket> pockets, {
    required String title,
    required int? selectedId,
    required void Function(int id) apply,
  }) async {
    if (pockets.isEmpty) {
      _toast('还没有账户：先到「资产」页新建一个');
      return;
    }
    final v = await showPocketPicker(
      context,
      ref,
      title: title,
      items: pockets,
      selectedId: selectedId,
    );
    if (v == null || !mounted) return;
    setState(() => apply(v));
  }

  Future<void> _pickDate() async {
    final v = await showAppSheet<String>(
      context: context,
      title: '记在哪天',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final d in const [
            ('今天', '0'),
            ('昨天', '-1'),
            ('前天', '-2'),
          ])
            ListTile(
              dense: true,
              title: Text(d.$1),
              trailing: _day.difference(_today()).inDays.toString() == d.$2
                  ? Icon(Icons.check, size: 18, color: Palette.brand(ctx))
                  : null,
              onTap: () => Navigator.pop(ctx, d.$2),
            ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.date_range_outlined, size: 18),
            title: const Text('选日期'),
            onTap: () => Navigator.pop(ctx, 'pick'),
          ),
          if (_timeMinutes != null)
            ListTile(
              dense: true,
              leading: const Icon(Icons.schedule_outlined, size: 18),
              title: const Text('清除时间'),
              onTap: () => Navigator.pop(ctx, 'clearTime'),
            ),
        ],
      ),
    );
    if (v == null || !mounted) return;
    if (v == 'clearTime') {
      setState(() {
        _edited.add('time');
        _timeMinutes = null;
      });
      return;
    }
    if (v == 'pick') {
      final picked = await showDatePicker(
        context: context,
        initialDate: _day,
        firstDate: DateTime(2000),
        lastDate: DateTime(2100),
      );
      if (picked == null || !mounted) return;
      setState(() {
        _edited.add('day');
        _day = DateTime(picked.year, picked.month, picked.day);
      });
      return;
    }
    final offset = int.tryParse(v);
    if (offset == null) return;
    setState(() {
      _edited.add('day');
      _day = _today().add(Duration(days: offset));
    });
  }

  Widget _draftCard(
    BuildContext context,
    BillDraft draft,
    List<Bucket> buckets,
    List<Pocket> pockets,
    int? bucketId,
    int? pocketId,
  ) {
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 新装 App 不预置账户。不写清楚的话，用户会一直卡在
          // 「先选一个账户」却不知道去哪里建。
          if (pockets.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpace.md),
              child: Text(
                '还没有账户：先到「资产」页新建一个，回来就能语音记账。',
                style: const TextStyle(fontSize: 12, color: Palette.expense),
              ),
            ),
          Row(
            children: [
              Text(
                '账单草稿',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: Palette.ink(context)),
              ),
              const Spacer(),
              Text(
                '把握 ${(draft.confidence * 100).round()}%',
                style: TextStyle(
                    fontSize: 11.5, color: Palette.inkFaint(context)),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.sm),
          if (draft.notes.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final n in draft.notes)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Palette.mint(context),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: Text(
                      n,
                      style: TextStyle(
                          fontSize: 11, color: Palette.inkSoft(context)),
                    ),
                  ),
              ],
            ),
          if (draft.missing.isNotEmpty) ...[
            const SizedBox(height: AppSpace.sm),
            Text(
              '还需确认：${draft.missing.join('、')}',
              style: const TextStyle(fontSize: 12, color: Palette.expense),
            ),
          ],
          const SizedBox(height: AppSpace.lg),
          AppTextField(
            label: '金额（元）',
            controller: _amountCtrl,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            suffixText: '元',
            onChanged: (_) => _mark('amount'),
          ),
          const SizedBox(height: AppSpace.md),
          AppField(
            label: '类型',
            child: Wrap(
              spacing: 8,
              children: [
                for (final f in const [
                  ('out', '支出'),
                  ('in', '收入'),
                  ('transfer', '转账'),
                ])
                  ChoiceChip(
                    label: Text(f.$2),
                    selected: _flow == f.$1,
                    onSelected: (_) {
                      setState(() {
                        _edited.add('flow');
                        _flow = f.$1;
                        _bucketId = null;
                      });
                    },
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpace.md),
          if (_flow != 'transfer')
            AppDropdown<int?>(
              label: '分类',
              value: bucketId,
              items: [
                const DropdownMenuItem<int?>(
                    value: null, child: Text('未分类')),
                for (final b in buckets)
                  DropdownMenuItem<int?>(
                      value: b.id, child: Text(b.title)),
              ],
              onChanged: (v) {
                setState(() {
                  _edited.add('bucket');
                  _bucketId = v;
                });
              },
            ),
          if (_flow != 'transfer') const SizedBox(height: AppSpace.md),
          AppDropdown<int?>(
            label: _flow == 'transfer' ? '转出账户' : '账户',
            value: pocketId,
            items: [
              if (pockets.isEmpty)
                const DropdownMenuItem<int?>(
                    value: null, child: Text('还没有账户')),
              for (final p in pockets)
                DropdownMenuItem<int?>(
                    value: p.id, child: Text(p.displayName)),
            ],
            onChanged: (v) {
              setState(() {
                _edited.add('pocket');
                _pocketId = v;
              });
            },
          ),
          if (_flow == 'transfer') ...[
            const SizedBox(height: AppSpace.md),
            AppDropdown<int?>(
              label: '转入账户',
              value: _toPocketId,
              items: [
                const DropdownMenuItem<int?>(
                    value: null, child: Text('请选择')),
                for (final p in pockets)
                  DropdownMenuItem<int?>(
                      value: p.id, child: Text(p.displayName)),
              ],
              onChanged: (v) {
                setState(() {
                  _edited.add('toPocket');
                  _toPocketId = v;
                });
              },
            ),
          ],
          const SizedBox(height: AppSpace.md),
          AppField(
            label: '日期',
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(dayKey(_day),
                    style: TextStyle(fontSize: 14, color: Palette.ink(context))),
                for (final d in const [
                  ('今天', 0),
                  ('昨天', -1),
                  ('前天', -2),
                ])
                  ActionChip(
                    label: Text(d.$1),
                    onPressed: () {
                      setState(() {
                        _edited.add('day');
                        _day = _today().add(Duration(days: d.$2));
                      });
                    },
                  ),
                IconButton(
                  tooltip: '选日期',
                  visualDensity: VisualDensity.compact,
                  onPressed: _pickDay,
                  icon: const Icon(Icons.date_range_outlined, size: 18),
                ),
              ],
            ),
          ),
          if (_timeMinutes != null) ...[
            const SizedBox(height: AppSpace.sm),
            Row(
              children: [
                Text(
                  '时间 ${pad2(_timeMinutes! ~/ 60)}:${pad2(_timeMinutes! % 60)}',
                  style: TextStyle(
                      fontSize: 12, color: Palette.inkSoft(context)),
                ),
                const SizedBox(width: AppSpace.xs),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _edited.add('time');
                      _timeMinutes = null;
                    });
                  },
                  child: Text(
                    '清除',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkFaint(context)),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpace.md),
          AppTextField(
            label: '备注',
            controller: _memoCtrl,
            onChanged: (_) => _mark('memo'),
          ),
        ],
      ),
    );
  }
}

/// 「自定义分类」的输入面板。独立 StatefulWidget 只是为了把
/// TextEditingController 的 dispose 推迟到面板真正从树上摘掉之后。
class _NameSheet extends StatefulWidget {
  const _NameSheet({required this.initial, required this.hint});

  final String initial;
  final String hint;

  @override
  State<_NameSheet> createState() => _NameSheetState();
}

class _NameSheetState extends State<_NameSheet> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            maxLength: 12,
            style: TextStyle(fontSize: 15, color: Palette.ink(context)),
            decoration: InputDecoration(
              isDense: true,
              counterText: '',
              hintText: widget.hint,
              hintStyle:
                  TextStyle(fontSize: 13, color: Palette.inkFaint(context)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
                borderSide: BorderSide(color: Palette.hairline(context)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.control),
                borderSide: BorderSide(color: Palette.brand(context)),
              ),
            ),
            onSubmitted: (v) => Navigator.pop(context, v),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context, _ctrl.text),
              child: const Text('创建并选用'),
            ),
          ),
        ],
      ),
    );
  }
}

class _IntroCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Panel(
      tint: Palette.mint(context),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.keyboard_voice_outlined,
              size: 20, color: Palette.inkSoft(context)),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Text(
              '用输入法的麦克风说话，文字会自动变成账单草稿；'
              '确认一下金额、分类和账户再保存。'
              '文字只在本机解析，不上传任何音频。',
              style: TextStyle(
                  fontSize: 12, height: 1.5, color: Palette.inkSoft(context)),
            ),
          ),
        ],
      ),
    );
  }
}
