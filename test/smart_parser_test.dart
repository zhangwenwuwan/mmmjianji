import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/smart_parser.dart';

void main() {
  // 固定「现在」：2026-11-06 是周五，本周一 11-02、上周三 10-28。
  final now = DateTime(2026, 11, 6, 18, 0);
  const categories = [
    SmartCategory(id: 1, title: '食', flow: 'out'),
    SmartCategory(id: 2, title: '行', flow: 'out'),
    SmartCategory(id: 3, title: '住', flow: 'out'),
    SmartCategory(id: 4, title: '衣', flow: 'out'),
    SmartCategory(id: 5, title: '工资', flow: 'in'),
    SmartCategory(id: 6, title: '餐饮', flow: 'out'),
  ];
  const accounts = [
    SmartAccount(id: 11, title: '支付宝', alias: '阿宝'),
    SmartAccount(id: 12, title: '微信零钱', alias: '微信'),
    SmartAccount(id: 13, title: '招行银行卡', alias: '银行卡'),
  ];

  SmartContext ctx({
    Map<String, int> categoryHints = const {},
    Map<String, int> accountHints = const {},
  }) =>
      SmartContext(
        now: now,
        categories: categories,
        accounts: accounts,
        categoryHints: categoryHints,
        accountHints: accountHints,
      );

  group('金额', () {
    test('阿拉伯数字 + 元', () {
      final d = parseSmartText('今天午饭花了 35 元', ctx());
      expect(d.amountCents, 3500);
      expect(d.hasAmount, isTrue);
      expect(d.canSave, isTrue);
    });

    test('小数 + 块', () {
      final d = parseSmartText('昨天打车 23.5 块', ctx());
      expect(d.amountCents, 2350);
      expect(d.day, DateTime(2026, 11, 5));
    });

    test('中文数字 + 角：十二块五', () {
      expect(parseSmartText('早餐十二块五', ctx()).amountCents, 1250);
    });

    test('中文数字：十五块', () {
      expect(parseSmartText('十五块', ctx()).amountCents, 1500);
    });

    test('口语省略十：一百二元 = 120 元', () {
      expect(parseSmartText('一百二元 买菜', ctx()).amountCents, 12000);
    });

    test('¥ 前缀', () {
      expect(parseSmartText('¥12.5 咖啡', ctx()).amountCents, 1250);
    });

    test('毛/角', () {
      expect(parseSmartText('五毛', ctx()).amountCents, 50);
    });

    test('全角数字与全角标点', () {
      expect(parseSmartText('咖啡１２．５元', ctx()).amountCents, 1250);
    });

    test('没有单位时取孤立数字，但置信度更低', () {
      final bare = parseSmartText('早餐 15', ctx());
      final explicit = parseSmartText('早餐 15 元', ctx());
      expect(bare.amountCents, 1500);
      expect(bare.confidence, lessThan(explicit.confidence));
    });

    test('日期数字不能被当成金额', () {
      final d = parseSmartText('3月5日 房租 2000 元', ctx());
      expect(d.amountCents, 200000);
      expect(d.day, DateTime(2026, 3, 5));
    });
  });

  group('时间', () {
    test('今天 / 昨天 / 前天', () {
      expect(parseSmartText('今天 咖啡 20元', ctx()).day,
          DateTime(2026, 11, 6));
      expect(parseSmartText('昨天 咖啡 20元', ctx()).day,
          DateTime(2026, 11, 5));
      expect(parseSmartText('前天 咖啡 20元', ctx()).day,
          DateTime(2026, 11, 4));
    });

    test('完整年月日', () {
      expect(parseSmartText('2026年11月5日 买书 45元', ctx()).day,
          DateTime(2026, 11, 5));
    });

    test('上周三按周一为起点算', () {
      final d = parseSmartText('上周三 买菜 68', ctx());
      expect(d.day, DateTime(2026, 10, 28));
      expect(d.amountCents, 6800);
    });

    test('晚上 8 点要换算成 20:00', () {
      final d = parseSmartText('晚上8点吃饭 30 元', ctx());
      expect(d.timeMinutes, 20 * 60);
      expect(d.amountCents, 3000);
    });

    test('8:30', () {
      expect(parseSmartText('8:30 咖啡 20元', ctx()).timeMinutes,
          8 * 60 + 30);
    });
  });

  group('分类与账户', () {
    test('口语词映射到默认单字分类', () {
      expect(parseSmartText('午饭 35 元', ctx()).bucketId, 1);
      expect(parseSmartText('打车 23 元', ctx()).bucketId, 2);
      expect(parseSmartText('房租 2000 元', ctx()).bucketId, 3);
    });

    test('用户自定义分类名直接命中', () {
      expect(parseSmartText('餐饮 66 元', ctx()).bucketId, 6);
    });

    test('账户简称也能命中', () {
      final d = parseSmartText('微信 咖啡 20元', ctx());
      expect(d.pocketId, 12);
      expect(d.bucketId, 1);
    });

    test('未知说法不硬猜分类，留给用户补', () {
      final d = parseSmartText('星巴克 38 元', ctx());
      expect(d.bucketId, isNull);
      expect(d.missing, contains('分类'));
      expect(d.keyword, '星巴克');
    });

    test('记忆表命中优先于词典', () {
      final d = parseSmartText(
          '星巴克 38 元', ctx(categoryHints: {'星巴克': 6}));
      expect(d.bucketId, 6);
      expect(d.keyword, '星巴克');
    });
  });

  group('转账与收入', () {
    test('A 转到 B：连接词前后分别取账户', () {
      final d = parseSmartText('支付宝转到微信 15 元', ctx());
      expect(d.flow, 'transfer');
      expect(d.pocketId, 11);
      expect(d.toPocketId, 12);
      expect(d.bucketId, isNull);
      expect(d.canSave, isTrue);
    });

    test('单字「转」按出现顺序取两个账户', () {
      final d = parseSmartText('微信转银行卡 100 块', ctx());
      expect(d.flow, 'transfer');
      expect(d.pocketId, 12);
      expect(d.toPocketId, 13);
    });

    test('缺转出账户时不能把目标账户当成转出', () {
      final d = parseSmartText('转到微信 15 元', ctx());
      expect(d.pocketId, isNull);
      expect(d.toPocketId, 12);
      expect(d.missing, contains('转出账户'));
      expect(d.canSave, isFalse);
    });

    test('工资识别为收入，用收入侧分类', () {
      final d = parseSmartText('工资 8000 元', ctx());
      expect(d.flow, 'in');
      expect(d.bucketId, 5);
    });
  });

  group('缺省与边界', () {
    test('空文本', () {
      final d = parseSmartText('', ctx());
      expect(d.hasAmount, isFalse);
      expect(d.canSave, isFalse);
      expect(d.missing, contains('金额'));
    });

    test('没有数字时金额为空', () {
      final d = parseSmartText('今天天气不错', ctx());
      expect(d.amountCents, isNull);
      expect(d.missing, contains('金额'));
    });

    test('备注不会把整句金额留下来', () {
      final d = parseSmartText('星巴克 38 元', ctx());
      expect(d.memo, isNot(contains('38')));
    });

    test('notes 里能看出解析依据', () {
      final d = parseSmartText('昨天打车 23.5 块', ctx());
      expect(d.notes.join(' '), contains('时间'));
      expect(d.notes.join(' '), contains('金额'));
    });
  });
}
