import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_glyph.dart';
import '../core/currency.dart';
import '../data/store.dart';
import '../state/settings.dart';
import '../services/attachment_service.dart';
import '../state/ledger_state.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

const _bookGlyphs = ['📒', '🏠', '🧳', '💼', '🎓', '🐱', '🚗', '✈️'];

/// 账本管理 + 汇率维护。
///
/// 汇率是**手填**：自动拉取要联网 + 加权限，留给下一轮；这里先把机制跑通，
/// 平时只有外币账户的人才需要填。
class BookManagePage extends ConsumerWidget {
  const BookManagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final booksAsync = ref.watch(booksProvider);
    final activeAsync = ref.watch(activeBookProvider);
    final ratesAsync = ref.watch(ratesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('账本与汇率')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editBook(context, ref, null),
        icon: const Icon(Icons.add),
        label: const Text('新建账本'),
      ),
      body: booksAsync.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(),
        error: (e, _) => Center(child: LoadError(error: e)),
        data: (books) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            SectionLabel('账本'),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < books.length; i++) ...[
                    if (i > 0) const Divider(height: 1, indent: 56),
                    ListTile(
                      leading: AppGlyph(books[i].glyph, size: 20),
                      title: Text(books[i].title),
                      subtitle: Text('主币种 ${nameOf(books[i].baseCurrency)}',
                          style: const TextStyle(fontSize: 11)),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz, size: 20),
                        onSelected: (v) async {
                          if (v == 'edit') {
                            await _editBook(context, ref, books[i]);
                          } else if (v == 'delete') {
                            await _deleteBook(context, ref, books[i]);
                          } else if (v == 'use') {
                            ref.read(activeBookIdProvider.notifier).state =
                                books[i].id;
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'use', child: Text('设为当前账本')),
                          PopupMenuItem(value: 'edit', child: Text('编辑')),
                          PopupMenuItem(value: 'delete', child: Text('删除账本')),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text('删除账本会连同它的账户、分类、流水、预算一起删掉，不可恢复。',
                style:
                    TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
            const SizedBox(height: 20),
            SectionLabel('汇率（1 外币 = ? 主币）'),
            Panel(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final r
                      in ratesAsync.valueOrNull?.entries.toList() ?? const [])
                    ListTile(
                      dense: true,
                      title: Text('${nameOf(r.key)}（${r.key}）'),
                      trailing: Text(r.value.toStringAsFixed(4)),
                      onTap: () => _editRate(
                          context,
                          ref,
                          activeAsync.valueOrNull?.baseCurrency ?? 'CNY',
                          r.key),
                    ),
                  ListTile(
                    leading: const Icon(Icons.add, size: 20),
                    title: const Text('添加 / 修改汇率'),
                    onTap: () async {
                      final book = await ref.read(activeBookProvider.future);
                      if (!context.mounted) return;
                      await _pickCurrencyToRate(context, ref, book);
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '外币账户的流水会按这里的汇率折算进统计；没填汇率的币种按 1:1 计（会在报告里标注）。',
              style: TextStyle(
                  fontSize: 11, height: 1.5, color: Palette.inkFaint(context)),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickCurrencyToRate(
      BuildContext context, WidgetRef ref, Book book) async {
    final pockets = await ref.read(allPocketsProvider.future);
    final used = pockets
        .map((p) => p.currency)
        .where((c) => c != book.baseCurrency)
        .toSet();
    if (!context.mounted) return;
    final code = await showAppSheet<String>(
      context: context,
      title: '选择币种',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in used)
            ListTile(
              title: Text('${nameOf(c)}（$c）'),
              onTap: () => Navigator.pop(ctx, c),
            ),
          if (used.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('先把某个账户的币种改成外币'),
            ),
        ],
      ),
    );
    if (code == null) return;
    if (!context.mounted) return;
    await _editRate(context, ref, book.baseCurrency, code);
  }

  Future<void> _editRate(
      BuildContext context, WidgetRef ref, String base, String code) async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    if (!context.mounted) return;
    final existing = (await store.rates(book.id))[code];
    if (!context.mounted) return;
    final ctrl = TextEditingController(
        text: existing == null ? '' : existing.toStringAsFixed(4));
    final value = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('$code → $base'),
        content: AppTextField(
          label: '1 $code 等于多少 $base',
          controller: ctrl,
          hint: '例如 7.15',
          helper: '汇率可以填到 4 位小数，用来把外币折算成主币种',
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textAlign: TextAlign.end,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim());
              Navigator.pop(ctx, (v != null && v > 0) ? v : null);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (value == null) return;
    await store.setRate(book.id, code, value);
    bumpRevision(ref);
  }

  Future<void> _editBook(
      BuildContext context, WidgetRef ref, Book? book) async {
    String title = book?.title ?? '';
    // 常驻 controller：放在 build 里每帧新建会让光标跳到开头、
    // 敲一半点图标/下拉就丢位置（这个坑在记账备注框踩过，这里不能再犯）。
    final titleCtrl = TextEditingController(text: title);
    String glyph = book?.glyph ?? _bookGlyphs.first;
    String baseCurrency = book?.baseCurrency ?? 'CNY';
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(book == null ? '新建账本' : '编辑账本'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AppTextField(
                label: '名称',
                controller: titleCtrl,
                hint: '例如 日常账本、旅行',
                onChanged: (v) => title = v,
              ),
              const SizedBox(height: 14),
              GlyphPicker(
                glyphs: _bookGlyphs,
                value: glyph,
                onChanged: (g) => setState(() => glyph = g),
              ),
              const SizedBox(height: 14),
              AppDropdown<String>(
                label: '主币种',
                value: baseCurrency,
                helper: '统计和净资产都以主币种为准',
                items: [
                  for (final e in kCurrencies.entries)
                    DropdownMenuItem(
                        value: e.key, child: Text('${e.key} · ${e.value.$2}')),
                ],
                onChanged: (v) =>
                    setState(() => baseCurrency = v ?? baseCurrency),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('保存')),
          ],
        ),
      ),
    );
    if (saved != true) return;
    final store = await ref.read(storeProvider.future);
    if (book == null) {
      final id = await store.addBook(
        title.trim().isEmpty ? '新账本' : title.trim(),
        glyph,
        baseCurrency,
      );
      ref.read(activeBookIdProvider.notifier).state = id;
    } else {
      // 主币种一变，所有「折算成主币」的结果都变：
      //   · 旧 rates 里的汇率还是按旧主币存的 → 新主币很可能没有汇率，
      //     于是全部走 1:1，资产总额可能缩水到 1/7 且方向相反
      //   · amount_cents 的口径没变，但解释方式全变了
      // 原来毫无提示，用户以为只是改了个下拉框。
      if (baseCurrency != book.baseCurrency) {
        // ConsumerWidget 没有 mounted，用 context.mounted
        if (!context.mounted) return;
        final stats = await store.entryStats(book.id);
        if (stats.count > 0) {
          // 每次 await 之后都要重新确认（linter 的 use_build_context_synchronously）
          if (!context.mounted) return;
          final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('主币种会变，历史金额全部重算'),
              content: Text(
                '这个账本有 ${stats.count} 笔流水，金额是按原主币种的口径存的。\n\n'
                '改成 ${nameOf(baseCurrency)} 后，请一并到「账本管理」里'
                '核对汇率，否则统计可能整体偏离。\n\n确定继续吗？',
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
          if (ok != true) return;
        }
        // 展示符号还停在「¥」的话，跟着主币走，
        // 否则折成美元的合计会顶着一个「¥」，用户完全看不懂。
        final s = ref.read(settingsProvider);
        if (s.symbol == '¥' || s.symbol == symbolOf(book.baseCurrency)) {
          await ref
              .read(settingsProvider.notifier)
              .setSymbol(symbolOf(baseCurrency));
        }
      }
      await store.updateBook(Book(
        id: book.id,
        title: title.trim().isEmpty ? book.title : title.trim(),
        glyph: glyph,
        baseCurrency: baseCurrency,
      ));
    }
    bumpRevision(ref);
  }

  Future<void> _deleteBook(
      BuildContext context, WidgetRef ref, Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${book.title}」？'),
        content: const Text(
            '这个账本下的分类、流水、预算、目标、周期账单会一起删除，无法恢复。\n'
            '账户是跨账本共用的：只有「仅本账本用过」的账户会被删掉，'
            '别的账本还在用的会保留。'),
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
    try {
      await store.deleteBook(book.id);
      // 数据库行删了，磁盘上的凭证图也要删，否则永久占空间
      await AttachmentService.deleteBookDir(book.id);
      ref.read(activeBookIdProvider.notifier).state = null;
      bumpRevision(ref);
    } on StateError catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
