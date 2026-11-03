import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'amount_keypad.dart';
import 'app_glyph.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 记账模板图标候选（emoji）。第一个是默认。
const kTemplateGlyphs = [
  '📋',
  '🍜',
  '🚌',
  '☕',
  '🛒',
  '💡',
  '📱',
  '🏠',
  '⛽',
  '🎬',
  '💊',
  '🐱',
];

/// 记账模板管理：列表 + 删除 + 新建/编辑入口。
class TemplateManagePage extends ConsumerStatefulWidget {
  const TemplateManagePage({super.key, this.editing});

  /// 直接进入编辑某条模板（长按列表项时传入）。
  final Template? editing;

  @override
  ConsumerState<TemplateManagePage> createState() => _TemplateManagePageState();
}

class _TemplateManagePageState extends ConsumerState<TemplateManagePage> {
  @override
  void initState() {
    super.initState();
    // 带 editing 进来：直接把编辑页推到最上面。
    if (widget.editing != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).push(AppPageRoute(
            page: TemplateEditPage(template: widget.editing)));
      });
    }
  }

  Future<void> _confirmDelete(Template t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个模板？'),
        content: Text('「${t.title}」删掉后，记账页顶部就少一个快捷项。'),
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
    if (ok != true || !mounted) return;
    final store = await ref.read(storeProvider.future);
    await store.deleteTemplate(t.id);
    bumpRevision(ref);
    if (mounted) {
      ScaffoldMessenger.of(context).toast('已删除模板');
    }
  }

  @override
  Widget build(BuildContext context) {
    final bookId = ref.watch(activeBookIdProvider);
    final book = ref.watch(activeBookProvider).valueOrNull;
    final asyncTemplates = bookId == null
        ? const AsyncLoading<List<Template>>()
        : ref.watch(templatesProvider(bookId));
    final buckets = ref.watch(allBucketsProvider).valueOrNull ?? const <Bucket>[];
    final pockets = ref.watch(pocketsProvider).valueOrNull ?? const <Pocket>[];

    final bucketTitle = {
      for (final b in buckets) b.id: b.title,
    };
    final pocketName = {
      for (final p in pockets) p.id: p.displayName,
    };

    return Scaffold(
      appBar: AppBar(title: const Text('记账模板')),
      body: asyncTemplates.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => LoadError(error: e, compact: true),
              data: (templates) {
                if (templates.isEmpty) {
                  return Center(
                    child: EmptyView(
                      title: '还没有记账模板',
                      hint: '把常用的「账户 + 分类 + 金额」存成模板，'
                          '下次在记账页点一下就直接记一笔。',
                      actionLabel: '新建模板',
                      onAction: () => Navigator.of(context).push(
                          AppPageRoute(page: const TemplateEditPage())),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: templates.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final t = templates[i];
                    final symbol = ref.watch(settingsProvider).symbol;
                    final cat = t.bucketId == null
                        ? ''
                        : (bucketTitle[t.bucketId] ?? '未分类');
                    final acc = pocketName[t.pocketId] ?? '账户已删';
                    final parts = <String>[acc];
                    if (cat.isNotEmpty) parts.add(cat);
                    final subtitle = parts.join(' · ');
                    return ListTile(
                      leading: SizedBox(
                        width: 36,
                        height: 36,
                        child: AppGlyph(t.glyph, size: 22),
                      ),
                      title: Text(t.title),
                      subtitle: Text(
                        '$subtitle · $symbol${centsToText(t.amountCents)}',
                        style: TextStyle(
                            fontSize: 12, color: Palette.inkFaint(context)),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 19),
                        color: Palette.inkSoft(context),
                        onPressed: () => _confirmDelete(t),
                      ),
                      onTap: () => Navigator.of(context).push(AppPageRoute(
                          page: TemplateEditPage(template: t))),
                    );
                  },
                );
              },
            ),
      floatingActionButton: book == null
          ? null
          : FloatingActionButton(
              onPressed: () => Navigator.of(context)
                  .push(AppPageRoute(page: const TemplateEditPage())),
              child: const Icon(Icons.add),
            ),
    );
  }
}

/// 新建 / 编辑一条记账模板。
class TemplateEditPage extends ConsumerStatefulWidget {
  const TemplateEditPage({super.key, this.template});

  final Template? template;

  @override
  ConsumerState<TemplateEditPage> createState() => _TemplateEditPageState();
}

class _TemplateEditPageState extends ConsumerState<TemplateEditPage> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _memoCtrl;
  late final TextEditingController _tagsCtrl;

  late String _glyph;
  late String _flow;
  late int? _pocketId;
  late int? _toPocketId;
  late int? _bucketId;
  late int _amountCents;
  String? _titleError;

  bool get _isEdit => widget.template != null;

  @override
  void initState() {
    super.initState();
    final t = widget.template;
    _titleCtrl = TextEditingController(text: t?.title ?? '');
    _memoCtrl = TextEditingController(text: t?.memo ?? '');
    _tagsCtrl = TextEditingController(text: t?.tags ?? '');
    _glyph = t?.glyph ?? kTemplateGlyphs.first;
    _flow = t?.flow ?? 'out';
    _pocketId = t?.pocketId;
    _toPocketId = t?.toPocketId;
    _bucketId = t?.bucketId;
    _amountCents = t?.amountCents ?? 0;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _memoCtrl.dispose();
    _tagsCtrl.dispose();
    super.dispose();
  }

  List<DropdownMenuItem<int?>> _pocketItems(List<Pocket> pockets) =>
      [for (final p in pockets) DropdownMenuItem<int?>(value: p.id, child: Text(p.displayName))];

  Future<void> _pickAmount() async {
    final v = await showAmountKeypad(
      context,
      initialCents: _amountCents,
      title: '模板金额',
      allowZero: false,
    );
    if (v != null && mounted) setState(() => _amountCents = v);
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      setState(() => _titleError = '起个名字，方便在记账页一眼认出');
      return;
    }
    if (_pocketId == null) {
      ScaffoldMessenger.of(context).toast('请选择记账账户');
      return;
    }
    if (_amountCents <= 0) {
      ScaffoldMessenger.of(context).toast('请先设置金额');
      return;
    }
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    if (_isEdit) {
      await store.updateTemplate(Template(
        id: widget.template!.id,
        bookId: book.id,
        title: title,
        glyph: _glyph,
        flow: _flow,
        pocketId: _pocketId!,
        toPocketId: _flow == 'transfer' ? _toPocketId : null,
        bucketId: _flow == 'transfer' ? null : _bucketId,
        amountCents: _amountCents,
        memo: _memoCtrl.text.trim(),
        tags: _tagsCtrl.text.trim(),
        currency: null,
        rank: widget.template!.rank,
      ));
    } else {
      await store.addTemplate(
        bookId: book.id,
        title: title,
        glyph: _glyph,
        flow: _flow,
        pocketId: _pocketId!,
        toPocketId: _flow == 'transfer' ? _toPocketId : null,
        bucketId: _flow == 'transfer' ? null : _bucketId,
        amountCents: _amountCents,
        memo: _memoCtrl.text.trim(),
        tags: _tagsCtrl.text.trim(),
        currency: null,
      );
    }
    bumpRevision(ref);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final pockets = (ref.watch(pocketsProvider).valueOrNull ?? const <Pocket>[])
        .where((p) => !p.archived)
        .where((p) => p.recordable)
        .toList();
    final buckets = ref.watch(bucketsProvider(_flow)).valueOrNull ??
        const <Bucket>[];

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '编辑模板' : '新建模板'),
        actions: [
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          AppTextField(
            label: '模板名称',
            controller: _titleCtrl,
            hint: '如：午餐、打车、工资',
            maxLength: 20,
            errorText: _titleError,
          ),
          const SizedBox(height: 16),
          GlyphPicker(
            glyphs: kTemplateGlyphs,
            value: _glyph,
            onChanged: (g) => setState(() => _glyph = g),
          ),
          const SizedBox(height: 16),
          // 流向：支出 / 收入 / 转账
          AppField(
            label: '类型',
            child: SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'out', label: Text('支出')),
                ButtonSegment(value: 'in', label: Text('收入')),
                ButtonSegment(value: 'transfer', label: Text('转账')),
              ],
              selected: {_flow},
              onSelectionChanged: (s) => setState(() {
                _flow = s.first;
                // 切到转账：分类无意义；切回支出/收入：清空失效的"转入账户"
                if (_flow == 'transfer') {
                  _bucketId = null;
                } else {
                  _toPocketId = null;
                }
              }),
            ),
          ),
          const SizedBox(height: 16),
          AppDropdown<int?>(
            label: _flow == 'transfer' ? '转出账户' : '记账账户',
            value: _pocketId,
            hint: '选择账户',
            items: _pocketItems(pockets),
            onChanged: (v) => setState(() => _pocketId = v),
          ),
          if (_flow == 'transfer') ...[
            const SizedBox(height: 16),
            AppDropdown<int?>(
              label: '转入账户',
              value: _toPocketId,
              hint: '选择转入账户',
              items: _pocketItems(pockets),
              onChanged: (v) => setState(() => _toPocketId = v),
            ),
          ] else ...[
            const SizedBox(height: 16),
            AppDropdown<int?>(
              label: '分类',
              value: _bucketId,
              hint: '未分类',
              items: [
                DropdownMenuItem(
                    value: null,
                    child: Text('未分类',
                        style: TextStyle(color: Palette.inkFaint(context)))),
                for (final b in buckets)
                  DropdownMenuItem(value: b.id, child: Text(b.title)),
              ],
              onChanged: (v) => setState(() => _bucketId = v),
            ),
          ],
          const SizedBox(height: 16),
          AppField(
            label: '金额',
            child: PressScale(
              scale: 0.98,
              onTap: _pickAmount,
              child: Container(
                height: 42,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Palette.paper(context),
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '${settings.symbol}${centsToText(_amountCents)}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: _amountCents > 0
                            ? Palette.ink(context)
                            : Palette.inkFaint(context),
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 18, color: Palette.inkFaint(context)),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          AppTextField(
            label: '备注',
            controller: _memoCtrl,
            hint: '可选',
            maxLength: 60,
          ),
          const SizedBox(height: 16),
          AppTextField(
            label: '标签',
            controller: _tagsCtrl,
            hint: '逗号分隔，如：聚餐,报销',
            maxLength: 40,
          ),
          const SizedBox(height: 22),
          Text(
            '保存后在记账页顶部会多一个快捷项，点一下就按这套预设直接记一笔。',
            style: TextStyle(
                fontSize: 11.5, height: 1.5, color: Palette.inkFaint(context)),
          ),
        ],
      ),
    );
  }
}
