// URL Scheme 解析器回归用例。
// 覆盖：正常链、金额边界、flow/date/auto 校验、非 jianji 链接、
// 非法参数整体作废 vs 可选参数容错的边界。
import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/scheme.dart';

void main() {
  group('parseScheme · add', () {
    test('最短合法链：只有金额', () {
      final c = parseScheme('jianji://add?money=25')!;
      expect(c.action, 'add');
      final d = c.draft!;
      expect(d.amountCents, 2500);
      expect(d.flow, 'out');
      expect(d.auto, isFalse);
      expect(d.day, isNull);
      expect(d.memo, isEmpty);
      expect(d.amountText, '25');
    });

    test('全参数链', () {
      final c = parseScheme(
        'jianji://add?money=25.5&note=午饭&bucket=食&pocket=微信'
        '&flow=in&date=2026-11-09&auto=1',
      )!;
      final d = c.draft!;
      expect(d.amountCents, 2550);
      expect(d.flow, 'in');
      expect(d.memo, '午饭');
      expect(d.bucketName, '食');
      expect(d.pocketName, '微信');
      expect(d.day, DateTime(2026, 11, 9));
      expect(d.auto, isTrue);
    });

    test('金额容错：¥ 前缀 / 两位小数截断到分', () {
      expect(
        (parseScheme('jianji://add?money=%C2%A525')!)
            .draft!
            .amountCents,
        2500,
      );
      expect(
        (parseScheme('jianji://add?money=0.99')!)
            .draft!
            .amountCents,
        99,
      );
    });

    test('auto 也接受 true（大小写不敏感）', () {
      expect(
        (parseScheme('jianji://add?money=1&auto=TRUE')!)
            .draft!
            .auto,
        isTrue,
      );
      expect(
        (parseScheme('jianji://add?money=1&auto=yes')!)
            .draft!
            .auto,
        isFalse,
      );
    });

    test('note 与 memo 等价', () {
      expect(
        (parseScheme('jianji://add?money=1&memo=打车')!)
            .draft!
            .memo,
        '打车',
      );
    });
  });

  group('parseScheme · 整条作废（硬参数非法）', () {
    for (final bad in [
      // 裸 add（一个参数都没有）= 开空编辑器，见「三斜杠路径式」组
      'jianji://add?money=', // 空
      'jianji://add?money=0', // 零
      'jianji://add?money=-5', // 负数
      'jianji://add?money=abc', // 非数字
      'jianji://add?money=1&flow=transfer', // 转账不开放
      'jianji://add?money=1&flow=xx', // 未知流向
    ]) {
      test('作废: $bad', () => expect(parseScheme(bad), isNull));
    }
  });

  group('parseScheme · 可选参数容错（不整条作废）', () {
    test('date 非法 → 当没传（今天）', () {
      final d =
          (parseScheme('jianji://add?money=1&date=2026-13-40')!)
              .draft!;
      expect(d.day, isNull);
      expect(d.amountCents, 100);
    });
    test('date 合法边界', () {
      final d =
          parseScheme('jianji://add?money=1&date=2024-02-29')!.draft!;
      expect(d.day, DateTime(2024, 2, 29));
    });
    test('空名字参数当没传', () {
      final d =
          parseScheme('jianji://add?money=1&bucket=&pocket=')!.draft!;
      expect(d.bucketName, isNull);
      expect(d.pocketName, isNull);
    });
  });

  group('parseScheme · 其他', () {
    test('voice', () {
      final c = parseScheme('jianji://voice')!;
      expect(c.action, 'voice');
      expect(c.draft, isNull);
    });
    test('非 jianji 链接 / 未知 host / 垃圾输入 → null', () {
      expect(parseScheme('https://example.com/add?money=1'), isNull);
      expect(parseScheme('myapp://add?money=1'), isNull);
      expect(parseScheme('jianji://stats'), isNull);
      expect(parseScheme(''), isNull);
      expect(parseScheme(null), isNull);
      expect(parseScheme('   jianji://voice  ')!.action, 'voice');
    });
    test('解析异常输入不抛异常', () {
      expect(parseScheme('jianji://%zz'), isNull);
    });
  });

  group('parseScheme · 三斜杠路径式与引擎剥残体', () {
    test('三斜杠 voice / add', () {
      expect(parseScheme('jianji:///voice')!.action, 'voice');
      final c = parseScheme('jianji:///add?money=3&note=测试')!;
      expect(c.action, 'add');
      expect(c.draft!.amountCents, 300);
      expect(c.draft!.memo, '测试');
    });
    test('引擎剥掉 scheme 后的残体（热启动真实形态）', () {
      expect(parseScheme('/voice')!.action, 'voice');
      final c = parseScheme('/add?money=1.5')!;
      expect(c.action, 'add');
      expect(c.draft!.amountCents, 150);
      final c2 = parseScheme('/?money=2')!; // 旧式 authority 写法的残体
      expect(c2.action, 'add');
      expect(c2.draft!.amountCents, 200);
    });
    test('裸 add = 开空编辑器（金额 0）', () {
      final c = parseScheme('jianji:///add')!;
      expect(c.action, 'add');
      expect(c.draft!.amountCents, 0);
      final c2 = parseScheme('/add')!;
      expect(c2.action, 'add');
      expect(c2.draft!.amountCents, 0);
    });
    test('带 query 但 money 缺失仍整条作废（不猜意图）', () {
      expect(parseScheme('/add?note=只有备注'), isNull);
      expect(parseScheme('/?note=x'), isNull);
    });
    test('不认识的剥残体路径 → null', () {
      expect(parseScheme('/foo'), isNull);
      expect(parseScheme('/stats'), isNull);
    });
  });

  test('buildAddScheme ↔ parseScheme 回环', () {
    // ignore: prefer_const_constructors
    final d = SchemeAddDraft(
      amountCents: 2550,
      flow: 'in',
      memo: '红包',
      bucketName: '收入',
      day: DateTime(2026, 11, 9),
      auto: true,
    );
    final c = parseScheme(buildAddScheme(d))!;
    final back = c.draft!;
    expect(back.amountCents, 2550);
    expect(back.flow, 'in');
    expect(back.memo, '红包');
    expect(back.bucketName, '收入');
    expect(back.day, DateTime(2026, 11, 9));
    expect(back.auto, isTrue);
  });
}
