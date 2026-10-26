import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/currency.dart';
import '../core/pocket_types.dart';
import '../data/store.dart';
import '../services/icon_service.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'amount_keypad.dart';
import 'app_glyph.dart';
import 'common.dart';
import 'theme.dart';

/// 账户编辑页（新增 / 修改）。
///
/// 2026-10-26 用户要求「照 iCost 改」：原来的表单是 AppBar + SectionLabel +
/// 一堆带外框输入框 + 底部大按钮，太杂。现在改成 iCost 的样子：
/// - 顶栏：圆形返回 / 居中标题 / 圆形 ✓（保存）；
/// - 主体：分组白卡，卡内一行「左标签 · 右值 ›」，行间细分隔线；
/// - 类型选择：独立页「选择类型」，分组列表（只露 7 个常用类型）。
///
/// **数据口径和保存逻辑一个字没动**，只换皮。
class AccountEditPage extends ConsumerStatefulWidget {
  const AccountEditPage({super.key, this.pocket});

  final Pocket? pocket;

  /// 图标栏默认图标（自定义图片由 GlyphPicker 的相册入口负责）
  static const glyphs = ['💚', '🅰️', '🏦', '💳'];

  @override
  ConsumerState<AccountEditPage> createState() => _AccountEditPageState();
}

class _AccountEditPageState extends ConsumerState<AccountEditPage> {
  late final TextEditingController _titleCtrl;

  /// 简称（如「工资卡」）。列表/选择器优先显示它。
  late final TextEditingController _aliasCtrl;

  /// 卡号，仅个人备忘。
  late final TextEditingController _cardNoCtrl;

  /// 备注（账户级，仅个人备忘）。
  late final TextEditingController _noteCtrl;

  // —— v15 新增的「账户信息页」字段（见 store.dart 迁移说明）——
  bool _includeInAssets = true;
  String _glyphDark = '';
  bool _sharedLimit = false;
  bool _billNextPeriod = false;
  String _annualFee = '无';
  String _incomeSync = '无';
  bool _recordable = true;
  String _visibleBookIds = '';

  // —— v16 新增「贷款」专属字段（见 store.dart 迁移说明）——
  /// 贷款年利率（百分比，例如 5.8 表示 5.8%）。
  double _annualRate = 0;
  /// 贷款期数（月）。
  int _periods = 0;
  /// 还款方式：0 等额本息 / 1 等额本金 / 2 先息后本 / 3 一次性还本付息。
  int _repaymentMethod = 0;

  /// 期初余额（分）。用自有金额键盘输入，不再走系统数字键盘。
  int _openingCents = 0;

  /// 信用额度（分）
  int _limitCents = 0;
  late PocketKind _kind;

  /// 类型预设 id（见 core/pocket_types.dart）。'' = 老账户还没认过类型。
  late String _typeId;
  late String _glyph;
  late String _currency;
  int? _billingDay;
  int? _paymentDueDay;
  bool _saving = false;

  bool get _isEdit => widget.pocket != null;

  @override
  void initState() {
    super.initState();
    final p = widget.pocket;
    _titleCtrl = TextEditingController(text: p?.title ?? '');
    _aliasCtrl = TextEditingController(text: p?.alias ?? '');
    _cardNoCtrl = TextEditingController(text: p?.cardNo ?? '');
    _openingCents = p?.openingCents ?? 0;
    _limitCents = p?.creditLimitCents ?? 0;
    _kind = p?.kind ?? PocketKind.cash;
    // 老账户没存过 type，按 kind + 图标反推一个，编辑时才不会空着；
    // 新建直接给「现金钱包」（iCost 选择器的第一项）——
    // ⚠️ 别走 guessPocketType：它对空图标会命中同名的 cash，新建就变「现金」了。
    if (p == null) {
      _typeId = 'cashWallet';
    } else if (p.typeId.isNotEmpty) {
      _typeId = p.typeId;
    } else {
      // 老账户 typeId 是空串（不是 null），得显式判 isNotEmpty 才会走到反推
      _typeId = guessPocketType(p.kind, p.glyph)?.id ?? 'cash';
    }
    _glyph = p?.glyph ?? '💵';
    _currency = p?.currency ?? 'CNY';
    _billingDay = p?.billingDay;
    _paymentDueDay = p?.paymentDueDay;
    _noteCtrl = TextEditingController(text: p?.note ?? '');
    _includeInAssets = p?.includeInAssets ?? true;
    _glyphDark = p?.glyphDark ?? '';
    _sharedLimit = p?.sharedLimit ?? false;
    _billNextPeriod = p?.billNextPeriod ?? false;
    _annualFee = p?.annualFee ?? '无';
    _incomeSync = p?.incomeSync ?? '无';
    _recordable = p?.recordable ?? true;
    _visibleBookIds = p?.visibleBookIds ?? '';
    _annualRate = p?.annualRate ?? 0;
    _periods = p?.periods ?? 0;
    _repaymentMethod = p?.repaymentMethod ?? 0;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _aliasCtrl.dispose();
    _cardNoCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _titleCtrl.text.trim();
    if (name.isEmpty) {
      _toast('给账户起个名字');
      return;
    }
    setState(() => _saving = true);
    try {
      final store = await ref.read(storeProvider.future);
      final book = await ref.read(activeBookProvider.future);
      final opening = _openingCents;
      final limit = _limitCents;
      if (_isEdit) {
        final old = widget.pocket!;
        // 改币种或账户类型会**重新解释所有历史金额**，必须让用户知道：
        //   · CNY 卡改成 USD → 统计按汇率折算，总额可能翻 7 倍
        //   · 现金改成信用卡 → 余额符号翻转（+1000 变成欠 1000）
        // 原来没有任何提示，用户以为只是改了个标签。
        if (old.currency != _currency || old.kind != _kind) {
          final n = await store.countEntriesOfPocket(old.id);
          if (n > 0 && mounted) {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('历史流水会按新设置重算'),
                content: Text(
                  '「${old.title}」名下已有 $n 笔流水。\n\n'
                  '改币种后，这些金额会按新币种解释（统计和余额都会变）；'
                  '改账户类型可能让余额正负翻转。\n\n'
                  '确定继续吗？',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('继续'),
                  ),
                ],
              ),
            );
            if (ok != true) {
              if (mounted) setState(() => _saving = false);
              return;
            }
          }
        }
        await store.updatePocket(Pocket(
          id: old.id,
          bookId: old.bookId,
          title: name,
          glyph: _glyph,
          kind: _kind,
          currency: _currency,
          openingCents: opening,
          archived: old.archived,
          creditLimitCents: _kind.isLiability ? limit : 0,
          billingDay: _kind == PocketKind.credit ? _billingDay : null,
          paymentDueDay: _kind == PocketKind.credit ? _paymentDueDay : null,
          alias: _aliasCtrl.text.trim(),
          cardNo: _cardNoCtrl.text.trim(),
          typeId: _typeId,
          note: _noteCtrl.text.trim(),
          includeInAssets: _includeInAssets,
          glyphDark: _glyphDark,
          sharedLimit: _sharedLimit,
          billNextPeriod: _billNextPeriod,
          annualFee: _annualFee,
          incomeSync: _incomeSync,
          recordable: _recordable,
          visibleBookIds: _visibleBookIds,
          annualRate: _annualRate,
          periods: _periods,
          repaymentMethod: _repaymentMethod,
        ));
      } else {
        await store.addPocket(
          bookId: book.id,
          title: name,
          glyph: _glyph,
          kind: _kind,
          currency: _currency,
          openingCents: opening,
          creditLimitCents: _kind.isLiability ? limit : 0,
          billingDay: _kind == PocketKind.credit ? _billingDay : null,
          paymentDueDay: _kind == PocketKind.credit ? _paymentDueDay : null,
          alias: _aliasCtrl.text.trim(),
          cardNo: _cardNoCtrl.text.trim(),
          typeId: _typeId,
          note: _noteCtrl.text.trim(),
          includeInAssets: _includeInAssets,
          glyphDark: _glyphDark,
          sharedLimit: _sharedLimit,
          billNextPeriod: _billNextPeriod,
          annualFee: _annualFee,
          incomeSync: _incomeSync,
          recordable: _recordable,
          visibleBookIds: _visibleBookIds,
          annualRate: _annualRate,
          periods: _periods,
          repaymentMethod: _repaymentMethod,
        );
      }
      bumpRevision(ref);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('保存失败，请重试');
      debugPrint('账户保存失败: $e');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    return Scaffold(
      backgroundColor: Palette.paper(context),
      body: SafeArea(
        child: Column(
          children: [
            _topBar(context),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 28),
                children: [
                  // —— 基本信息 ——
                  _cardBox(context, [
                    _typeRow(context),
                    _inputRow(context, '名称', _titleCtrl,
                        hint: pocketTypeOf(_typeId)?.hint ?? '请输入账户名称'),
                    _valueRow(context, _openingLabel(_kind),
                        _openingText(settings),
                        onTap: _pickOpening, last: _kind.isLiability),
                    if (!_kind.isLiability)
                      _valueRow(context, '币种',
                          '${nameOf(_currency)}（$_currency）',
                          onTap: _pickCurrency, last: false),
                    _inputRow(context, '简称', _aliasCtrl,
                        hint: '如工资卡、农行，可用于账户快速识别', maxLength: 12),
                    _inputRow(context, '备注', _noteCtrl, hint: '选填'),
                    _inputRow(context, '卡号', _cardNoCtrl,
                        hint: '仅备注，不参与计算', maxLength: 24, last: true),
                  ]),
                  _caption(context,
                      '卡号仅用作个人备注，不涉及任何金融交易，可不填写'),

                  // —— 信用卡：额度与日期 ——
                  if (_kind == PocketKind.credit) ...[
                    const SizedBox(height: 12),
                    _cardBox(context, [
                      _valueRow(context, '总额度', _limitText(settings),
                          onTap: _pickLimit, last: false),
                      _switchRow(context, '额度共享', _sharedLimit,
                          (v) => setState(() => _sharedLimit = v), last: false),
                      _valueRow(
                          context,
                          '出账日期',
                          _billingDay == null ? '选填' : '每月 $_billingDay 日',
                          onTap: () => _pickDay(billing: true),
                          last: false),
                      _valueRow(
                          context,
                          '还款日期',
                          _paymentDueDay == null
                              ? '选填'
                              : '每月 $_paymentDueDay 日',
                          onTap: () => _pickDay(billing: false),
                          last: false),
                      _switchRow(context, '出账日消费计入下一期', _billNextPeriod,
                          (v) => setState(() => _billNextPeriod = v),
                          last: false),
                      _valueRow(context, '年费设置', _annualFee,
                          onTap: _pickAnnualFee, last: true),
                    ]),
                    const SizedBox(height: 12),
                    _cardBox(context, [_glyphRow(context, last: true)]),
                  ] else if (_kind == PocketKind.debt) ...[
                    // —— 贷款：专属字段（年利率 / 期数 / 还款方式）——
                    const SizedBox(height: 12),
                    _cardBox(context, [
                      _loanRateRow(context),
                      _loanPeriodsRow(context),
                      _valueRow(context, '还款方式', _repaymentMethodName,
                          onTap: _pickRepaymentMethod, last: true),
                    ]),
                    if (_loanPreview.isNotEmpty)
                      _caption(context, _loanPreview),
                    const SizedBox(height: 12),
                    _cardBox(context, [_glyphRow(context, last: true)]),
                  ] else ...[
                    // —— 其他账户：图标与分组 ——
                    const SizedBox(height: 12),
                    _cardBox(context, [
                      _glyphRow(context),
                      _glyphDarkRow(context),
                      _valueRow(context, '所属分组', _groupName,
                          onTap: _openTypePicker, last: false),
                      _valueRow(context, '收益同步', _incomeSync,
                          onTap: _pickIncomeSync, last: true),
                    ]),
                    _caption(context,
                        '收益同步：余额宝、零钱通等收益自动同步（需云端，暂未启用）'),
                    const SizedBox(height: 12),
                    // —— 账本相关 ——
                    _cardBox(context, [
                      _switchRow(context, '计入总资产', _includeInAssets,
                          (v) => setState(() => _includeInAssets = v),
                          last: false),
                      _switchRow(context, '记账可被选择', _recordable,
                          (v) => setState(() => _recordable = v), last: false),
                      _valueRow(context, '选择生效账本', _booksLabel,
                          onTap: _pickBooks, last: true),
                    ]),
                    _caption(context,
                        '选择生效账本：仅在勾选的账本记账时，该账户才会出现在选账户列表'),
                  ],
                  const SizedBox(height: 20),
                  Text(
                    '账户一旦有流水就删不掉了，只能归档。期初余额只是起点，之后每笔都会算进去。',
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: Palette.inkFaint(context)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: SizedBox(
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: _RoundIconButton(
                icon: Icons.chevron_left,
                onTap: () => Navigator.of(context).maybePop(),
              ),
            ),
            Text(
              _isEdit ? '编辑账户' : '添加账户',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: Palette.ink(context)),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _RoundIconButton(
                icon: Icons.check,
                filled: true,
                busy: _saving,
                onTap: _saving ? null : _save,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 卡片 / 行

  Widget _cardBox(BuildContext context, List<Widget> children) {
    return Material(
      color: Palette.card(context),
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  Widget _hairline(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 16),
        child: Container(height: 0.5, color: Palette.hairline(context)),
      );

  /// 点一下能进下一层的行：左标签 + 右值 + ›
  Widget _valueRow(
    BuildContext context,
    String label,
    String value, {
    VoidCallback? onTap,
    bool last = false,
  }) {
    return InkWell(
      onTap: onTap,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            child: Row(
              children: [
                Text(label,
                    style:
                        TextStyle(fontSize: 15, color: Palette.ink(context))),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    value,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14.5, color: Palette.inkFaint(context)),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right,
                    size: 18, color: Palette.inkFaint(context)),
              ],
            ),
          ),
          if (!last) _hairline(context),
        ],
      ),
    );
  }

  /// 直接在本行输入的字段（右侧对齐、无边框）
  Widget _inputRow(
    BuildContext context,
    String label,
    TextEditingController ctrl, {
    String? hint,
    int? maxLength,
    bool last = false,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text(label,
                  style: TextStyle(fontSize: 15, color: Palette.ink(context))),
              const SizedBox(width: 20),
              Expanded(
                child: TextField(
                  controller: ctrl,
                  textAlign: TextAlign.right,
                  maxLength: maxLength,
                  style:
                      TextStyle(fontSize: 14.5, color: Palette.ink(context)),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    counterText: '',
                    hintText: hint,
                    hintStyle: TextStyle(
                        fontSize: 14.5, color: Palette.inkFaint(context)),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!last) _hairline(context),
      ],
    );
  }

  /// 卡内第一行：类型预览（图标 + 名称），点它去选择类型
  Widget _typeRow(BuildContext context) {
    final preset = pocketTypeOf(_typeId);
    final label = preset?.label ?? _kind.label;
    final badge = kTypeBadges[_typeId];
    return InkWell(
      onTap: _openTypePicker,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: [
                IconService.isImage(_glyph)
                    ? SizedBox(
                        width: 38,
                        height: 38,
                        child:
                            AppGlyph(_glyph, size: 21, fill: true, radius: 10),
                      )
                    : TypeBadgeView(
                        badge ??
                            TypeBadge(
                                tint: _kindColorOf(_kind), emoji: _glyph),
                        size: 38,
                      ),
                const SizedBox(width: 12),
                Text(label,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Palette.ink(context))),
                const Spacer(),
                Icon(Icons.chevron_right,
                    size: 18, color: Palette.inkFaint(context)),
              ],
            ),
          ),
          _hairline(context),
        ],
      ),
    );
  }

  Widget _glyphRow(BuildContext context, {bool last = false}) {
    return InkWell(
      onTap: _pickGlyph,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Text('账户图标',
                    style: TextStyle(fontSize: 15, color: Palette.ink(context))),
                const Spacer(),
                SizedBox(
                  width: 30,
                  height: 30,
                  child: AppGlyph(_glyph, size: 20, fill: true, radius: 8),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right,
                    size: 18, color: Palette.inkFaint(context)),
              ],
            ),
          ),
          if (!last) _hairline(context),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 交互

  Future<void> _openTypePicker() async {
    final picked = await Navigator.of(context).push<PocketType>(
      MaterialPageRoute(builder: (_) => _AccountTypePage(selectedId: _typeId)),
    );
    if (picked != null && mounted) _applyType(picked);
  }

  /// 选中类型后：图标、口径、名称提示一起跟着变。
  ///
  /// 名称只在「空着」或「还是上一个类型的默认名」时才自动填 —— 用户手写的
  /// 「招行工资卡」绝不能被换类型时覆盖掉。
  void _applyType(PocketType t) {
    final current = _titleCtrl.text.trim();
    final prev = pocketTypeOf(_typeId);
    setState(() {
      _typeId = t.id;
      _kind = t.kind;
      // 用户自己从相册挑的图，**换类型不能冲掉**。
      if (!IconService.isImage(_glyph)) _glyph = t.glyph;
      if (current.isEmpty || (prev != null && current == prev.label)) {
        _titleCtrl.text = t.label;
        _titleCtrl.selection =
            TextSelection.collapsed(offset: _titleCtrl.text.length);
      }
      // 切到非信用卡时清掉还款周期，避免残留脏值
      if (t.kind != PocketKind.credit) {
        _billingDay = null;
        _paymentDueDay = null;
      }
    });
  }

  Future<void> _pickOpening() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final v = await showAmountKeypad(
      context,
      initialCents: _openingCents,
      title: _openingLabel(_kind),
      symbol: symbolOf(_currency),
      allowZero: true,
    );
    if (v != null && mounted) setState(() => _openingCents = v);
  }

  Future<void> _pickLimit() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final v = await showAmountKeypad(
      context,
      initialCents: _limitCents,
      title: '信用额度',
      symbol: symbolOf(_currency),
      allowZero: true,
    );
    if (v != null && mounted) setState(() => _limitCents = v);
  }

  Future<void> _pickCurrency() async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final e in kCurrencies.entries)
              ListTile(
                title: Text('${e.value.$2}（${e.key}）'),
                trailing: e.key == _currency
                    ? Icon(Icons.check, color: Palette.brand(ctx))
                    : null,
                onTap: () => Navigator.of(ctx).pop(e.key),
              ),
          ],
        ),
      ),
    );
    if (v != null && mounted) setState(() => _currency = v);
  }

  /// 账单日 / 还款日：1-28 号（不会有 2 月 30 号这种坑）。0 = 不设置。
  Future<void> _pickDay({required bool billing}) async {
    final current = billing ? _billingDay : _paymentDueDay;
    final v = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('不设置'),
              trailing: current == null
                  ? Icon(Icons.check, color: Palette.brand(ctx))
                  : null,
              onTap: () => Navigator.of(ctx).pop(0),
            ),
            for (var d = 1; d <= 28; d++)
              ListTile(
                title: Text('每月 $d 日'),
                trailing: current == d
                    ? Icon(Icons.check, color: Palette.brand(ctx))
                    : null,
                onTap: () => Navigator.of(ctx).pop(d),
              ),
          ],
        ),
      ),
    );
    if (v == null) return;
    if (!mounted) return;
    setState(() {
      final value = v == 0 ? null : v;
      if (billing) {
        _billingDay = value;
      } else {
        _paymentDueDay = value;
      }
    });
  }

  Future<void> _pickGlyph() async {
    final g = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: GlyphPicker(
          glyphs: AccountEditPage.glyphs,
          value: _glyph,
          onChanged: (v) => Navigator.of(ctx).pop(v),
        ),
      ),
    );
    if (g != null && mounted) setState(() => _glyph = g);
  }

  Future<void> _pickGlyphDark() async {
    final g = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: GlyphPicker(
          glyphs: AccountEditPage.glyphs,
          value: _glyphDark.isEmpty ? _glyph : _glyphDark,
          onChanged: (v) => Navigator.of(ctx).pop(v),
        ),
      ),
    );
    if (g != null && mounted) setState(() => _glyphDark = g);
  }

  Widget _glyphDarkRow(BuildContext context) {
    final g = _glyphDark.isEmpty ? _glyph : _glyphDark;
    return InkWell(
      onTap: _pickGlyphDark,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Text('夜间模式图标',
                    style: TextStyle(fontSize: 15, color: Palette.ink(context))),
                const Spacer(),
                SizedBox(
                  width: 30,
                  height: 30,
                  child: AppGlyph(g, size: 20, fill: true, radius: 8),
                ),
                const SizedBox(width: 6),
                if (_glyphDark.isEmpty)
                  Text('自动',
                      style: TextStyle(
                          fontSize: 13, color: Palette.inkFaint(context))),
                Icon(Icons.chevron_right,
                    size: 18, color: Palette.inkFaint(context)),
              ],
            ),
          ),
          _hairline(context),
        ],
      ),
    );
  }

  /// 左标签 + 右侧开关。
  Widget _switchRow(BuildContext context, String label, bool value,
      ValueChanged<bool> onChanged, {bool last = false}) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
            child: Row(
              children: [
                Expanded(
                  child: Text(label,
                      style:
                          TextStyle(fontSize: 15, color: Palette.ink(context))),
                ),
                Switch(
                  value: value,
                  onChanged: onChanged,
                  activeThumbColor: Palette.brand(context),
                  activeTrackColor: Palette.brand(context).withValues(alpha: 0.5),
                ),
              ],
            ),
          ),
          if (!last) _hairline(context),
        ],
      ),
    );
  }

  /// 卡片下方灰色说明文字。
  Widget _caption(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
        child: Text(text,
            style: TextStyle(
                fontSize: 11, height: 1.5, color: Palette.inkFaint(context))),
      );

  /// 所属分组：优先取选择器展示分组名（资金账户 / 信贷账户 …），
  /// 该类型不在选择器里时退回 PocketType.group，再退回 kind 名。
  String get _groupName {
    for (final g in kAccountChooserGroups) {
      if (g.$2.contains(_typeId)) return g.$1;
    }
    return pocketTypeOf(_typeId)?.group ?? _kind.label;
  }

  String get _booksLabel => _visibleBookIds.trim().isEmpty
      ? '全部账本'
      : '${_visibleBookIds.split(',').where((s) => s.trim().isNotEmpty).length} 个账本';

  Future<void> _pickAnnualFee() async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final o in const ['无', '减免', '有年费'])
              ListTile(
                title: Text(o),
                trailing: _annualFee == o
                    ? Icon(Icons.check, color: Palette.brand(ctx))
                    : null,
                onTap: () => Navigator.of(ctx).pop(o),
              ),
          ],
        ),
      ),
    );
    if (v != null && mounted) setState(() => _annualFee = v);
  }

  Future<void> _pickIncomeSync() async {
    final v = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final o in const ['无', '每日', '每月'])
              ListTile(
                title: Text(o),
                trailing: _incomeSync == o
                    ? Icon(Icons.check, color: Palette.brand(ctx))
                    : null,
                onTap: () => Navigator.of(ctx).pop(o),
              ),
          ],
        ),
      ),
    );
    if (v != null && mounted) setState(() => _incomeSync = v);
  }

  Future<void> _pickBooks() async {
    final books = ref.read(booksProvider).valueOrNull ?? const <Book>[];
    final selected = <int>{
      for (final s in _visibleBookIds.split(','))
        int.tryParse(s.trim()) ?? -1
    }..remove(-1);
    final result = await showModalBottomSheet<Set<int>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('全部账本'),
                trailing: selected.isEmpty
                    ? Icon(Icons.check, color: Palette.brand(ctx))
                    : null,
                onTap: () => Navigator.of(ctx).pop(<int>{}),
              ),
              for (final b in books)
                ListTile(
                  title: Text(b.title),
                  trailing: selected.contains(b.id)
                      ? Icon(Icons.check, color: Palette.brand(ctx))
                      : null,
                  onTap: () {
                    if (selected.contains(b.id)) {
                      selected.remove(b.id);
                    } else {
                      selected.add(b.id);
                    }
                    setSheet(() {});
                  },
                ),
              if (books.isNotEmpty)
                ListTile(
                  title: const Text('完成'),
                  onTap: () => Navigator.of(ctx).pop({...selected}),
                ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    if (mounted) {
      setState(() =>
          _visibleBookIds = result.isEmpty ? '' : result.join(','));
    }
  }

  // ---------------------------------------------------------------- 贷款字段

  /// 贷款年利率输入行：右侧直接输入百分比数字（如 5.8）。
  Widget _loanRateRow(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text('年利率',
                  style: TextStyle(fontSize: 15, color: Palette.ink(context))),
              const SizedBox(width: 20),
              Expanded(
                child: TextField(
                  controller: TextEditingController(
                      text: _annualRate == 0
                          ? ''
                          : _annualRate.toStringAsFixed(2)),
                  textAlign: TextAlign.right,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  style:
                      TextStyle(fontSize: 14.5, color: Palette.ink(context)),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    counterText: '',
                    hintText: '例如 5.8（%）',
                    hintStyle: TextStyle(
                        fontSize: 14.5, color: Palette.inkFaint(context)),
                    suffixText: '%',
                  ),
                  onChanged: (v) =>
                      _annualRate = double.tryParse(v.trim()) ?? 0,
                ),
              ),
            ],
          ),
        ),
        _hairline(context),
      ],
    );
  }

  /// 贷款期数输入行：右侧直接输入月数（整数）。
  Widget _loanPeriodsRow(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text('期数',
                  style: TextStyle(fontSize: 15, color: Palette.ink(context))),
              const SizedBox(width: 20),
              Expanded(
                child: TextField(
                  controller: TextEditingController(
                      text: _periods == 0 ? '' : _periods.toString()),
                  textAlign: TextAlign.right,
                  keyboardType: TextInputType.number,
                  style:
                      TextStyle(fontSize: 14.5, color: Palette.ink(context)),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: false,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    counterText: '',
                    hintText: '例如 12（月）',
                    hintStyle: TextStyle(
                        fontSize: 14.5, color: Palette.inkFaint(context)),
                    suffixText: '月',
                  ),
                  onChanged: (v) => _periods = int.tryParse(v.trim()) ?? 0,
                ),
              ),
            ],
          ),
        ),
        _hairline(context),
      ],
    );
  }

  static const List<String> _repaymentMethods = [
    '等额本息',
    '等额本金',
    '先息后本',
    '一次性还本付息',
  ];

  String get _repaymentMethodName =>
      _repaymentMethods[_repaymentMethod.clamp(0, 3)];

  Future<void> _pickRepaymentMethod() async {
    final v = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < _repaymentMethods.length; i++)
              ListTile(
                title: Text(_repaymentMethods[i]),
                trailing: _repaymentMethod == i
                    ? Icon(Icons.check, color: Palette.brand(ctx))
                    : null,
                onTap: () => Navigator.of(ctx).pop(i),
              ),
          ],
        ),
      ),
    );
    if (v != null && mounted) setState(() => _repaymentMethod = v);
  }

  String get _loanPreview {
    if (_annualRate <= 0 || _periods <= 0 || _openingCents <= 0) return '';
    final P = _openingCents / 100; // 欠款本金（账户币种）
    final r = _annualRate / 100 / 12; // 月利率
    final n = _periods;
    final sym = symbolOf(_currency);
    String fmt(double v) => '$sym${v.toStringAsFixed(2)}';
    switch (_repaymentMethod) {
      case 1: // 等额本金
        final m1 = P / n + P * r;
        final perMonthDown = P * r / n;
        final totalInterest = P * r * (n + 1) / 2;
        return '等额本金：首月约 ${fmt(m1)}，每月递减 ${fmt(perMonthDown)}，'
            '总利息约 ${fmt(totalInterest)}';
      case 2: // 先息后本
        final monthly = P * r;
        final totalInterest = P * r * n;
        return '先息后本：每月利息约 ${fmt(monthly)}，到期一次性还本金 ${fmt(P)}'
            '，总利息约 ${fmt(totalInterest)}';
      case 3: // 一次性还本付息
        final totalInterest = P * _annualRate / 100 * n;
        return '一次性还本付息：到期一次性还约 '
            '${fmt(P + totalInterest)}（利息 ${fmt(totalInterest)}）';
      default: // 等额本息
        final m = r == 0
            ? P / n
            : P * r * pow(1 + r, n) / (pow(1 + r, n) - 1);
        final totalInterest = m * n - P;
        return '等额本息：每月约 ${fmt(m)}，总利息约 ${fmt(totalInterest)}';
    }
  }

  // ---------------------------------------------------------------- 文案

  String _openingText(AppSettings s) {
    if (s.hideAmounts) return '****';
    if (_openingCents == 0) return '请输入${_openingLabel(_kind)}';
    return '${s.symbol}${(_openingCents / 100).toStringAsFixed(2)}';
  }

  String _limitText(AppSettings s) {
    if (s.hideAmounts) return '****';
    if (_limitCents == 0) {
      return _kind == PocketKind.credit ? '请输入总额度' : '可不填';
    }
    return '${s.symbol}${(_limitCents / 100).toStringAsFixed(2)}';
  }

  static String _openingLabel(PocketKind k) => switch (k) {
        PocketKind.cash => '余额',
        PocketKind.bank => '余额',
        PocketKind.credit => '欠款',
        PocketKind.debt => '欠款',
      };
}

/// 选择类型页里每个类型的「彩色徽标」：彩色圆角方底 + 白色字形 / Material 图标。
/// 设计过的图标，比五花八门的 emoji 好看、也和全 App 一致。
class TypeBadge {
  const TypeBadge({
    required this.tint,
    this.icon,
    this.text,
    this.emoji,
  });
  final Color tint;
  final IconData? icon;
  final String? text;
  final String? emoji;
}

/// 每个类型对应的徽标（id → 配色 + 字形）。没列进来的类型走 [_fallbackBadge]。
const Map<String, TypeBadge> kTypeBadges = {
  // 资金账户
  'cash': TypeBadge(tint: Color(0xFFF2A33C), text: '¥'),
  'alipay': TypeBadge(tint: Color(0xFF1677FF), text: '支'),
  'wechatWallet': TypeBadge(tint: Color(0xFF07C160), text: '微'),
  'bankcard': TypeBadge(tint: Color(0xFF3C7EED), icon: Icons.credit_card),
  'qq': TypeBadge(tint: Color(0xFF12B7F5), text: 'Q'),
  'jd': TypeBadge(tint: Color(0xFFE1251B), text: '京'),
  'custom': TypeBadge(tint: Color(0xFF15B8A6), icon: Icons.star),
  // 信贷账户
  'credit': TypeBadge(tint: Color(0xFF8A9099), icon: Icons.credit_card),
  'huabei': TypeBadge(tint: Color(0xFF2F6BFF), text: '花'),
  'baitiaoPlain': TypeBadge(tint: Color(0xFFE1251B), text: '白条'),
  // 信贷列的「自定义」：和资金列的 custom 是两个类型（口径不同），
  // 徽标配色也换掉，免得两列都是同款青绿星星分不清。
  'customCredit': TypeBadge(tint: Color(0xFF7C5CD6), icon: Icons.star),
  // 充值账户
  'member': TypeBadge(tint: Color(0xFFC99B3B), icon: Icons.card_membership),
  'transit': TypeBadge(tint: Color(0xFF1FA463), icon: Icons.directions_bus),
  'meal': TypeBadge(tint: Color(0xFFE8833A), icon: Icons.restaurant),
  'depositCard': TypeBadge(tint: Color(0xFF3C7EED), text: '押'),
  // 投资理财
  'insurance': TypeBadge(tint: Color(0xFF3C7EED), text: '保'),
  'crypto': TypeBadge(tint: Color(0xFF9B59B6), icon: Icons.currency_bitcoin),
  // 二手货物
  'house': TypeBadge(tint: Color(0xFFE0533D), icon: Icons.home),
  'car': TypeBadge(tint: Color(0xFF3C7EED), icon: Icons.directions_car),
  // 债务
  'borrowIn': TypeBadge(tint: Color(0xFFE0A93D), icon: Icons.call_received),
  'lendOut': TypeBadge(tint: Color(0xFF15B8A6), icon: Icons.call_made),
  'reimburse': TypeBadge(tint: Color(0xFF3C7EED), icon: Icons.receipt_long),
};

/// 「选择类型」独立页（参考 App 风格）：顶栏返回 + 居中标题，下面是
/// **分组 + 网格式**的彩色徽标（图标在上、名称在下，每行 5 个）。
///
/// 只露 [kAccountChooserGroups] 里的类型；老类型仍然能通过
/// `pocketTypeOf` 解析（老账户不受影响）。
class _AccountTypePage extends StatelessWidget {
  const _AccountTypePage({required this.selectedId});

  final String selectedId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Palette.paper(context),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: SizedBox(
                height: 44,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _RoundIconButton(
                        icon: Icons.chevron_left,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    Text('选择类型',
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: Palette.ink(context))),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 2, 16, 28),
                children: [
                  for (final g in kAccountChooserGroups) ...[
                    _sectionHeader(context, g.$1),
                    _grid(context, g.$2),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 10),
        child: Text(title,
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Palette.inkSoft(context))),
      );

  Widget _grid(BuildContext context, List<String> ids) => GridView.count(
        crossAxisCount: 5,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 16,
        crossAxisSpacing: 8,
        childAspectRatio: 0.82,
        children: [for (final id in ids) _gridItem(context, id)],
      );

  Widget _gridItem(BuildContext context, String id) {
    final t = pocketTypeOf(id);
    if (t == null) return const SizedBox.shrink();
    final selected = id == selectedId;
    return InkWell(
      onTap: () => Navigator.of(context).pop(t),
      borderRadius: BorderRadius.circular(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TypeBadgeView(kTypeBadges[id] ?? _fallbackBadge(t),
              size: 48, selected: selected),
          const SizedBox(height: 6),
          Text(t.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11.5, color: Palette.ink(context))),
        ],
      ),
    );
  }
}

/// 彩色圆角方徽标：白字 / 白图标画在 tint 上；选中时加品牌色描边 + 角标对勾。
class TypeBadgeView extends StatelessWidget {
  const TypeBadgeView(this.badge,
      {super.key, this.size = 48, this.selected = false});

  final TypeBadge badge;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final radius = size * 0.28;
    final child = Center(
      child: badge.icon != null
          ? Icon(badge.icon, size: size * 0.54, color: Colors.white)
          : (badge.text != null
              ? Text(badge.text!,
                  style: TextStyle(
                    fontSize:
                        badge.text!.length > 1 ? size * 0.32 : size * 0.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ))
              : Text(badge.emoji ?? '🧾',
                  style: TextStyle(fontSize: size * 0.5))),
    );
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: badge.tint,
        borderRadius: BorderRadius.circular(radius),
        border: selected
            ? Border.all(color: Palette.brand(context), width: 2.5)
            : null,
        boxShadow: selected
            ? [
                BoxShadow(
                  color: Palette.brand(context).withValues(alpha: 0.3),
                  blurRadius: 6,
                  spreadRadius: 1,
                )
              ]
            : null,
      ),
      child: Stack(
        children: [
          child,
          if (selected)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                width: size * 0.36,
                height: size * 0.36,
                decoration: BoxDecoration(
                  color: Palette.brand(context),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: Icon(Icons.check, size: size * 0.2, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

TypeBadge _fallbackBadge(PocketType t) =>
    TypeBadge(tint: _kindColorOf(t.kind), emoji: t.glyph);

/// 顶栏的圆形按钮：返回（白底细边）/ 保存（品牌色实心）。
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    this.onTap,
    this.filled = false,
    this.busy = false,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final bg = filled ? Palette.brand(context) : Palette.card(context);
    final fg = filled ? Colors.white : Palette.ink(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 36,
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: filled ? null : Border.all(color: Palette.hairline(context)),
        ),
        child: busy
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: fg),
              )
            : Icon(icon, size: 22, color: fg),
      ),
    );
  }
}

Color _kindColorOf(PocketKind k) => switch (k) {
      PocketKind.cash => const Color(0xFF6E7671),
      PocketKind.bank => const Color(0xFF3E7BB6),
      PocketKind.credit => const Color(0xFF4A4F6B),
      PocketKind.debt => Palette.expense,
    };
