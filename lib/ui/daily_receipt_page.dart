import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/currency.dart';
import '../core/rules.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'app_glyph.dart';
import 'common.dart';
import 'theme.dart';

/// 小票上的一行（已折算成主币种分）。
typedef _Line = ({
  int? timeMinutes,
  String title,
  String account,
  String glyph,
  int cents,
  bool isIncome,
  bool isTransfer,
  bool hasSplit,
});

class _Receipt {
  const _Receipt({
    required this.day,
    required this.lines,
    required this.expenseCents,
    required this.incomeCents,
    required this.aaPendingCents,
  });

  final DateTime day;
  final List<_Line> lines;
  final int expenseCents;
  final int incomeCents;
  final int aaPendingCents;

  int get netCents => incomeCents - expenseCents;
  String get no => 'NO.${_ymd(day)}-${lines.length.toString().padLeft(2, '0')}';
}

String _ymd(DateTime d) =>
    '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

String _hm(int? m) {
  if (m == null) return '--:--';
  return '${(m ~/ 60).toString().padLeft(2, '0')}:'
      '${(m % 60).toString().padLeft(2, '0')}';
}

/// 每日小票：把一天的流水排成一张可分享的纸质小票。
///
/// 与「账单分享」（整月长图）的分工：
/// - 账单分享：给家人看完整明细，信息密度高；
/// - 每日小票：一天一张、可当打卡发，信息克制，追求"像一张真凭证"。
///
/// 口径：明细金额是**实付全额**（垫付了多少钱），AA 同时单独写一行待收，
/// 不把别人的份额偷偷减掉 —— 小票是"我花了多少"的凭证。
class DailyReceiptPage extends ConsumerStatefulWidget {
  const DailyReceiptPage({super.key, required this.day});

  final DateTime day;

  @override
  ConsumerState<DailyReceiptPage> createState() => _DailyReceiptPageState();
}

class _DailyReceiptPageState extends ConsumerState<DailyReceiptPage> {
  final _paperKey = GlobalKey();
  late DateTime _day;
  Future<_Receipt>? _future;

  @override
  void initState() {
    super.initState();
    _day = DateTime(widget.day.year, widget.day.month, widget.day.day);
    _future = _load();
  }

  Future<_Receipt> _load() async {
    final store = await ref.read(storeProvider.future);
    final book = await ref.read(activeBookProvider.future);
    final rates = await store.rates(book.id);
    final pockets = await store.allPockets();
    final currencyOf = {for (final p in pockets) p.id: p.currency};
    final pocketName = {for (final p in pockets) p.id: p.displayName};
    // 必须同时取「支出 + 收入」两类：收入流水挂在 in 分类下，
    // 只查 out 会让每一笔收入都掉进「未分类」。
    final outBuckets =
        await store.buckets(book.id, 'out', includeArchived: true);
    final inBuckets =
        await store.buckets(book.id, 'in', includeArchived: true);
    final bucketName = {
      for (final b in [...outBuckets, ...inBuckets]) b.id: b.title,
    };
    final bucketGlyph = {
      for (final b in [...outBuckets, ...inBuckets]) b.id: b.glyph,
    };
    final entries = await store.entriesOfDay(book.id, _day);

    var expense = 0;
    var income = 0;
    var aaPending = 0;
    final lines = <_Line>[];
    for (final e in entries) {
      if (e.deletedAt != null) continue;
      if (e.excludeFromStats) continue;
      final isTransfer = e.isTransfer;
      final from = e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency;
      // 小票用实付全额（不是「我的消费」口径），否则付了 52 显示 26 会更让人困惑。
      final base = isTransfer
          ? 0
          : toBaseCents(e.amountCents, from, book.baseCurrency, rates);
      if (!isTransfer) {
        if (e.flow == 'in') {
          income += base;
        } else {
          expense += base;
          if (e.splitCents > 0) {
            aaPending += toBaseCents(
                e.splitCents, from, book.baseCurrency, rates);
          }
        }
      }
      final fromName = pocketName[e.pocketId] ?? '账户';
      lines.add((
        timeMinutes: e.timeMinutes,
        glyph: isTransfer
            ? '🔄'
            : (bucketGlyph[e.bucketId] ?? (e.flow == 'in' ? '💰' : '🧾')),
        title: isTransfer
            ? '$fromName → ${pocketName[e.toPocketId] ?? '账户'}'
            : (e.memo.trim().isNotEmpty
                ? e.memo.trim()
                : (bucketName[e.bucketId] ?? '未分类')),
        account: isTransfer
            ? '账户间转账'
            : [
                bucketName[e.bucketId] ?? '未分类',
                if (fromName.trim().isNotEmpty) fromName.trim(),
              ].join(' · '),
        cents: base,
        isIncome: e.flow == 'in',
        isTransfer: isTransfer,
        hasSplit: e.splitCents > 0,
      ));
    }
    lines.sort((a, b) {
      final ta = a.timeMinutes;
      final tb = b.timeMinutes;
      if (ta == null && tb == null) return 0;
      if (ta == null) return 1;
      if (tb == null) return -1;
      return ta.compareTo(tb);
    });
    return _Receipt(
      day: _day,
      lines: lines,
      expenseCents: expense,
      incomeCents: income,
      aaPendingCents: aaPending,
    );
  }

  void _shift(int delta) {
    setState(() {
      _day = DateTime(_day.year, _day.month, _day.day + delta);
      _future = _load();
    });
  }

  Future<void> _share() async {
    try {
      final boundary = _paperKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 2.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) return;
      await Share.shareXFiles([
        XFile.fromData(Uint8List.view(bytes.buffer),
            mimeType: 'image/png', name: '简记-小票-${_ymd(_day)}.png'),
      ], text: '简记 · ${_day.month} 月 ${_day.day} 日小票');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).toast('分享失败，可先截图保存');
    }
  }

  @override
  Widget build(BuildContext context) {
    final hide = ref.watch(settingsProvider).hideAmounts;
    return Scaffold(
      appBar: AppBar(
        title: const Text('每日小票'),
        actions: [
          IconButton(
            tooltip: '分享小票',
            onPressed: _share,
            icon: const Icon(Icons.ios_share),
          ),
        ],
      ),
      body: FutureBuilder<_Receipt>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final r = snap.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 28),
            children: [
              // 翻日期的控件放在纸外面，否则会被画进分享图
              Row(
                children: [
                  IconButton(
                    tooltip: '前一天',
                    onPressed: () => _shift(-1),
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Text(
                      '${r.day.year} 年 ${r.day.month} 月 ${r.day.day} 日',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 13, color: Palette.inkSoft(context)),
                    ),
                  ),
                  IconButton(
                    tooltip: '后一天',
                    onPressed: () => _shift(1),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              if (r.lines.isEmpty)
                _EmptyPaper(day: r.day)
              else
                RepaintBoundary(
                  key: _paperKey,
                  child: _Paper(receipt: r, hideAmounts: hide),
                ),
              const SizedBox(height: 10),
              Text(
                '长按或点右上角「分享」保存成图片；数据只存在这台手机上。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Palette.inkFaint(context)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyPaper extends StatelessWidget {
  const _EmptyPaper({required this.day});
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        children: [
          Icon(Icons.receipt_long_outlined,
              size: 40, color: Palette.inkFaint(context)),
          const SizedBox(height: 12),
          Text('${day.month} 月 ${day.day} 日还没有记录',
              style: TextStyle(fontSize: 13, color: Palette.inkSoft(context))),
          const SizedBox(height: 4),
          Text('记一笔之后，这张小票就会自己长出来',
              style: TextStyle(fontSize: 11, color: Palette.inkFaint(context))),
        ],
      ),
    );
  }
}

/// 纸面：锯齿边 + 白色纸 + 内容。
class _Paper extends StatelessWidget {
  const _Paper({required this.receipt, required this.hideAmounts});

  final _Receipt receipt;
  final bool hideAmounts;

  String _money(int cents) =>
      hideAmounts ? '****' : centsToText(cents).replaceFirst('-', '');

  @override
  Widget build(BuildContext context) {
    final ink = const Color(0xFF2C2A24);
    final faint = const Color(0xFFA8A296);
    final line = const Color(0xFFDDD7C9);
    final r = receipt;
    return ClipPath(
      clipper: const _ReceiptClipper(tooth: 11),
      child: Container(
        color: const Color(0xFFFFFDF8),
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                color: Color(0xFFE8F3EE),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.receipt_long,
                  size: 22, color: Color(0xFF12795C)),
            ),
            const SizedBox(height: 10),
            Text('每日小票',
                style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w600,
                    color: ink,
                    letterSpacing: 2)),
            const SizedBox(height: 4),
            Text('DAILY RECEIPT',
                style: TextStyle(
                    fontSize: 9.5, color: faint, letterSpacing: 3.2)),
            const SizedBox(height: 16),
            _dash(line),
            const SizedBox(height: 12),
            _meta('编号', r.no, faint, ink),
            _meta('账单日期',
                '${r.day.year}-${r.day.month.toString().padLeft(2, '0')}-${r.day.day.toString().padLeft(2, '0')}',
                faint, ink),
            _meta('笔数', '${r.lines.length} 笔', faint, ink),
            const SizedBox(height: 12),
            _dash(line),
            const SizedBox(height: 6),
            for (final l in r.lines) _lineRow(l, ink, faint),
            const SizedBox(height: 6),
            _dash(line),
            const SizedBox(height: 12),
            _total('当日总支出', '-¥${_money(r.expenseCents)}',
                const Color(0xFFC6473F), faint),
            const SizedBox(height: 6),
            _total('当日总收入', '+¥${_money(r.incomeCents)}',
                const Color(0xFF12795C), faint),
            if (r.aaPendingCents > 0) ...[
              const SizedBox(height: 6),
              _total('其中 AA 待收', '¥${_money(r.aaPendingCents)}', faint, faint),
            ],
            const SizedBox(height: 12),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFBE9E6),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Text('当日净结余',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: ink)),
                  const Spacer(),
                  Text('${r.netCents < 0 ? '-' : '+'}¥${_money(r.netCents)}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: r.netCents < 0
                            ? const Color(0xFFC6473F)
                            : const Color(0xFF12795C),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      )),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Align(
              alignment: Alignment.centerRight,
              child: CustomPaint(
                size: const Size(58, 58),
                painter: _SealPainter(color: const Color(0xFF12795C)),
              ),
            ),
            const SizedBox(height: 6),
            CustomPaint(
              size: const Size(132, 36),
              painter: _BarcodePainter(seed: r.day.day * 7919 + r.lines.length),
            ),
            const SizedBox(height: 4),
            Text('${r.day.year}.${r.day.month}.${r.day.day}',
                style: TextStyle(
                    fontSize: 10, color: faint, letterSpacing: 2.5)),
            const SizedBox(height: 10),
            Text('简记 · 数据只存在这台手机上',
                style: TextStyle(fontSize: 10, color: faint)),
          ],
        ),
      ),
    );
  }

  Widget _dash(Color c) => CustomPaint(
        size: const Size(double.infinity, 8),
        painter: _DashPainter(color: c),
      );

  Widget _meta(String k, String v, Color kc, Color vc) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2.5),
        child: Row(
          children: [
            Text(k, style: TextStyle(fontSize: 12, color: kc)),
            const Spacer(),
            Text(v, style: TextStyle(fontSize: 12, color: vc)),
          ],
        ),
      );

  Widget _lineRow(_Line l, Color ink, Color faint) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 38,
              child: Text(_hm(l.timeMinutes),
                  style: TextStyle(
                      fontSize: 10.5,
                      color: faint,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(l.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: ink)),
                      ),
                      if (l.hasSplit) ...[
                        const SizedBox(width: 5),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8F3EE),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: const Text('AA',
                              style: TextStyle(
                                  fontSize: 9, color: Color(0xFF12795C))),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      // 分类小图标：跟着副标题走，一眼能看出是餐饮/交通/返利。
                      AppGlyph(l.glyph, size: 11),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(l.account,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10.5, color: faint)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              l.isTransfer
                  ? '转账'
                  : '${l.isIncome ? '+' : '-'}${_money(l.cents)}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: l.isTransfer
                    ? faint
                    : (l.isIncome
                        ? const Color(0xFF12795C)
                        : const Color(0xFFC6473F)),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );

  Widget _total(String k, String v, Color vc, Color kc) => Row(
        children: [
          Text(k, style: TextStyle(fontSize: 12.5, color: kc)),
          const Spacer(),
          Text(v,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: vc,
                  fontFeatures: const [FontFeature.tabularFigures()])),
        ],
      );
}

class _ReceiptClipper extends CustomClipper<Path> {
  const _ReceiptClipper({this.tooth = 10});
  final double tooth;

  @override
  Path getClip(Size size) {
    const h = 9.0;
    final p = Path()..moveTo(0, h);
    for (var x = 0.0; x < size.width; x += tooth) {
      p.lineTo(x + tooth / 2, 0);
      p.lineTo(math.min(x + tooth, size.width), h);
    }
    p.lineTo(size.width, size.height - h);
    for (var x = size.width; x > 0; x -= tooth) {
      p.lineTo(math.max(x - tooth / 2, 0), size.height);
      p.lineTo(math.max(x - tooth, 0), size.height - h);
    }
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant _ReceiptClipper old) => old.tooth != tooth;
}

class _DashPainter extends CustomPainter {
  const _DashPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 4.0;
    const gap = 4.0;
    var x = 0.0;
    while (x < size.width) {
      canvas.drawLine(Offset(x, size.height / 2),
          Offset(math.min(x + dash, size.width), size.height / 2), paint);
      x += dash + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _DashPainter old) => old.color != color;
}

/// 印章：双圈 + 勾。纯装饰，但它是"这张票被认过了"的心理暗示。
class _SealPainter extends CustomPainter {
  const _SealPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 2;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    canvas.drawCircle(c, r, stroke);
    canvas.drawCircle(
        c,
        r - 5,
        Paint()
          ..color = color.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8);
    final tick = Path()
      ..moveTo(c.dx - 9, c.dy)
      ..lineTo(c.dx - 2, c.dy + 7)
      ..lineTo(c.dx + 10, c.dy - 8);
    canvas.drawPath(
        tick,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant _SealPainter old) => old.color != color;
}

/// 条形码：按日期种子生成确定性条纹。
/// 不追求可扫（真要能扫得引入 Code128 编码），但必须"看起来像真的"——
/// 随机到每张都不一样、同一张每次都一样。
class _BarcodePainter extends CustomPainter {
  const _BarcodePainter({required this.seed});
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFF3C3A33);
    var x = 0.0;
    var v = seed == 0 ? 1 : seed;
    while (x < size.width) {
      v = (v * 1103515245 + 12345) & 0x7fffffff;
      final w = 1.0 + (v % 3);
      final gap = 1.0 + ((v >> 5) % 3);
      canvas.drawRect(
          Rect.fromLTWH(x, 0, math.min(w, size.width - x), size.height), paint);
      x += w + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _BarcodePainter old) => old.seed != seed;
}
