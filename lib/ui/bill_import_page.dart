import 'app_glyph.dart';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/rules.dart';
import '../core/bill_csv.dart';
import '../data/store.dart';
import '../services/app_log.dart';
import '../state/ledger_state.dart';
import 'common.dart';
import 'motion.dart';
import 'pocket_manage_page.dart' show showPocketEditor;
import 'theme.dart';

/// 账单导入：把微信 / 支付宝导出的 CSV 粘进来，批量入账。
class BillImportPage extends ConsumerStatefulWidget {
  const BillImportPage({super.key});

  @override
  ConsumerState<BillImportPage> createState() => _BillImportPageState();
}

class _BillImportPageState extends ConsumerState<BillImportPage> {
  final _ctrl = TextEditingController();
  BillParseResult? _result;
  int? _pocketId;
  bool _importing = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      _toast('剪贴板里没有内容');
      return;
    }
    _ctrl.text = text;
    _parse();
  }

  void _parse() {
    final result = parseBillCsv(_ctrl.text);
    setState(() => _result = result);
  }

  /// 选一个 CSV 文件读进来（微信/支付宝导出的账单通常是 UTF-8 BOM）
  Future<void> _pickFile() async {
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv', 'txt'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty) return;
      final f = picked.files.first;
      String text;
      if (f.bytes != null) {
        text = _decode(f.bytes!);
      } else if (f.path != null) {
        text = _decode(await File(f.path!).readAsBytes());
      } else {
        _toast('读不到文件内容');
        return;
      }
      if (!mounted) return;
      setState(() {
        _ctrl.text = text;
        _result = null;
      });
      _toast('已读入 ${text.length} 个字符，点「解析」开始');
    } catch (e) {
      AppLog.error('import', '选择文件失败', e);
      if (mounted) _toast('选文件失败，换个文件试试');
    }
  }

  /// 优先 UTF-8，失败退回 GBK（国内账单常见编码）
  static String _decode(List<int> bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } catch (_) {
      try {
        return latin1.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }

  Future<void> _import() async {
    final result = _result;
    if (result == null || result.rows.isEmpty) return;
    final pocketId = _pocketId;
    if (pocketId == null) {
      _toast('先选一个账户');
      return;
    }
    setState(() => _importing = true);
    try {
      final store = await ref.read(storeProvider.future);
      final book = await ref.read(activeBookProvider.future);
      final pockets = await store.allPockets(includeArchived: false);
      Pocket? pocket;
      for (final p in pockets) {
        if (p.id == pocketId) pocket = p;
      }
      if (pocket == null) {
        _toast('账户不存在了，请重新选择');
        return;
      }

      // 现有分类按名字建索引，账单里的「交易分类」能对上就直接用
      final buckets = <Bucket>[
        ...await store.buckets(book.id, 'out'),
        ...await store.buckets(book.id, 'in'),
      ];
      final bucketByName = {
        for (final b in buckets) b.title: b,
      };

      // 去重：先取这批账单日期范围内的已有流水，做指纹集合
      final days = result.rows.map((r) => r.day).toList()..sort();
      final existing =
          await store.entriesBetween(book.id, days.first, days.last);
      final seen = {
        for (final e in existing) billFingerprint(e.day, e.amountCents, e.memo),
      };

      var inserted = 0;
      var duplicated = 0;
      for (final row in result.rows) {
        final memo = billMemoOf(row);
        final fp = billFingerprint(row.day, row.cents, memo);
        if (seen.contains(fp)) {
          duplicated++;
          continue;
        }
        final bucket = bucketByName[row.category];
        await store.addEntry(
          bookId: book.id,
          pocketId: pocket.id,
          bucketId: bucket?.id,
          flow: row.flow,
          amountCents: row.cents,
          memo: memo,
          day: row.day,
          tags: row.tags,
          reimburse: row.reimburse,
        );
        seen.add(fp);
        inserted++;
      }

      if (!mounted) return;
      bumpRevision(ref);
      setState(() {
        _importing = false;
        _result = null;
        _ctrl.clear();
      });
      // 导入完回明细页，让用户马上看到新记录
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('导入 $inserted 笔'
            '${duplicated > 0 ? '，跳过重复 $duplicated 笔' : ''}'),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      AppLog.error('import', '导入失败', e);
      _toast('导入失败，详情见日志中心');
    }
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final pocketsAsync = ref.watch(pocketsProvider);
    final pockets = pocketsAsync.valueOrNull ?? const <Pocket>[];
    final result = _result;

    return Scaffold(
      appBar: AppBar(title: const Text('账单导入')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: [
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: Palette.brand(context)),
                    const SizedBox(width: 6),
                    const Text('怎么用',
                        style: TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '微信：我 → 服务 → 钱包 → 账单 → 常见问题 → 下载账单 → 用于个人对账\n'
                  '支付宝：我的 → 账单 → 右上角 … → 开具交易流水证明 → 用于个人对账\n'
                  '拿到 CSV 后解压，用文本/表格打开全选复制，粘到下面即可。',
                  style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: Palette.inkSoft(context)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _paste,
                  icon: const Icon(Icons.content_paste, size: 16),
                  label: const Text('从剪贴板粘贴'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    _ctrl.clear();
                    setState(() => _result = null);
                  },
                  icon: const Icon(Icons.clear, size: 16),
                  label: const Text('清空'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // 选文件：从手机里挑一个 CSV（对齐原版的文件导入）
          PressScale(
            scale: 0.97,
            onTap: _pickFile,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: Palette.card(context),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Palette.brand(context)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.folder_open,
                      size: 18, color: Palette.brand(context)),
                  const SizedBox(width: 8),
                  Text('选择 CSV 文件',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Palette.brand(context))),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: Divider(color: Palette.hairline(context))),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('或者直接粘贴',
                    style: TextStyle(
                        fontSize: 10.5, color: Palette.inkFaint(context))),
              ),
              Expanded(child: Divider(color: Palette.hairline(context))),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _ctrl,
            maxLines: 6,
            // 没有 onChanged 的话，直接 Ctrl+V 粘进来不会重建本页，
            // 下面「解析」按钮一直停在 onPressed: null 的禁用态，整条导入链路点不动。
            onChanged: (_) => setState(() {}),
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: '把账单 CSV 内容粘到这里…',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 46,
            child: FilledButton(
              onPressed: _ctrl.text.trim().isEmpty ? null : _parse,
              child: const Text('解析'),
            ),
          ),
          if (result != null) ...[
            const SizedBox(height: 16),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('识别结果',
                          style: TextStyle(
                              fontSize: 12, color: Palette.inkSoft(context))),
                      const Spacer(),
                      Text(_sourceLabel(result.source),
                          style: TextStyle(
                              fontSize: 12, color: Palette.inkFaint(context))),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text('${result.rows.length} 笔',
                      style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    '收入 ${_yuan(result.totalIn)} · 支出 ${_yuan(result.totalOut)}'
                    '${result.skipped > 0 ? ' · 跳过 ${result.skipped} 行' : ''}',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkSoft(context)),
                  ),
                  if (result.warnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    for (final w in result.warnings.take(3))
                      Text('· $w',
                          style: TextStyle(
                              fontSize: 10.5, color: Palette.expense)),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            SectionLabel('导入到哪个账户'),
            if (pockets.isEmpty)
              // 一个账户都没有（新装 App 的初始状态）：不渲染空列表，
              // 直接给「先去建账户」的出口，否则用户粘完账单发现没地方导。
              Panel(
                child: Row(
                  children: [
                    Icon(Icons.account_balance_wallet_outlined,
                        size: 18, color: Palette.brand(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('还没有账户，先建一个再导入',
                          style: TextStyle(
                              fontSize: 13, color: Palette.inkSoft(context))),
                    ),
                    TextButton(
                      onPressed: () => showPocketEditor(context, ref, null),
                      child: const Text('添加账户'),
                    ),
                  ],
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final p in pockets.where((p) => !p.archived))
                    ChoiceChip(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AppGlyph(p.glyph, size: 16),
                          const SizedBox(width: 4),
                          Flexible(
                              child: Text(p.title,
                                  overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                      selected: _pocketId == p.id,
                      onSelected: (_) => setState(() => _pocketId = p.id),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            SizedBox(
              height: 50,
              child: FilledButton(
                onPressed: result.rows.isEmpty || _importing ? null : _import,
                child: Text(_importing ? '导入中…' : '导入 ${result.rows.length} 笔'),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '重复的会自动跳过（同一天 + 同金额 + 同备注视为同一条）。'
              '分类名能对上就自动归类，对不上记为「未分类」。',
              style: TextStyle(
                  fontSize: 12, height: 1.5, color: Palette.inkFaint(context)),
            ),
          ],
        ],
      ),
    );
  }

  static String _sourceLabel(String s) => switch (s) {
        'wechat' => '微信账单',
        'alipay' => '支付宝账单',
        _ => '通用 CSV',
      };

  // 统一走 centsToText：预览里金额也要带千分位，和别处一致
  static String _yuan(int cents) => centsToText(cents, alwaysTwoDecimals: true);
}
