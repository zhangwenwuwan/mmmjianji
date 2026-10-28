import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/currency.dart';
import '../core/rules.dart';
import '../data/store.dart';
import '../services/attachment_service.dart';
import '../services/app_log.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'account_edit_page.dart';
import 'attachment_viewer_page.dart';
import 'bucket_manage_page.dart';
import 'amount_keypad.dart';
import 'common.dart';
import 'loans_page.dart' show showDebtEditor;
import 'motion.dart';
import 'theme.dart';
import 'wheel_date_picker.dart';

/// 记一笔（**一屏流程**，对齐一木记账）：
///
/// 1. 顶部 TabBar：支出 / 收入 / 转账 / 债务，右上「取消」；
/// 2. 主体上方是**全屏分类选择**（4 列网格 + 底部分类管理入口）；
/// 3. 主体下方**常驻金额面板**：金额 · 备注 · 日期/标签/报销/情绪/账户/更多 · 数字键盘 · 保存/再记一笔；
/// 4. 点分类只是**选中**（底部金额区跟着变），不再弹第二层面板 —— 旧版每次记账多一层；
/// 5. 保存成功 → 中央弹一枚对勾，再关闭。
///
/// 转账和「编辑已有流水」仍走 `_openSheet` 的金额面板：转账要填转入方/手续费/折扣/到账金额，
/// 编辑要能改全字段，塞进一屏面板会把面板撑爆。
/// 「债务」tab 也是异类：它不生成流水，而是记一条待收/待还（独立的 debts 表），
/// 所以点了之后弹的是借贷表单，不是金额面板。
class EntryEditorPage extends ConsumerStatefulWidget {
  const EntryEditorPage({super.key, this.existing});

  final Entry? existing;

  @override
  ConsumerState<EntryEditorPage> createState() => _EntryEditorPageState();
}

class _EntryEditorPageState extends ConsumerState<EntryEditorPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(
    length: 4,
    vsync: this,
    initialIndex: switch (widget.existing?.flow) {
      'in' => 1,
      'transfer' => 2,
      _ => 0,
    },
  );

  /// 当前所在的 tab。
  ///
  /// 不能只靠 `_flow` 判断：债务 tab 不对应任何 flow，
  /// 停在债务 tab 时 `_flow` 还是上一个 tab 的值，
  /// 光看 `_flow` 会把底部金额面板继续画出来（面板盖在债务页上）。
  late int _tabIndex = switch (widget.existing?.flow) {
    'in' => 1,
    'transfer' => 2,
    _ => 0,
  };

  bool get _isEdit => widget.existing != null;

  // ------------------------------------------------------------ 一屏记账草稿
  // 对齐一木记账：点分类只是「选中」，金额 + 键盘 + 保存在同屏底部，
  // 不再弹第二层面板（旧流程每次记账多一次交互）。
  /// 当前草稿流向（跟随 tab）。转账不走这条路。
  String _flow = 'out';
  int? _bucketId;
  String? _bucketTitle;
  String? _bucketGlyph;

  String _amount = '';
  String _tags = '';
  DateTime _day = DateTime.now();
  int? _pocketId;
  int _reimburse = 0;
  int _mood = 0;
  bool _saving = false;

  /// 不计入收支（内部调账、代付等）/ 不计入预算
  bool _excludeStats = false;
  bool _excludeBudget = false;

  /// 本笔币种；null = 跟随账户
  String? _currency;

  /// 退款关联的原始支出 id
  int? _refundOfId;

  /// 四则运算：已确认的累加值（分）与当前运算符
  int _acc = 0;
  String? _op;

  /// 优惠 / 折扣（分）。一木的支出表单也有这一项：
  /// 金额记的是**实付**，优惠只作附加记录（详情页能看到「省了多少」），
  /// 不动 amountCents，所以统计口径不会变。
  int _discountCents = 0;

  /// 本次新增的凭证（已落到应用目录，保存时才挂到 entry 上）
  final List<String> _newAttachments = <String>[];

  /// ⚠️ 备注只有 _memoCtrl 一个真源。曾经还有个 _memo 影子变量，
  /// 弹窗写一次、输入框写一次，两条路径互相覆盖，顺序一换就丢字。
  late final TextEditingController _memoCtrl;

  @override
  void initState() {
    super.initState();
    _memoCtrl = TextEditingController();
    _tab.addListener(_onTabChanged);
    // 编辑模式：分类已定，进入页面就直接弹金额面板
    if (_isEdit) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final e = widget.existing!;
        Bucket? bucket;
        if (e.flow != 'transfer') {
          final buckets = await ref
              .read(bucketsProvider(e.flow).future)
              .catchError((_) => <Bucket>[]);
          for (final b in buckets) {
            if (b.id == e.bucketId) bucket = b;
          }
        }
        if (!mounted) return;
        await _openSheet(e.flow, bucket: bucket, editing: e);
      });
    }
  }

  /// 优惠 / 折扣：走 App 自己的金额键盘（和转账那份共用 editFeeOrDiscount）
  Future<void> _editFeeOrDiscount({required bool isFee}) async {
    final v = await editFeeOrDiscount(
      context,
      isFee: isFee,
      currentCents: isFee ? 0 : _discountCents,
    );
    if (v == null || !mounted) return;
    setState(() => _discountCents = v);
  }

  /// 切 tab = 换一套分类，旧选择必须作废（否则底部金额区还挂着上一个流向的分类）
  void _onTabChanged() {
    if (!mounted) return;
    final idx = _tab.index;
    // 债务 tab 不属于「支出 / 收入 / 转账」三选一：
    // 保持 _flow 不动（回到支出 tab 时还认得上次选的分类），只记住 tab 位置。
    if (idx == 3) {
      setState(() => _tabIndex = 3);
      return;
    }
    final flow = switch (idx) { 1 => 'in', 2 => 'transfer', _ => 'out' };
    if (flow == _flow && _tabIndex == idx) return;
    setState(() {
      _tabIndex = idx;
      _flow = flow;
      _bucketId = null;
      _bucketTitle = null;
      _bucketGlyph = null;
    });
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    _memoCtrl.dispose();
    super.dispose();
  }

  Future<void> _openSheet(String flow, {Bucket? bucket, Entry? editing}) async {
    final result = await showAppSheet<EditorSheetResult>(
      context: context,
      scrollable: false,
      // 记一笔的面板是自己管滚动的：金额 + 键盘 + 保存常驻，中间表单区可滚。
      // 不撑满高度的话，小屏上整列内容会直接溢出（黄黑条）。
      fillsHeight: true,
      title: flow == 'transfer'
          ? '转账'
          : (editing != null ? '修改记录' : (bucket?.title ?? '记一笔')),
      builder: (ctx) => _AmountSheet(
        flow: flow,
        bucket: bucket,
        existing: editing,
      ),
    );
    if (!mounted) return;
    if (result == null || !result.saved) return; // 用户取消
    // 保存成功：先给对勾，再退出编辑器
    await showSaveSuccessCheck(context);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// 「债务」tab：记一条待收 / 待还。
  ///
  /// 它不产生流水 —— 借出去的钱还没回来，不该出现在收支里。
  /// 所以这里直接打开借贷表单，保存后回到首页（和转账一致的收尾方式）。
  Future<void> _openDebt() async {
    final saved = await showDebtEditor(context, ref, null);
    if (!mounted || !saved) return;
    await showSaveSuccessCheck(context);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  /// 选中一个分类：只改草稿，不弹面板（一屏流程的关键）。
  void _selectBucket(String flow, Bucket b) {
    // 收起系统键盘：用户点了分类通常马上要按数字键，
    // 留着焦点会让系统键盘盖住我们自己的键盘。
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _flow = flow;
      _bucketId = b.id;
      _bucketTitle = b.title;
      _bucketGlyph = b.glyph;
    });
  }

  /// 「更多」弹层里已设了几项。
  ///
  /// ⚠️ 这个 App 有**两套字段 chip 行**：本类的一屏面板（新建记账走这里）
  /// 和 [_AmountSheet]（修改已有流水 / 转账走那里）。两边都要显示这个计数，
  /// 只改一处会出现"新建记账看不到、改一笔又看到了"的鬼故事。
  int get _moreSetCount => [
        _currency != null,
        _excludeStats,
        _excludeBudget,
        _newAttachments.isNotEmpty,
        _refundOfId != null,
      ].where((v) => v).length;

  /// 一屏记账面板：金额 + 备注 + 常用字段 + 键盘 + 保存。
  ///
  /// 高度预算是按 1080×2340 实机算的：面板约 430dp，上面至少还剩 390dp
  /// 给分类网格（约 4 行 16 个分类，超出可滚）。
  Widget _draftPanel() {
    final bucketsAsync = ref.watch(bucketsProvider(_flow));
    final buckets = bucketsAsync.valueOrNull ?? const <Bucket>[];
    // 默认选中当前流向的第一个一级分类：一木也是这样，用户进来直接输金额。
    // 不预选等于每次记账都多一次「点分类」。
    if (!_isEdit &&
        _tabIndex != 2 &&
        _tabIndex != 3 &&
        _bucketId == null &&
        buckets.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _bucketId != null) return;
        final tops = buckets.where((b) => b.isTop).toList();
        final pick = tops.isNotEmpty ? tops.first : buckets.first;
        setState(() {
          _bucketId = pick.id;
          _bucketTitle = pick.title;
          _bucketGlyph = pick.glyph;
        });
      });
    }
    // 转账（tab 2）和债务（tab 3）没有金额草稿：转账走自己的表单，
    // 债务根本不是流水。停在它们上面时把面板收起来，否则会浮在半空。
    if (_isEdit || _tabIndex == 2 || _tabIndex == 3 || _bucketId == null) {
      return const SizedBox.shrink();
    }

    final settings = ref.watch(settingsProvider);
    final currentBookId = ref.watch(activeBookProvider).valueOrNull?.id;
    // 转账的转入/转出方都用「可用账户」：归档账户不该再被选为新流水的目标；
    // 「记账可被选择」关掉、或「选择生效账本」不命中当前账本的，也隐藏。
    final pockets = (ref.watch(pocketsProvider).valueOrNull ?? const <Pocket>[])
        .where((p) => !p.archived)
        .where((p) => p.recordable)
        .where((p) => pocketVisibleInBook(p, currentBookId))
        .toList();
    // 账户是跨账本共享的：非本账本创建的账户要标出归属，
    // 否则用户在账本 A 里看到一个陌生账户，完全不知道它是谁的。
    final books = ref.watch(booksProvider).valueOrNull ?? const <Book>[];
    final bookTitleOf = {for (final b in books) b.id: b.title};
    String ownerLabel(Pocket p) {
      if (currentBookId == null || p.bookId == currentBookId) return '';
      return '（${bookTitleOf[p.bookId] ?? '其它账本'}）';
    }

    if (_pocketId == null && pockets.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _pocketId != null) return;
        var pick = pockets.first;
        // ① 优先用「设置 → 默认账户」。必须校验它还在：账户可能已被归档删除，
        //    直接用会选中一个不存在的 id，保存时报「请选择账户」还找不到原因。
        final preferred = ref.read(settingsProvider).defaultPocketId;
        Pocket? byDefault;
        if (preferred > 0) {
          for (final p in pockets) {
            if (p.id == preferred) {
              byDefault = p;
              break;
            }
          }
        }
        // ② 没设默认账户：显式选了币种就按币种匹配 ③ 再不行取第一个
        final cur = _currency;
        if (byDefault != null) {
          pick = byDefault;
        } else if (cur != null) {
          for (final p in pockets) {
            if (p.currency == cur) {
              pick = p;
              break;
            }
          }
        }
        setState(() => _pocketId = pick.id);
      });
    }
    final fromCur =
        pockets.where((p) => p.id == _pocketId).firstOrNull?.currency ?? 'CNY';
    final color = _flow == 'in' ? Palette.income : Palette.expense;
    final picked = pockets.where((p) => p.id == _pocketId).firstOrNull;

    return Container(
      decoration: BoxDecoration(
        color: Palette.card(context),
        border: Border(top: BorderSide(color: Palette.hairline(context))),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 金额行：左 = 当前分类，右 = 大数字（有运算符时上方显示累加过程）
          if (_op != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(centsToText(_acc),
                    style: TextStyle(
                        fontSize: 13, color: Palette.inkFaint(context))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(_op!,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: color)),
                ),
                Text(
                  _amount.isEmpty ? '…' : _amount,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Palette.inkSoft(context)),
                ),
              ],
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 当前分类（点它不能改分类——网格就在上面，这里只做状态展示）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppGlyph(_bucketGlyph ?? '', size: 13),
                    const SizedBox(width: 4),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 76),
                      child: Text(
                        _bucketTitle ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: color),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Text(_currency == null ? settings.symbol : symbolOf(_currency!),
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: color.withValues(alpha: 0.75))),
              const SizedBox(width: 5),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    _op != null
                        ? centsToText(_resultCents)
                        : (_amount.isEmpty ? '0.00' : _amount),
                    // 给键盘测试用：金额是这个页面的主状态，必须能被钉住
                    key: const Key('amount-display'),
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: (_op == null && _amount.isEmpty)
                          ? Palette.inkFaint(context)
                          : color,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 备注：常驻一行。放到 chip 里点开对话框会多一次交互，
          // 而备注是记账时第二常填的字段。
          TextField(
            controller: _memoCtrl,
            maxLength: 60,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              hintText: '备注（这笔钱花在哪了）',
              counterText: '',
              isDense: true,
              filled: true,
              fillColor: Palette.paper(context),
              prefixIcon: PressScale(
                scale: 0.9,
                onTap: _pickFrequentMemo,
                child: Icon(Icons.history,
                    size: 18, color: Palette.inkSoft(context)),
              ),
              prefixIconConstraints:
                  const BoxConstraints(minWidth: 40, minHeight: 20),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 8),
          // 常用字段：横向滚动，屏幕再窄也不会挤爆
          SizedBox(
            height: 32,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _FieldChip(
                    icon: Icons.event_outlined,
                    label: dayKey(_day),
                    onTap: _pickDay),
                const SizedBox(width: 6),
                // 账户紧跟日期：这是「记到哪个账户」，直接影响账对不对。
                // 之前排在第 6 位，393dp 窄屏首屏根本看不到，得横滑才知道记哪了。
                _FieldChip(
                    icon: Icons.account_balance_wallet_outlined,
                    label: picked == null ? '账户' : picked.displayName,
                    onTap: () => _pickPocketForDraft(pockets, ownerLabel)),
                const SizedBox(width: 6),
                _FieldChip(
                    icon: Icons.edit_note,
                    label: _tags.isEmpty ? '标签' : _tags,
                    active: _tags.isNotEmpty,
                    onTap: _editNote),
                const SizedBox(width: 6),
                if (_flow == 'out') ...[
                  _FieldChip(
                      icon: Icons.request_quote_outlined,
                      label: _reimburse == 1 ? '待报销' : '报销',
                      active: _reimburse == 1,
                      onTap: () =>
                          setState(() => _reimburse = _reimburse == 1 ? 0 : 1)),
                  const SizedBox(width: 6),
                ],
                _FieldChip(
                    icon: Icons.local_offer_outlined,
                    label: _discountCents > 0
                        ? '省 ${centsToText(_discountCents)}'
                        : '优惠',
                    active: _discountCents > 0,
                    onTap: () => _editFeeOrDiscount(isFee: false)),
                const SizedBox(width: 6),
                _FieldChip(
                    icon: Icons.mood_outlined,
                    label: switch (_mood) {
                      1 => '😊 值',
                      2 => '😐 一般',
                      3 => '😣 后悔',
                      _ => '情绪',
                    },
                    active: _mood != 0,
                    onTap: _pickMood),
                const SizedBox(width: 6),
                // 「不计入收支」开了就露在主行：它藏在弹层里时，
                // 用户保存完看不出自己开过，回头就问"这笔怎么没进统计"。
                if (_excludeStats) ...[
                  _FieldChip(
                      icon: Icons.visibility_off_outlined,
                      label: '不计收支',
                      active: true,
                      onTap: () => setState(() => _excludeStats = false)),
                  const SizedBox(width: 6),
                ],
                _FieldChip(
                    icon: Icons.more_horiz,
                    // 已设几项就写在 chip 上，别让「不计预算/币种/凭证」隐形
                    label: _moreSetCount > 0 ? '更多 · $_moreSetCount' : '更多',
                    active: _moreSetCount > 0,
                    onTap: () => _moreOptions(fromCur)),
              ],
            ),
          ),
          // 凭证缩略图（有才占位）
          if (_newAttachments.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 54,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final path in _newAttachments)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: AttachmentThumb(
                        path: path,
                        onTap: () => Navigator.of(context).push(AppPageRoute(
                          page: AttachmentViewerPage(paths: [path]),
                        )),
                        onRemove: () => _removeNewAttachment(path),
                      ),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          AmountKeypad(onKey: _press),
          const SizedBox(height: 8),
          // 底部：清空 / 再记一笔 / 保存
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => _press('clear'),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('清空', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 46,
                  child: OutlinedButton(
                    onPressed:
                        _saving ? null : () => _saveDraft(continueAdding: true),
                    style: OutlinedButton.styleFrom(
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('再记一笔', style: TextStyle(fontSize: 13)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 46,
                  child: MorphButton(
                    saving: _saving,
                    onPressed: _saving ? null : () => _saveDraft(),
                    label: '保存',
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 草稿运算/保存

  /// 当前数字段的金额（分）
  int get _curCents => parseAmountToCents(_amount) ?? 0;

  /// 运算符优先级：先把 × ÷ 并进累加值，再处理 + -
  ///
  /// 走 [applyAmountOp] 单一实现：乘除要在「元」域换算，
  /// 直接拿两个「分」相乘会把 17×2 算成 3400 元。
  int _apply(int acc, String op, int v) => applyAmountOp(acc, op, v);

  /// 表达式最终结果（分）。有运算符时**实时**显示，所以键盘上不需要 `=` 键。
  ///
  /// ⚠️ 刚按完运算符、下一个数还没输入时，返回**累加值本身**：
  /// 否则会显示「17 × 0 = 0」，用户以为金额被清空了。
  /// （真计算器都是这么处理的——按下 × 之后屏幕上还是 17。）
  int get _resultCents {
    if (_op == null) return _curCents;
    if (_amount.isEmpty) return _acc;
    return _apply(_acc, _op!, _curCents);
  }

  void _press(String key) {
    // 收键盘：点了数字键还留着备注焦点，系统键盘会盖住我们自己的键盘
    FocusManager.instance.primaryFocus?.unfocus();
    if (const ['+', '-', '×', '÷'].contains(key)) {
      setState(() {
        final cur = _curCents;
        _acc = _op == null ? cur : _apply(_acc, _op!, cur);
        _op = key;
        _amount = '';
      });
      return;
    }
    setState(() {
      if (key == 'del') {
        if (_amount.isNotEmpty) {
          _amount = _amount.substring(0, _amount.length - 1);
        }
        return;
      }
      if (key == 'clear') {
        _amount = '';
        _acc = 0;
        _op = null;
        return;
      }
      if (!RegExp(r'^[\d.]$').hasMatch(key)) return;
      final next = _amount + key;
      if (!RegExp(r'^\d{0,7}(\.\d{0,2})?$').hasMatch(next)) return;
      _amount = next;
    });
  }

  Future<void> _saveDraft({bool continueAdding = false}) async {
    if (_saving) return;
    if (_resultCents <= 0) {
      HapticFeedback.mediumImpact();
      _toast('请输入金额');
      return;
    }
    final pocketId = _pocketId;
    if (pocketId == null) {
      // 一个账户都没有（新装、或全归档了）时只说「请选择账户」是死路：
      // 用户根本无处可选。直接把人带去新建账户页，建完回来接着记。
      final all = ref.read(pocketsProvider).valueOrNull ?? const <Pocket>[];
      final usable = all.where((p) => !p.archived).toList();
      if (usable.isEmpty) {
        await Navigator.of(context)
            .push(AppPageRoute(page: const AccountEditPage()));
        if (mounted) bumpRevision(ref);
        return;
      }
      _toast('请选择账户');
      return;
    }
    // 最后一道防线：本笔币种必须和账户币种一致（转账除外）。
    // 界面上已经把候选账户过滤成同币种了，但"选了外币、又没有该币种账户"
    // 时 _pocketId 还指着旧账户 —— 这里拦住，别落一笔错账。
    if (_flow != 'transfer' && _currency != null) {
      final accounts =
          ref.read(pocketsProvider).valueOrNull ?? const <Pocket>[];
      final p = accounts.where((x) => x.id == pocketId).firstOrNull;
      if (p != null && p.currency != _currency) {
        HapticFeedback.mediumImpact();
        _toast('这一笔是 $_currency，账户却是 ${p.currency}。'
            '换一个 $_currency 账户，或把币种改回「跟随账户」');
        return;
      }
    }
    final tags = _tags
        .split(RegExp(r'[,，]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .join(',');

    setState(() => _saving = true);
    try {
      final store = await ref.read(storeProvider.future);
      final book = await ref.read(activeBookProvider.future);
      final entryId = await store.addEntry(
        bookId: book.id,
        pocketId: pocketId,
        toPocketId: null,
        bucketId: _bucketId,
        flow: _flow,
        amountCents: _resultCents,
        memo: _memoCtrl.text.trim(),
        day: _day,
        tags: tags,
        reimburse: _flow == 'in' ? 0 : _reimburse,
        mood: _flow == 'in' ? 0 : _mood,
        feeCents: 0,
        discountCents: _discountCents,
        excludeFromStats: _excludeStats,
        excludeFromBudget: _excludeBudget,
        currency: _currency,
        toAmountCents: null,
        refundOfId: _flow == 'in' ? _refundOfId : null,
      );
      // 把这次新加的凭证挂到这笔流水上
      for (final path in _newAttachments) {
        await store.addAttachment(
            bookId: book.id, entryId: entryId, path: path);
      }
      _newAttachments.clear();
      bumpRevision(ref);
      if (!mounted) return;
      HapticFeedback.lightImpact();
      SystemSound.play(SystemSoundType.click);
      if (continueAdding) {
        // 继续记下一笔：清掉金额/备注/标签/表达式，**保留分类和账户**
        // （连记三笔咖啡是常见操作，每次重选分类会很烦）
        setState(() {
          _saving = false;
          _amount = '';
          _memoCtrl.clear();
          _tags = '';
          _acc = 0;
          _op = null;
          _refundOfId = null;
        });
      } else {
        await showSaveSuccessCheck(context);
        if (!mounted) return;
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppLog.error('editor', '保存流水失败', e);
      _toast('保存失败，详情见「我的 → 数据管理 → 日志中心」');
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).toast(text);
  }

  Future<void> _pickDay() async {
    final picked = await pickDateWheel(
      context,
      _day,
      includeDay: true,
      title: '选择日期',
    );
    if (picked != null && mounted) setState(() => _day = picked);
  }

  Future<void> _pickMood() async {
    final picked = await showAppSheet<int>(
      context: context,
      title: '这笔花得值吗？',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in const [
            (1, '😊 值'),
            (2, '😐 一般'),
            (3, '😣 后悔'),
            (0, '不标')
          ])
            ListTile(
              dense: true,
              title: Text(m.$2),
              trailing: _mood == m.$1 ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, m.$1),
            ),
        ],
      ),
    );
    if (picked != null && mounted) setState(() => _mood = picked);
  }

  Future<void> _editNote() async {
    final memoCtrl = TextEditingController(text: _memoCtrl.text);
    final tagCtrl = TextEditingController(text: _tags);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备注与标签'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(
              label: '备注',
              controller: memoCtrl,
              hint: '这笔钱花在哪了',
              autofocus: true,
              maxLength: 60,
            ),
            const SizedBox(height: 14),
            AppTextField(
              label: '标签',
              controller: tagCtrl,
              hint: '逗号分隔，如：聚餐,报销',
              maxLength: 40,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() {
        _tags = tagCtrl.text;
        // 弹窗里的文本回写到常驻控制器（唯一真源）
        _memoCtrl.text = memoCtrl.text;
      });
    }
  }

  /// 常用备注（备注历史）：点备注框左侧时钟图标弹出
  Future<void> _pickFrequentMemo() async {
    final memos =
        ref.read(frequentMemosProvider).valueOrNull ?? const <String>[];
    if (memos.isEmpty) {
      _toast('还没有历史备注，记几笔之后就有了');
      return;
    }
    final picked = await showAppSheet<String>(
      context: context,
      title: '常用备注',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in memos)
            ListTile(
              dense: true,
              leading:
                  Icon(Icons.history, size: 18, color: Palette.inkFaint(ctx)),
              title: Text(m, style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, m),
            ),
        ],
      ),
    );
    if (picked != null && mounted) {
      setState(() {
        _memoCtrl.text = picked;
        _memoCtrl.selection =
            TextSelection.fromPosition(TextPosition(offset: picked.length));
      });
    }
  }

  /// 本笔币种（null = 跟随账户）
  Future<void> _pickCurrency(String pocketCurrency) async {
    final picked = await showAppSheet<String>(
      context: context,
      title: '这一笔的币种',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            title: Text('跟随账户（$pocketCurrency）'),
            trailing: _currency == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, '__follow__'),
          ),
          const Divider(height: 1),
          for (final e in kCurrencies.entries)
            ListTile(
              dense: true,
              title: Text('${e.key}  ${e.value}'),
              trailing: _currency == e.key ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, e.key),
            ),
        ],
      ),
    );
    if (!mounted) return;
    final cur = picked == '__follow__' ? null : picked;
    setState(() => _currency = cur);
    if (cur == null) return;

    // 换成外币之后，当前账户必须跟着换：留着 CNY 账户就是一笔错账。
    final list = ref.read(pocketsProvider).valueOrNull ?? const <Pocket>[];
    final now = list.where((p) => p.id == _pocketId).firstOrNull;
    if (now != null && now.currency == cur) return;
    final same = [
      for (final p in list)
        if (p.recordable && p.currency == cur) p,
    ];
    if (same.isNotEmpty) {
      setState(() => _pocketId = same.first.id);
    } else if (mounted) {
      ScaffoldMessenger.of(context).toast('还没有 $cur 账户，点账户可以新建一个');
    }
  }

  /// 账户选择（一屏面板里只显示一个 chip，具体选哪个摊开成列表）
  ///
  /// ⚠️ 显式选了外币时，只能选**同币种**账户。
  /// 否则一笔 USD 会被记进 CNY 账户，而余额是直接累加 amount_cents 的
  /// （不折算），统计页却按汇率折算 —— 同一笔钱在首页和资产页是两个数。
  /// 转账不动：跨币种转账有 to_amount_cents，是设计内的。
  Future<void> _pickPocketForDraft(
      List<Pocket> pockets, String Function(Pocket) ownerLabel) async {
    final wanted = _flow == 'transfer' ? null : _currency;
    final scoped = wanted == null
        ? pockets
        : [
            for (final p in pockets)
              if (p.currency == wanted) p,
          ];

    // 一个账户都没有（新装 App 的初始状态）：别弹「还没有可用账户」就完事，
    // 直接把人带去新建账户页 —— 他要记一笔，缺的正是账户。
    if (scoped.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).toast(wanted == null
              ? '还没有可用账户，先建一个'
              : '还没有 $wanted 账户，先建一个再记这一笔');
      }
      // AppPageRoute 的泛型是 dynamic，直接 push，结果按 dynamic 收
      final created = await Navigator.of(context)
          .push(AppPageRoute(page: const AccountEditPage()));
      if (created == true && mounted) {
        bumpRevision(ref);
        // 建完账户：pocketsProvider 会重读，本页的 _pocketId 由
        // didChangeDependencies 里的默认账户逻辑自动补上。
        setState(() {});
      }
      return;
    }
    final picked = await showAppSheet<int>(
      context: context,
      title: _flow == 'in'
          ? '收入到账${wanted == null ? '' : '（$wanted）'}'
          : '支出账户${wanted == null ? '' : '（$wanted）'}',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final p in scoped)
            ListTile(
              dense: true,
              leading: AppGlyph(p.glyph, size: 18),
              title: Text('${p.displayName}${ownerLabel(p)}'),
              subtitle: Text(
                switch (p.kind) {
                  PocketKind.cash => '现金 · ${p.currency}',
                  PocketKind.bank => '银行卡 · ${p.currency}',
                  PocketKind.credit => '信用卡 · ${p.currency}',
                  PocketKind.debt => '负债 · ${p.currency}',
                },
                style: TextStyle(fontSize: 12),
              ),
              trailing:
                  p.id == _pocketId ? const Icon(Icons.check, size: 18) : null,
              onTap: () => Navigator.pop(ctx, p.id),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _pocketId = picked);
  }

  /// 更多选项：币种 / 不计入收支 / 不计入预算 / 退款关联 / 凭证。
  /// 这些都是「偶尔才用一次」的，摊在主面板上会把高频字段淹掉。
  Future<void> _moreOptions(String fromCur) async {
    await showAppSheet<void>(
      context: context,
      title: '更多选项',
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.currency_exchange, size: 18),
              title: Text(
                  _currency == null ? '币种：跟随账户（$fromCur）' : '币种：$_currency'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () async {
                await _pickCurrency(fromCur);
                if (ctx.mounted) setSheet(() {});
              },
            ),
            const Divider(height: 1),
            SwitchListTile(
              dense: true,
              secondary: const Icon(Icons.visibility_off_outlined, size: 18),
              title: const Text('不计入收支'),
              subtitle: const Text('内部调账、代付等'),
              value: _excludeStats,
              onChanged: (v) {
                setState(() => _excludeStats = v);
                if (ctx.mounted) setSheet(() {});
              },
            ),
            SwitchListTile(
              dense: true,
              secondary: const Icon(Icons.pie_chart_outline, size: 18),
              title: const Text('不计入预算'),
              subtitle: const Text('这笔支出不计入预算完成率'),
              value: _excludeBudget,
              onChanged: (v) {
                setState(() => _excludeBudget = v);
                if (ctx.mounted) setSheet(() {});
              },
            ),
            if (_flow == 'in')
              ListTile(
                dense: true,
                leading: const Icon(Icons.undo, size: 18),
                title: Text(_refundOfId == null ? '退款关联' : '已关联原支出'),
                subtitle: _refundOfId == null ? const Text('') : null,
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () async {
                  await _pickRefundSource();
                  if (ctx.mounted) setSheet(() {});
                },
              ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: const Icon(Icons.photo_camera_outlined, size: 18),
              title: Text('凭证（${_newAttachments.length}）'),
              subtitle: const Text('拍照或从相册选，保存时挂到这笔账上'),
              onTap: () async {
                await _addAttachment();
                if (ctx.mounted) setSheet(() {});
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 退款关联：从最近的支出里挑一条原记录
  Future<void> _pickRefundSource() async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final recent = await store.entriesRecent(book.id, days: 180);
    final candidates = recent.where((e) => e.flow == 'out').toList();
    if (!mounted) return;
    if (candidates.isEmpty) {
      _toast('最近半年没有可关联的支出');
      return;
    }
    final picked = await showAppSheet<int>(
      context: context,
      title: '这笔退款对应哪条支出？',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.link_off, size: 18),
            title: const Text('不关联'),
            trailing: _refundOfId == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, -1),
          ),
          const Divider(height: 1),
          for (final e in candidates.take(50))
            ListTile(
              dense: true,
              leading: Text(
                e.memo.isEmpty ? '💸' : '💸',
                style: const TextStyle(fontSize: 17),
              ),
              title: Text(
                e.memo.isEmpty ? '（无备注）' : e.memo,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle:
                  Text('${dayKey(e.day)} · ${centsToText(e.amountCents)}'),
              trailing: _refundOfId == e.id ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, e.id),
            ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _refundOfId = picked == -1 ? null : picked);
  }

  Future<void> _addAttachment() async {
    final book = await ref.read(activeBookProvider.future);
    if (!mounted) return;
    final source = await showAppSheet<String>(
      context: context,
      title: '添加凭证',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.photo_camera_outlined, size: 18),
            title: const Text('拍一张'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.photo_library_outlined, size: 18),
            title: const Text('从相册选'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
        ],
      ),
    );
    if (source == null) return;
    final path = source == 'camera'
        ? await AttachmentService.pickFromCamera(book.id)
        : await AttachmentService.pickFromGallery(book.id);
    if (path == null) {
      if (mounted) _toast('没有选中图片');
      return;
    }
    if (!mounted) return;
    setState(() => _newAttachments.add(path));
  }

  Future<void> _removeNewAttachment(String path) async {
    setState(() => _newAttachments.remove(path));
    await AttachmentService.deleteFile(path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          // 顶部：三个分类 tab + 取消（原版没有「保存」按钮，保存发生在底部金额区）
          SafeArea(
            bottom: false,
            child: SizedBox(
              height: 46,
              child: Row(
                children: [
                  Expanded(
                    child: TabBar(
                      controller: _tab,
                      labelColor: Palette.ink(context),
                      unselectedLabelColor: Palette.inkFaint(context),
                      labelStyle: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w700),
                      unselectedLabelStyle: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500),
                      indicator: UnderlineTabIndicator(
                        borderSide:
                            BorderSide(width: 2, color: Palette.brand(context)),
                        insets: EdgeInsets.zero,
                      ),
                      tabs: const [
                        Tab(text: '支出'),
                        Tab(text: '收入'),
                        Tab(text: '转账'),
                        Tab(text: '债务'),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: [
                _CategoryGrid(
                  kind: 'out',
                  selectedId: _flow == 'out' ? _bucketId : null,
                  onPick: (b) => _selectBucket('out', b),
                ),
                _CategoryGrid(
                  kind: 'in',
                  selectedId: _flow == 'in' ? _bucketId : null,
                  onPick: (b) => _selectBucket('in', b),
                ),
                _TransferEntry(onStart: () => _openSheet('transfer')),
                _DebtEntry(onStart: _openDebt),
              ],
            ),
          ),
          // 一屏金额面板（转账/编辑时隐藏，它们走 _openSheet）
          _draftPanel(),
        ],
      ),
    );
  }
}

/// 「选择生效账本」过滤：账户勾选了生效账本时，仅当当前账本命中才显示。
/// 未勾选（空）或当前账本未知时一律放行。
bool pocketVisibleInBook(Pocket p, int? currentBookId) {
  final vb = p.visibleBookIds.trim();
  if (vb.isEmpty || currentBookId == null) return true;
  return vb
      .split(',')
      .map((s) => int.tryParse(s.trim()) ?? -1)
      .contains(currentBookId);
}

/// 保存结果（跨文件：ledger_page 用它处理删除撤销）
class EditorSheetResult {
  const EditorSheetResult({required this.saved, this.deletedId});

  final bool saved;

  /// 删除流水后返回其 id，调用方据此提供「撤销」入口。
  final int? deletedId;
}

/// 全屏分类选择：一级分类 4 列网格；点有子分类的父分类 → 下方展开子分类行
/// （对齐原版 CategorySelector 的折叠/展开），底部有分类管理入口。
class _CategoryGrid extends ConsumerStatefulWidget {
  const _CategoryGrid(
      {required this.kind, required this.onPick, this.selectedId});

  final String kind;
  final ValueChanged<Bucket> onPick;

  /// 当前草签选中的分类 id（高亮用）
  final int? selectedId;

  @override
  ConsumerState<_CategoryGrid> createState() => _CategoryGridState();
}

class _CategoryGridState extends ConsumerState<_CategoryGrid> {
  /// 当前展开的父分类 id
  int? _expanded;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(bucketsProvider(widget.kind));
    return async.when(
      skipLoadingOnReload: true,
      loading: () => GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.35,
        ),
        itemCount: 12,
        itemBuilder: (_, __) => const Skeleton(radius: 14),
      ),
      error: (e, _) => ErrorRetryView(
        message: '分类读取失败',
        detail: '$e',
        onRetry: () async => ref.invalidate(bucketsProvider(widget.kind)),
      ),
      data: (all) {
        final tops = all.where((b) => b.isTop).toList();
        final childrenOf = <int, List<Bucket>>{};
        for (final b in all.where((b) => !b.isTop)) {
          childrenOf.putIfAbsent(b.parentId!, () => []).add(b);
        }
        final expandedChildren = _expanded == null
            ? const <Bucket>[]
            : (childrenOf[_expanded] ?? const []);
        // 展开面板里也要能选父分类本身：只想记「餐饮」不想细分到「外卖」的人
        // 是存在的。之前一展开就只能选子分类，等于把父分类记不了了。
        final expandedParent = tops.where((t) => t.id == _expanded).firstOrNull;

        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
          children: [
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.35,
              ),
              itemCount: tops.length,
              itemBuilder: (_, i) {
                final b = tops[i];
                final hasChildren = (childrenOf[b.id] ?? const []).isNotEmpty;
                return _BucketTile(
                  bucket: b,
                  hasChildren: hasChildren,
                  expanded: _expanded == b.id,
                  selected: b.id == widget.selectedId,
                  onTap: () {
                    if (hasChildren) {
                      // 有子分类：先展开，让用户选具体那个
                      setState(
                          () => _expanded = _expanded == b.id ? null : b.id);
                    } else {
                      widget.onPick(b);
                    }
                  },
                );
              },
            ),
            // 展开的子分类（原版就是在父分类下方插一块二级分类面板）
            if (expandedChildren.isNotEmpty) ...[
              const SizedBox(height: 12),
              Panel(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          // 用 nullable 查找，避免分类被删/归档后 firstWhere 抛异常
                          tops
                                  .where((t) => t.id == _expanded)
                                  .map((t) => t.title)
                                  .firstOrNull ??
                              '',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Palette.inkSoft(context)),
                        ),
                        const Spacer(),
                        PressScale(
                          scale: 0.9,
                          onTap: () => setState(() => _expanded = null),
                          child: Icon(Icons.close,
                              size: 16, color: Palette.inkFaint(context)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (expandedParent != null)
                          PressScale(
                            scale: 0.94,
                            onTap: () => widget.onPick(expandedParent),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                color: Palette.brand(context)
                                    .withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: Palette.brand(context)
                                        .withValues(alpha: 0.45)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AppGlyph(expandedParent.glyph, size: 13),
                                  const SizedBox(width: 5),
                                  Text('记到「${expandedParent.title}」',
                                      style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: Palette.brand(context))),
                                ],
                              ),
                            ),
                          ),
                        for (final c in expandedChildren)
                          PressScale(
                            scale: 0.94,
                            onTap: () => widget.onPick(c),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                color: c.id == widget.selectedId
                                    ? Palette.brand(context)
                                        .withValues(alpha: 0.12)
                                    : Palette.paper(context),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                    color: c.id == widget.selectedId
                                        ? Palette.brand(context)
                                        : Palette.hairline(context)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AppGlyph(c.glyph, size: 13),
                                  const SizedBox(width: 5),
                                  Text(c.title,
                                      style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: c.id == widget.selectedId
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                          color: c.id == widget.selectedId
                                              ? Palette.brand(context)
                                              : Palette.ink(context))),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 18),
            Center(
              child: PressScale(
                scale: 0.96,
                onTap: () => Navigator.of(context)
                    .push(AppPageRoute(page: const BucketManagePage())),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.settings_outlined,
                        size: 16, color: Palette.inkFaint(context)),
                    const SizedBox(width: 5),
                    Text('管理分类',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context))),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// 转账入口：原版转账是独立表单，这里先给一个明确的入口再弹面板。
class _TransferEntry extends StatelessWidget {
  const _TransferEntry({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.swap_horiz, size: 44, color: Palette.inkFaint(context)),
          const SizedBox(height: 12),
          Text('在账户之间转一笔',
              style: TextStyle(fontSize: 13, color: Palette.inkSoft(context))),
          const SizedBox(height: 16),
          PressScale(
            scale: 0.96,
            onTap: onStart,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Palette.brand(context).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Palette.brand(context)),
              ),
              child: Text('选择账户开始',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Palette.brand(context))),
            ),
          ),
        ],
      ),
    );
  }
}

/// 债务入口：借出去 / 借进来的钱都不属于收支，走独立的借贷表单。
class _DebtEntry extends StatelessWidget {
  const _DebtEntry({required this.onStart});

  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.handshake_outlined,
              size: 44, color: Palette.inkFaint(context)),
          const SizedBox(height: 12),
          Text('借出去的钱、要还的钱，都在这里记',
              style: TextStyle(fontSize: 13, color: Palette.inkSoft(context))),
          const SizedBox(height: 16),
          PressScale(
            scale: 0.96,
            onTap: onStart,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                color: Palette.brand(context).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: Palette.brand(context)),
              ),
              child: Text('记一笔借贷',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Palette.brand(context))),
            ),
          ),
        ],
      ),
    );
  }
}

/// 手续费 / 优惠金额编辑器：走 App 自己的键盘，不弹系统键盘。
///
/// 做成顶层函数是因为**两个 State 都要用**：一屏面板（支出/收入）
/// 和金额面板（转账/编辑已有流水）。抄两份的话，改一处必漏另一处。
/// 返回 null = 取消；允许 0（等于不填）。
Future<int?> editFeeOrDiscount(
  BuildContext context, {
  required bool isFee,
  required int currentCents,
}) =>
    showAmountKeypad(
      context,
      initialCents: currentCents,
      title: isFee ? '手续费' : '优惠 / 折扣',
      allowZero: true,
    );

/// 金额面板（复刻原版 AmountEditorSheet 的字段顺序）：
/// 金额 → 备注 → 账户（转账多一组「转入」）→ 日期/标签/报销/情绪 → 键盘 → 保存/再记一笔
class _AmountSheet extends ConsumerStatefulWidget {
  const _AmountSheet({
    required this.flow,
    this.bucket,
    this.existing,
  });

  final String flow;
  final Bucket? bucket;
  final Entry? existing;

  @override
  ConsumerState<_AmountSheet> createState() => _AmountSheetState();
}

class _AmountSheetState extends ConsumerState<_AmountSheet> {
  /// 当前输入的数字段
  late String _amount;
  // ⚠️ 备注只有 _memoCtrl 一个真源。曾经还有一个 _memo 影子变量，
  // 弹窗写一次、输入框写一次，两条路径互相覆盖，顺序一换就丢字。
  late String _tags;
  late DateTime _day;
  int? _pocketId;
  int? _toPocketId;
  late int _reimburse;
  late int _mood;
  bool _saving = false;

  // ---- 四则运算（对齐原版表达式模式）----
  /// 已确认的累加值（分）
  int _acc = 0;

  /// 当前运算符：+ - × ÷，null 表示没有在运算
  String? _op;

  /// 手续费 / 折扣（转账用，分）
  int _feeCents = 0;
  int _discountCents = 0;

  // ---- 不计入收支 / 预算、每笔币种、转账到账、退款关联 ----
  bool _excludeStats = false;
  bool _excludeBudget = false;

  /// 本笔币种；null = 跟随账户
  String? _currency;

  /// 转账到账金额（转入账户币种的分）；null = 同转出金额
  int? _toAmountCents;

  /// 退款关联的原始支出 id
  int? _refundOfId;

  /// 「更多」展开态：币种 / 不计入收支 / 不计入预算 / 凭证 / 退款关联。
  ///
  /// 这些属于「偶尔才用一次」，默认收起来——都摊开会让面板高到小屏放不下，
  /// 也把最常点的日期/标签/报销/情绪淹没了。
  bool _moreOpen = false;

  /// 本次新增的凭证（已落到应用目录，保存时才挂到 entry 上）
  final List<String> _newAttachments = <String>[];

  /// 编辑模式下已有的凭证
  List<({int id, String path, String name})> _savedAttachments = const [];

  /// 常驻控制器：如果每次 build 都新建一个，光标会跳、输入会丢字。
  late final TextEditingController _memoCtrl;

  bool get _isTransfer => widget.flow == 'transfer';
  bool get _isEdit => widget.existing != null;

  /// 「更多」展开层里已设了几项（显示在 chip 上，别让设置隐形）。
  int get _moreSetCount => [
        _currency != null,
        _excludeStats,
        _excludeBudget,
        _savedAttachments.isNotEmpty || _newAttachments.isNotEmpty,
        _refundOfId != null,
      ].where((v) => v).length;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _amount = e == null
        ? ''
        : (e.amountCents % 100 == 0
            ? (e.amountCents ~/ 100).toString()
            : (e.amountCents / 100).toStringAsFixed(2));
    _tags = e?.tags ?? '';
    _day = e?.day ?? DateTime.now();
    _pocketId = e?.pocketId;
    _toPocketId = e?.toPocketId;
    _reimburse = e?.reimburse ?? 0;
    _mood = e?.mood ?? 0;
    _feeCents = e?.feeCents ?? 0;
    _discountCents = e?.discountCents ?? 0;
    _excludeStats = e?.excludeFromStats ?? false;
    _excludeBudget = e?.excludeFromBudget ?? false;
    _currency = e?.currency;
    _toAmountCents = e?.toAmountCents;
    _refundOfId = e?.refundOfId;
    _memoCtrl = TextEditingController(text: e?.memo ?? '');
    if (e != null) _loadAttachments(e.id);
  }

  Future<void> _loadAttachments(int entryId) async {
    final store = await ref.read(storeProvider.future);
    final list = await store.attachmentsOf(entryId);
    if (!mounted) return;
    setState(() => _savedAttachments = list);
  }

  @override
  void dispose() {
    _memoCtrl.dispose();
    super.dispose();
  }

  /// 当前数字段的金额（分）
  int get _curCents => parseAmountToCents(_amount) ?? 0;

  /// 运算符优先级：先把 × ÷ 并进累加值，再处理 + -
  ///
  /// 走 [applyAmountOp] 单一实现（另一处在上方一屏面板，别再各写一份）。
  int _apply(int acc, String op, int v) => applyAmountOp(acc, op, v);

  /// 表达式最终结果（分）。
  /// 刚按完运算符、下一个数还没输入时返回累加值本身，
  /// 否则会显示「17 × 0 = 0」，用户以为金额被清空了（真计算器都显示累加值）。
  int get _resultCents {
    if (_op == null) return _curCents;
    if (_amount.isEmpty) return _acc;
    return _apply(_acc, _op!, _curCents);
  }

  void _press(String key) {
    // 运算符：把当前数字段并进累加值
    if (const ['+', '-', '×', '÷'].contains(key)) {
      setState(() {
        final cur = _curCents;
        _acc = _op == null ? cur : _apply(_acc, _op!, cur);
        _op = key;
        _amount = '';
      });
      return;
    }
    if (key == 'eq') {
      setState(() {
        if (_op != null) {
          final v = _apply(_acc, _op!, _curCents);
          _amount = v % 100 == 0
              ? (v ~/ 100).toString()
              : (v / 100).toStringAsFixed(2);
          _acc = 0;
          _op = null;
        }
      });
      return;
    }
    setState(() {
      if (key == 'del') {
        if (_amount.isNotEmpty) {
          _amount = _amount.substring(0, _amount.length - 1);
        }
        return;
      }
      if (key == 'clear') {
        _amount = '';
        _acc = 0;
        _op = null;
        return;
      }
      if (!RegExp(r'^[\d.]$').hasMatch(key)) return;
      final next = _amount + key;
      if (!RegExp(r'^\d{0,7}(\.\d{0,2})?$').hasMatch(next)) return;
      _amount = next;
    });
  }

  Future<void> _save({bool continueAdding = false}) async {
    if (_saving) return;
    if (_resultCents <= 0) {
      HapticFeedback.mediumImpact();
      _toast('请输入金额');
      return;
    }
    final pocketId = _pocketId;
    if (pocketId == null) {
      // 一个账户都没有（新装、或全归档了）时只说「请选择账户」是死路：
      // 用户根本无处可选。直接把人带去新建账户页，建完回来接着记。
      final all = ref.read(pocketsProvider).valueOrNull ?? const <Pocket>[];
      final usable = all.where((p) => !p.archived).toList();
      if (usable.isEmpty) {
        await Navigator.of(context)
            .push(AppPageRoute(page: const AccountEditPage()));
        if (mounted) bumpRevision(ref);
        return;
      }
      _toast('请选择账户');
      return;
    }
    // 最后一道防线：本笔币种必须和账户币种一致（转账除外）。
    // 界面上已经把候选账户过滤成同币种了，但"选了外币、又没有该币种账户"
    // 时 _pocketId 还指着旧账户 —— 这里拦住，别落一笔错账。
    if (widget.flow != 'transfer' && _currency != null) {
      final accounts =
          ref.read(pocketsProvider).valueOrNull ?? const <Pocket>[];
      final p = accounts.where((x) => x.id == pocketId).firstOrNull;
      if (p != null && p.currency != _currency) {
        HapticFeedback.mediumImpact();
        _toast('这一笔是 $_currency，账户却是 ${p.currency}。'
            '换一个 $_currency 账户，或把币种改回「跟随账户」');
        return;
      }
    }
    if (_isTransfer) {
      if (_toPocketId == null) {
        _toast('请选择转入账户');
        return;
      }
      if (_toPocketId == pocketId) {
        _toast('转出和转入不能是同一个账户');
        return;
      }
    }

    final tags = _tags
        .split(RegExp(r'[,，]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .join(',');

    setState(() => _saving = true);
    try {
      final store = await ref.read(storeProvider.future);
      final book = await ref.read(activeBookProvider.future);

      // 跨币种转账如果没手填「到账金额」，**绝不能按 1:1 入账**：
      // 从 USD 账户转 100 美元到 CNY 账户，1:1 会让净资产瞬间蒸发 600 多块。
      // 这里按汇率补一个默认值（用户仍可在界面上改）。
      var toAmount = _toAmountCents;
      if (_isTransfer && toAmount == null && _toPocketId != null) {
        final pockets = await ref.read(allPocketsProvider.future);
        String? fromCur;
        String? toCur;
        for (final p in pockets) {
          if (p.id == pocketId) fromCur = p.currency;
          if (p.id == _toPocketId) toCur = p.currency;
        }
        final f = _currency ?? fromCur ?? book.baseCurrency;
        final t = toCur ?? book.baseCurrency;
        if (f != t) {
          final rates = await ref.read(ratesProvider.future);
          final baseCents =
              toBaseCents(_resultCents, f, book.baseCurrency, rates);
          // rates[X] = 1 单位 X 换多少主币 → 反算要除
          toAmount = (baseCents / (rates[t] ?? 1.0)).round();
        }
      }

      late int entryId;
      if (_isEdit) {
        await store.updateEntry(widget.existing!.copyWith(
          pocketId: pocketId,
          toPocketId: _isTransfer ? _toPocketId : null,
          bucketId: _isTransfer ? null : widget.bucket?.id,
          flow: widget.flow,
          amountCents: _resultCents,
          memo: _memoCtrl.text.trim(),
          day: _day,
          tags: tags,
          reimburse: _isTransfer ? 0 : _reimburse,
          mood: _isTransfer ? 0 : _mood,
          feeCents: _isTransfer ? _feeCents : 0,
          discountCents: _discountCents,
          excludeFromStats: _excludeStats,
          excludeFromBudget: _excludeBudget,
          currency: _currency,
          toAmountCents: _isTransfer ? toAmount : null,
          refundOfId: _refundOfId,
          // 编辑时 null 的语义是「清掉」，不是「不改」
          clearToPocket: !_isTransfer,
          clearBucket: _isTransfer,
          clearCurrency: _currency == null,
          clearToAmount: !_isTransfer,
          clearRefund: _refundOfId == null,
        ));
        entryId = widget.existing!.id;
      } else {
        entryId = await store.addEntry(
          bookId: book.id,
          pocketId: pocketId,
          toPocketId: _isTransfer ? _toPocketId : null,
          bucketId: _isTransfer ? null : widget.bucket?.id,
          flow: widget.flow,
          amountCents: _resultCents,
          memo: _memoCtrl.text.trim(),
          day: _day,
          tags: tags,
          reimburse: _isTransfer ? 0 : _reimburse,
          mood: _isTransfer ? 0 : _mood,
          feeCents: _isTransfer ? _feeCents : 0,
          discountCents: _discountCents,
          excludeFromStats: _excludeStats,
          excludeFromBudget: _excludeBudget,
          currency: _currency,
          toAmountCents: _isTransfer ? toAmount : null,
          refundOfId: _refundOfId,
        );
      }
      // 把这次新加的凭证挂到这笔流水上
      for (final path in _newAttachments) {
        await store.addAttachment(
            bookId: book.id, entryId: entryId, path: path);
      }
      _newAttachments.clear();
      bumpRevision(ref);
      if (!mounted) return;
      HapticFeedback.lightImpact();
      SystemSound.play(SystemSoundType.click);
      if (continueAdding) {
        // 继续记下一笔：清掉金额和备注，留在本面板
        setState(() {
          _saving = false;
          _amount = '';
          _memoCtrl.clear();
          _tags = '';
          _acc = 0;
          _op = null;
          _toAmountCents = null;
          _refundOfId = null;
        });
        _memoCtrl.clear();
      } else {
        Navigator.of(context).pop(const EditorSheetResult(saved: true));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppLog.error('editor', '保存流水失败', e);
      _toast('保存失败，详情见「我的 → 数据管理 → 日志中心」');
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这笔记录？'),
        // 已报销的流水删掉时，那笔自动入账的收入会一起进回收站（见 store.dart
        // 的 softDeleteEntries）。不说清楚的话，用户只会看到「少了两行」。
        content: Text(
          (widget.existing?.reimburse == 2 ||
                  widget.existing?.reimburseEntryId != null)
              ? '会移入回收站，5 秒内可撤销。\n'
                  '这笔已报销：当初自动记入的那笔收入会一起移进去，'
                  '否则账户余额会多出一截。'
              : '会移入回收站，5 秒内可撤销。',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: Palette.expense)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final store = await ref.read(storeProvider.future);
    await store.deleteEntry(widget.existing!.id);
    if (!mounted) return;
    bumpRevision(ref);
    if (!mounted) return;
    Navigator.of(context).pop(EditorSheetResult(saved: true, deletedId: widget.existing!.id));
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).toast(text);
  }

  Future<void> _pickDay() async {
    final picked = await pickDateWheel(
      context,
      _day,
      includeDay: true,
      title: '选择日期',
    );
    if (picked != null) setState(() => _day = picked);
  }

  Future<void> _pickMood() async {
    final picked = await showAppSheet<int>(
      context: context,
      title: '这笔花得值吗？',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in const [
            (1, '😊 值'),
            (2, '😐 一般'),
            (3, '😣 后悔'),
            (0, '不标')
          ])
            ListTile(
              title: Text(m.$2),
              trailing: _mood == m.$1 ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, m.$1),
            ),
        ],
      ),
    );
    if (picked != null) setState(() => _mood = picked);
  }

  Future<void> _editNote() async {
    final memoCtrl = TextEditingController(text: _memoCtrl.text);
    final tagCtrl = TextEditingController(text: _tags);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备注与标签'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppTextField(
              label: '备注',
              controller: memoCtrl,
              hint: '这笔钱花在哪了',
              autofocus: true,
              maxLength: 60,
            ),
            const SizedBox(height: 14),
            AppTextField(
              label: '标签',
              controller: tagCtrl,
              hint: '逗号分隔，如：聚餐,报销',
              maxLength: 40,
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _tags = tagCtrl.text;
        // 弹窗里的文本回写到常驻控制器（唯一真源）
        _memoCtrl.text = memoCtrl.text;
      });
    }
  }

  /// 常用备注（备注历史）：点备注框左侧时钟图标弹出
  Future<void> _pickFrequentMemo() async {
    final memos =
        ref.read(frequentMemosProvider).valueOrNull ?? const <String>[];
    if (memos.isEmpty) {
      _toast('还没有历史备注，记几笔之后就有了');
      return;
    }
    final picked = await showAppSheet<String>(
      context: context,
      title: '常用备注',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in memos)
            ListTile(
              dense: true,
              leading:
                  Icon(Icons.history, size: 18, color: Palette.inkFaint(ctx)),
              title: Text(m, style: const TextStyle(fontSize: 14)),
              onTap: () => Navigator.pop(ctx, m),
            ),
        ],
      ),
    );
    if (picked != null) {
      setState(() {
        _memoCtrl.text = picked;
        _memoCtrl.selection =
            TextSelection.fromPosition(TextPosition(offset: picked.length));
      });
    }
  }

  /// 转账的手续费 / 折扣（对齐原版转账表单）
  Future<void> _editFeeOrDiscount({required bool isFee}) async {
    final v = await editFeeOrDiscount(
      context,
      isFee: isFee,
      currentCents: isFee ? _feeCents : _discountCents,
    );
    if (v == null) return;
    setState(() {
      if (isFee) {
        _feeCents = v;
      } else {
        _discountCents = v;
      }
    });
  }

  /// 本笔币种（null = 跟随账户）
  Future<void> _pickCurrency(String pocketCurrency) async {
    final picked = await showAppSheet<String>(
      context: context,
      title: '这一笔的币种',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            title: Text('跟随账户（$pocketCurrency）'),
            trailing: _currency == null ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, '__follow__'),
          ),
          const Divider(height: 1),
          for (final e in kCurrencies.entries)
            ListTile(
              dense: true,
              title: Text('${e.key} · ${e.value.$2}'),
              trailing: _currency == e.key ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, e.key),
            ),
        ],
      ),
    );
    if (picked == null) return;
    final cur = picked == '__follow__' ? null : picked;
    setState(() => _currency = cur);
    if (cur == null) return;

    // 和记账页同一条规则：换成外币就把转出账户切到同币种账户，
    // 否则改一次币种就造出一笔"USD 金额记在 CNY 账户"的错账。
    final list = ref.read(pocketsProvider).valueOrNull ?? const <Pocket>[];
    final now = list.where((p) => p.id == _pocketId).firstOrNull;
    if (now != null && now.currency == cur) return;
    final same = [
      for (final p in list)
        if (p.recordable && p.currency == cur) p,
    ];
    if (same.isNotEmpty && mounted) {
      setState(() => _pocketId = same.first.id);
    }
  }

  /// 转账到账金额（转入账户币种）。跨币种时按当前汇率给一个建议值。
  Future<void> _editToAmount(String toCurrency, {String? fromCurrency}) async {
    var suggest = _toAmountCents;
    if (suggest == null && fromCurrency != null && fromCurrency != toCurrency) {
      final rates = ref.read(ratesProvider).valueOrNull ?? const {};
      final base =
          ref.read(activeBookProvider).valueOrNull?.baseCurrency ?? 'CNY';
      final fromRate =
          fromCurrency == base ? 1.0 : (rates[fromCurrency] ?? 1.0);
      final toRate = toCurrency == base ? 1.0 : (rates[toCurrency] ?? 1.0);
      // 转出金额按汇率换算到目标币种
      if (fromRate > 0 && toRate > 0) {
        suggest = (_resultCents * toRate / fromRate).round();
      }
    }
    int picked = suggest ?? _resultCents;
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('到账金额（$toCurrency）'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AmountField(
                label: '实际到账',
                cents: picked,
                hint: '0.00',
                helper: '跨币种转账时填这里；留空表示与转出金额相同',
                onChanged: (x) => setLocal(() => picked = x),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, 0),
                child: const Text('与转出相同')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, picked),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (v == null) return;
    setState(() => _toAmountCents = v == 0 ? null : v);
  }

  /// 加凭证：拍照或从相册选
  Future<void> _addAttachment() async {
    final book = await ref.read(activeBookProvider.future);
    if (!mounted) return;
    final source = await showAppSheet<String>(
      context: context,
      title: '添加凭证',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('拍一张'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从相册选'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
        ],
      ),
    );
    if (source == null) return;
    final path = source == 'camera'
        ? await AttachmentService.pickFromCamera(book.id)
        : await AttachmentService.pickFromGallery(book.id);
    if (path == null) {
      if (mounted) _toast('没有选中图片');
      return;
    }
    if (!mounted) return;
    setState(() => _newAttachments.add(path));
  }

  Future<void> _removeNewAttachment(String path) async {
    setState(() => _newAttachments.remove(path));
    await AttachmentService.deleteFile(path);
  }

  Future<void> _removeSavedAttachment(int id, String path) async {
    final store = await ref.read(storeProvider.future);
    await store.deleteAttachment(id);
    await AttachmentService.deleteFile(path);
    if (!mounted) return;
    setState(() => _savedAttachments =
        _savedAttachments.where((a) => a.id != id).toList());
  }

  /// 退款关联：从最近的支出里挑一条原记录
  Future<void> _pickRefundSource() async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final recent = await store.entriesRecent(book.id, days: 180);
    final candidates = recent
        .where((e) => e.flow == 'out' && e.id != widget.existing?.id)
        .toList();
    if (!mounted) return;
    if (candidates.isEmpty) {
      _toast('最近半年没有可关联的支出');
      return;
    }
    final picked = await showAppSheet<int>(
      context: context,
      title: '这笔退款对应哪条支出？',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            dense: true,
            leading: const Icon(Icons.link_off, size: 18),
            title: const Text('不关联'),
            onTap: () => Navigator.pop(ctx, -1),
          ),
          const Divider(height: 1),
          for (final e in candidates.take(30))
            ListTile(
              dense: true,
              title: Text(e.memo.isEmpty ? '（无备注）' : e.memo,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${dayKey(e.day)} · ${centsToText(e.amountCents)}',
                  style: const TextStyle(fontSize: 10.5)),
              trailing: _refundOfId == e.id ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, e.id),
            ),
        ],
      ),
    );
    if (picked == null) return;
    setState(() => _refundOfId = picked == -1 ? null : picked);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final currentBookId = ref.watch(activeBookProvider).valueOrNull?.id;
    // 转账的转入/转出方都用「可用账户」：归档账户不该再被选为新流水的目标。
    // （两个 provider 现在都是跨账本的，区别只在含不含归档。）
    // 「记账可被选择」关掉、或「选择生效账本」不命中当前账本的，也隐藏。
    final pocketsAsync = ref.watch(pocketsProvider);
    final pockets = (pocketsAsync.valueOrNull ?? const <Pocket>[])
        .where((p) => !p.archived)
        .where((p) => p.recordable)
        .where((p) => pocketVisibleInBook(p, currentBookId))
        .toList();

    // 显式选了外币 → 「转出 / 记账」账户只能选同币种（转账的「到」不受限：
    // 跨币种转账有 to_amount_cents，是设计内的）。
    // 不这么做的话，一笔 USD 会按 1:1 累加进 CNY 账户余额，
    // 而统计页是按汇率折算的 —— 同一笔钱两个数。
    final scopedPockets = (_isTransfer || _currency == null)
        ? pockets
        : [
            for (final p in pockets)
              if (p.currency == _currency) p,
          ];

    // 打开一条历史跨币种流水来改：当前账户可能不在候选里，先归位，
    // 否则用户不改账户只点保存，错账还是错的。
    if (!_isTransfer &&
        scopedPockets.isNotEmpty &&
        !scopedPockets.any((p) => p.id == _pocketId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!scopedPockets.any((p) => p.id == _pocketId)) {
          setState(() => _pocketId = scopedPockets.first.id);
        }
      });
    }
    // 账户是跨账本共享的：非本账本创建的账户在 chips 上标出归属，
    // 否则用户在账本 A 里看到一个陌生账户，完全不知道它是谁的。
    final books = ref.watch(booksProvider).valueOrNull ?? const <Book>[];
    final bookTitleOf = {for (final b in books) b.id: b.title};
    String ownerLabel(Pocket p) {
      if (currentBookId == null || p.bookId == currentBookId) return '';
      return '（${bookTitleOf[p.bookId] ?? '其它账本'}）';
    }

    if (_pocketId == null && pockets.isNotEmpty) {
      // 默认账户（原版是「默认账户」设置，简记先取第一个）。
      // ⚠️ 但要优先匹配「本笔币种」：三笔不同币种的账户里，
      // 无脑选第一个会让用户在 USD 账户记账时先被塞一个 CNY 账户，
      // 而金额键盘在选账户前就能敲 → 直接按错币种落库。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _pocketId != null) return;
        var pick = pockets.first;
        final cur = _currency;
        if (cur != null) {
          for (final p in pockets) {
            if (p.currency == cur) {
              pick = p;
              break;
            }
          }
        }
        setState(() => _pocketId = pick.id);
      });
    }

    final color = switch (widget.flow) {
      'out' => Palette.expense,
      'in' => Palette.income,
      _ => Palette.brand(context),
    };
    // 当前转出/记账账户、转入账户的币种
    String curOf(int? id) =>
        pockets.where((p) => p.id == id).firstOrNull?.currency ?? 'CNY';
    final fromCur = curOf(_pocketId);
    final toCur = curOf(_toPocketId);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      // 三段式：金额常驻 → 表单区可滚 → 键盘 + 保存常驻。
      // 之前整列都是 MainAxisSize.min，小屏上直接溢出 90px（黄黑条），
      // 还会把键盘和保存键顶到屏幕外——那等于没法记账。
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 金额（右对齐；有运算符时上方显示「累加值 运算符」，下方显示「= 结果」）
          if (_op != null)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  centsToText(_acc),
                  style:
                      TextStyle(fontSize: 13, color: Palette.inkFaint(context)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Text(_op!,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: color)),
                ),
                Text(
                  _amount.isEmpty ? '…' : _amount,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Palette.inkSoft(context)),
                ),
              ],
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                  _op == null
                      ? (_currency == null
                          ? settings.symbol
                          : symbolOf(_currency!))
                      : '=',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: color.withValues(alpha: 0.75))),
              const SizedBox(width: 6),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    _op != null
                        ? centsToText(_resultCents)
                        : (_amount.isEmpty ? '0.00' : _amount),
                    // 给键盘测试用：金额是这个页面的主状态，必须能被钉住
                    key: const Key('amount-display'),
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: (_op == null && _amount.isEmpty)
                          ? Palette.inkFaint(context)
                          : color,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              if (_isEdit)
                IconButton(
                  tooltip: '删除',
                  onPressed: _delete,
                  icon: Icon(Icons.delete_outline,
                      size: 18, color: Palette.expense),
                ),
            ],
          ),
          // 中间表单区：内容再多也只是这里滚，键盘和保存键永远在
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  // 备注（左侧时钟图标 = 常用备注历史，对齐原版）
                  TextField(
                    controller: _memoCtrl,
                    maxLength: 60,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      hintText: '备注（这笔钱花在哪了）',
                      counterText: '',
                      isDense: true,
                      filled: true,
                      fillColor: Palette.paper(context),
                      prefixIcon: PressScale(
                        scale: 0.9,
                        onTap: _pickFrequentMemo,
                        child: Icon(Icons.history,
                            size: 18, color: Palette.inkSoft(context)),
                      ),
                      prefixIconConstraints:
                          const BoxConstraints(minWidth: 40, minHeight: 20),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 账户（横滑 chips）
                  _PocketChipRow(
                    label: _isTransfer ? '从' : '账户',
                    items: scopedPockets,
                    selectedId: _pocketId,
                    onPick: (id) => setState(() => _pocketId = id),
                    ownerLabel: ownerLabel,
                  ),
                  // 选了外币但没有该币种账户：说清楚下一步，别让人对着空行发呆
                  if (!_isTransfer &&
                      _currency != null &&
                      scopedPockets.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '还没有 $_currency 账户。先在「资产」里新建一个该币种的账户，'
                        '或者把这一笔改成「跟随账户」。',
                        style: TextStyle(
                            fontSize: 12, color: Palette.expense),
                      ),
                    ),
                  if (_isTransfer) ...[
                    const SizedBox(height: 6),
                    _PocketChipRow(
                      label: '到',
                      items: pockets,
                      selectedId: _toPocketId,
                      onPick: (id) => setState(() => _toPocketId = id),
                      ownerLabel: ownerLabel,
                    ),
                  ],
                  const SizedBox(height: 8),
                  // 日期 / 标签 / 报销 / 情绪
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _FieldChip(
                          icon: Icons.event_outlined,
                          label: dayKey(_day),
                          onTap: _pickDay),
                      _FieldChip(
                          icon: Icons.edit_note,
                          label: _tags.isEmpty ? '标签' : _tags,
                          active: _tags.isNotEmpty,
                          onTap: _editNote),
                      if (widget.flow == 'out')
                        _FieldChip(
                            icon: Icons.request_quote_outlined,
                            label: _reimburse == 1 ? '待报销' : '报销',
                            active: _reimburse == 1,
                            onTap: () => setState(
                                () => _reimburse = _reimburse == 1 ? 0 : 1)),
                      if (!_isTransfer)
                        _FieldChip(
                            icon: Icons.mood_outlined,
                            label: switch (_mood) {
                              1 => '😊 值',
                              2 => '😐 一般',
                              3 => '😣 后悔',
                              _ => '情绪',
                            },
                            active: _mood != 0,
                            onTap: _pickMood),
                      // 转账才有手续费 / 折扣（对齐原版转账表单）
                      if (_isTransfer)
                        _FieldChip(
                            icon: Icons.receipt_outlined,
                            label: _feeCents > 0
                                ? '手续费 ${centsToText(_feeCents)}'
                                : '手续费',
                            active: _feeCents > 0,
                            onTap: () => _editFeeOrDiscount(isFee: true)),
                      _FieldChip(
                          icon: Icons.local_offer_outlined,
                          label: _discountCents > 0
                              ? '优惠 ${centsToText(_discountCents)}'
                              : '优惠',
                          active: _discountCents > 0,
                          onTap: () => _editFeeOrDiscount(isFee: false)),
                      // 转账的到账金额（跨币种时填）
                      if (_isTransfer)
                        _FieldChip(
                            icon: Icons.south_east,
                            label: _toAmountCents == null
                                ? '到账金额'
                                : '到账 ${centsToText(_toAmountCents!)}',
                            active: _toAmountCents != null,
                            onTap: () =>
                                _editToAmount(toCur, fromCurrency: fromCur)),
                      // 「不计入收支」开了就直接露在主行。
                      // 它藏在展开层里时，用户保存完根本看不出自己开过，
                      // 回头就会问"这笔怎么没进统计"（一木是独立「属性」chip）。
                      if (_excludeStats)
                        _FieldChip(
                            icon: Icons.visibility_off_outlined,
                            label: '不计收支',
                            active: true,
                            onTap: () =>
                                setState(() => _excludeStats = false)),
                      // ▾ 更多 / ▴ 收起。展开层里已设了几项就写在 chip 上，
                      // 否则「不计预算 / 币种 / 凭证」设了跟没设一个样。
                      _FieldChip(
                          icon: _moreOpen
                              ? Icons.keyboard_arrow_up
                              : Icons.keyboard_arrow_down,
                          label: _moreOpen
                              ? '收起'
                              : (_moreSetCount > 0 ? '更多 · $_moreSetCount' : '更多'),
                          active: _moreOpen || _moreSetCount > 0,
                          onTap: () => setState(() => _moreOpen = !_moreOpen)),
                      if (_moreOpen) ...[
                        // 本笔币种（覆盖账户币种）
                        _FieldChip(
                            icon: Icons.currency_exchange,
                            label:
                                _currency == null ? '币种 跟随账户' : '币种 $_currency',
                            active: _currency != null,
                            onTap: () => _pickCurrency(fromCur)),
                        // 不计入收支（内部调账、代付等）
                        _FieldChip(
                            icon: Icons.visibility_off_outlined,
                            label: '不计入收支',
                            active: _excludeStats,
                            onTap: () =>
                                setState(() => _excludeStats = !_excludeStats)),
                        // 不计入预算
                        _FieldChip(
                            icon: Icons.pie_chart_outline,
                            label: '不计入预算',
                            active: _excludeBudget,
                            onTap: () => setState(
                                () => _excludeBudget = !_excludeBudget)),
                        // 凭证（拍照 / 相册）
                        _FieldChip(
                            icon: Icons.photo_camera_outlined,
                            label: _savedAttachments.isEmpty &&
                                    _newAttachments.isEmpty
                                ? '加凭证'
                                : '凭证 ${_savedAttachments.length + _newAttachments.length}',
                            active: _savedAttachments.isNotEmpty ||
                                _newAttachments.isNotEmpty,
                            onTap: _addAttachment),
                        // 退款关联（收入的笔才能挂到某条原支出上）
                        if (!_isTransfer && widget.flow == 'in')
                          _FieldChip(
                              icon: Icons.undo,
                              label: _refundOfId == null ? '退款关联' : '已关联原支出',
                              active: _refundOfId != null,
                              onTap: _pickRefundSource),
                      ],
                    ],
                  ),
                  // 凭证：已挂的缩略图 + 加凭证入口
                  if (_savedAttachments.isNotEmpty ||
                      _newAttachments.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 54,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final a in _savedAttachments)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: AttachmentThumb(
                                path: a.path,
                                onTap: () =>
                                    Navigator.of(context).push(AppPageRoute(
                                  page: AttachmentViewerPage(
                                    paths: [
                                      for (final x in _savedAttachments) x.path
                                    ],
                                    initialIndex: _savedAttachments.indexOf(a),
                                  ),
                                )),
                                onRemove: () =>
                                    _removeSavedAttachment(a.id, a.path),
                              ),
                            ),
                          for (final path in _newAttachments)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: AttachmentThumb(
                                path: path,
                                onTap: () =>
                                    Navigator.of(context).push(AppPageRoute(
                                  page: AttachmentViewerPage(paths: [path]),
                                )),
                                onRemove: () => _removeNewAttachment(path),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          // 键盘（多了 + - × ÷ 和 =，对齐原版的表达式模式）
          AmountKeypad(onKey: _press, showOperators: !_isTransfer),
          const SizedBox(height: 8),
          // 底部：再记一笔 + 保存
          Row(
            children: [
              if (!_isEdit)
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _saving ? null : () => _save(continueAdding: true),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('再记一笔', style: TextStyle(fontSize: 14)),
                  ),
                ),
              if (!_isEdit) const SizedBox(width: 10),
              Expanded(
                flex: _isEdit ? 1 : 2,
                child: SizedBox(
                  height: 48,
                  child: MorphButton(
                    saving: _saving,
                    onPressed: _saving ? null : () => _save(),
                    label: '保存',
                    color: color,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 分类网格单元：上方图标、下方名字；有子分类时右下角标三个点。
class _BucketTile extends StatelessWidget {
  const _BucketTile({
    required this.bucket,
    required this.onTap,
    this.hasChildren = false,
    this.expanded = false,
    this.selected = false,
  });

  final Bucket bucket;
  final VoidCallback onTap;
  final bool hasChildren;
  final bool expanded;

  /// 已选为当前草稿的分类（一屏流程：选中后底部金额面板直接跟着变）
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.94,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: expanded || selected
              ? Palette.brand(context).withValues(alpha: 0.09)
              : Palette.card(context),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: (expanded || selected)
                ? Palette.brand(context)
                : Palette.hairline(context),
          ),
        ),
        child: Stack(
          children: [
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AppGlyph(bucket.glyph, size: 20),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      bucket.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Palette.ink(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 有子分类：右下角三个点（原版也是这个提示）
            if (hasChildren)
              Positioned(
                right: 4,
                bottom: 3,
                child: Icon(
                  expanded ? Icons.expand_less : Icons.more_horiz,
                  size: 13,
                  color: expanded
                      ? Palette.brand(context)
                      : Palette.inkFaint(context),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 表单小 chip（日期 / 标签 / 报销 / 更多…）。
///
/// 抽成顶层 widget：一屏记账面板和「金额面板」两边都要用，
/// 留在某个 State 里另一边就只能复制一份。
class _FieldChip extends StatelessWidget {
  const _FieldChip(
      {required this.icon,
      required this.label,
      required this.onTap,
      this.active = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return PressScale(
      scale: 0.95,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? Palette.brand(context).withValues(alpha: 0.10)
              : Palette.card(context),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color:
                  active ? Palette.brand(context) : Palette.hairline(context)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 14,
                color:
                    active ? Palette.brand(context) : Palette.inkSoft(context)),
            const SizedBox(width: 5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 96),
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: active
                          ? Palette.brand(context)
                          : Palette.ink(context))),
            ),
          ],
        ),
      ),
    );
  }
}

/// 账户横滑 chips（同一排里能一眼分出储蓄卡/信用卡/负债）。
class _PocketChipRow extends StatelessWidget {
  const _PocketChipRow(
      {required this.label,
      required this.items,
      required this.selectedId,
      required this.onPick,
      this.ownerLabel});

  final String label;
  final List<Pocket> items;
  final int? selectedId;
  final ValueChanged<int> onPick;

  /// 非本账本创建的账户要怎么标注（账户跨账本共享后必须让用户看出归属）
  final String Function(Pocket)? ownerLabel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 30,
          child: Text(label,
              style: TextStyle(fontSize: 12, color: Palette.inkFaint(context))),
        ),
        Expanded(
          child: SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final p = items[i];
                final sel = p.id == selectedId;
                return PressScale(
                  scale: 0.94,
                  onTap: () => onPick(p.id),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: sel
                          ? Palette.brand(context).withValues(alpha: 0.12)
                          : Palette.paper(context),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: sel
                            ? Palette.brand(context)
                            : Palette.hairline(context),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AppGlyph(p.glyph, size: 12),
                        const SizedBox(width: 4),
                        if (p.kind != PocketKind.cash) ...[
                          Icon(
                            switch (p.kind) {
                              PocketKind.bank => Icons.account_balance,
                              PocketKind.credit => Icons.credit_card,
                              PocketKind.debt => Icons.trending_down,
                              PocketKind.cash => Icons.payments_outlined,
                            },
                            size: 11,
                            color: switch (p.kind) {
                              PocketKind.bank => const Color(0xFF3E7BB6),
                              PocketKind.credit => const Color(0xFF555A78),
                              PocketKind.debt => Palette.expense,
                              PocketKind.cash => Palette.inkFaint(context),
                            },
                          ),
                          const SizedBox(width: 3),
                        ],
                        Text('${p.displayName}${ownerLabel?.call(p) ?? ''}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  sel ? FontWeight.w600 : FontWeight.w400,
                              color: sel
                                  ? Palette.brand(context)
                                  : Palette.ink(context),
                            )),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
