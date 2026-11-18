import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/glyphs.dart';
import 'package:jianji/core/pocket_types.dart';
import 'package:jianji/data/store.dart';
import 'package:jianji/ui/sankey.dart';

/// 桑基图 + 账户类型预设的回归测试。
///
/// 桑基图是纯自绘（CustomPainter），布局算错不会抛异常、只会画歪，
/// 所以这里守的是「**不能崩**」这条底线：
/// - 分类多到要合并「其他」；
/// - 只有支出没有收入（左边得补一个「存款补足」，否则流量对不上）；
/// - 金额全为 0 / 只有 1 个节点 / 极端宽度。
void main() {
  Widget wrap(Widget child, {double width = 340}) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, child: child),
          ),
        ),
      );

  const sources = [
    (label: '工资', glyph: '💰', cents: 900000),
    (label: '兼职', glyph: '🧑‍💻', cents: 120000),
  ];
  const sinks = [
    (label: '餐饮', glyph: '🍜', cents: 340000),
    (label: '交通', glyph: '🚌', cents: 60000),
    (label: '结余', glyph: '🐷', cents: 620000),
  ];

  testWidgets('有收支时能画出来，点节点高亮不崩', (tester) async {
    await tester.pumpWidget(wrap(
      const SankeyChart(sources: sources, sinks: sinks, symbol: '¥'),
    ));
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);

    // 点左列第一个节点（工资）→ 高亮；再点一次取消
    await tester.tapAt(const Offset(60, 30));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    await tester.tapAt(const Offset(60, 30));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('节点很多时不会溢出（会合并成「其他」）', (tester) async {
    final many = [
      for (var i = 0; i < 9; i++)
        (label: '分类$i', glyph: '🍜', cents: 10000 * (i + 1)),
    ];
    await tester.pumpWidget(wrap(
      SankeyChart(sources: many, sinks: many, symbol: '¥'),
      width: 300,
    ));
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('只有支出、没有收入时也能画（左边是存款补足）', (tester) async {
    await tester.pumpWidget(wrap(
      const SankeyChart(
        sources: [(label: '存款补足', glyph: '🏦', cents: 50000)],
        sinks: [(label: '餐饮', glyph: '🍜', cents: 50000)],
        symbol: '¥',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);
  });

  testWidgets('金额为 0 不除以零', (tester) async {
    await tester.pumpWidget(wrap(
      const SankeyChart(
        sources: [(label: '工资', glyph: '💰', cents: 0)],
        sinks: [(label: '餐饮', glyph: '🍜', cents: 0)],
        symbol: '¥',
      ),
    ));
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);
  });

  group('账户类型预设', () {
    test('id 唯一、分组有效、都挂在合法的 kind 上', () {
      final ids = <String>{};
      for (final t in kPocketTypes) {
        expect(ids.add(t.id), isTrue, reason: '类型 id 重复：${t.id}');
        expect(kPocketTypeGroups, contains(t.group));
        expect(t.label.isNotEmpty, isTrue);
        expect(t.glyph.isNotEmpty, isTrue);
      }
      // 1.4.73 起类型表**只留「选择类型」里点得到的**那 11 个 ——
      // 多一个就是「有类型却选不到」的孤儿，且必然只能靠 emoji 撑着。
      final choosable = [
        for (final g in kAccountChooserGroups) ...g.$2,
      ];
      expect(kPocketTypes.map((t) => t.id).toSet(), choosable.toSet());
      expect(choosable.length, kAccountGlyphIds.length);
    });

    test('每个类型都有插画，一个 emoji 都不剩', () {
      for (final t in kPocketTypes) {
        expect(Glyphs.isIcon(t.glyph), isTrue,
            reason: '${t.label}（${t.id}）还在用 emoji「${t.glyph}」');
        expect(kAccountGlyphIds, contains(Glyphs.idOf(t.glyph)));
      }
    });

    test('支付宝/微信是资产类，花呗/白条是信用类', () {
      expect(pocketTypeOf('alipay')!.kind, PocketKind.bank);
      expect(pocketTypeOf('wechatWallet')!.kind, PocketKind.bank);
      expect(pocketTypeOf('huabei')!.kind, PocketKind.credit);
      expect(pocketTypeOf('baitiaoPlain')!.kind, PocketKind.credit);
      expect(pocketTypeOf('huabei')!.kind.isLiability, isTrue);
      expect(pocketTypeOf('') , isNull);
      expect(pocketTypeOf('不存在'), isNull);
      // 精简掉的类型必须真没了（老账户由 DB v27 归一）
      expect(pocketTypeOf('mortgage'), isNull);
      expect(pocketTypeOf('stock'), isNull);
      expect(pocketTypeOf('wechat'), isNull);
    });

    test('老账户按 kind + 图标反推预设', () {
      expect(guessPocketType(PocketKind.bank, '🏦')!.id, 'bankcard');
      expect(guessPocketType(PocketKind.cash, '💵')!.id, 'cash');
      // 图标对不上时退回同类的第一个（现金）
      expect(guessPocketType(PocketKind.cash, '🙈')!.kind, PocketKind.cash);
    });
  });
}
