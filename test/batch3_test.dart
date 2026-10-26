import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/bill_csv.dart';

/// 第 3 批回归：账单导入的两个「算错账」入口。
void main() {
  group('账单 CSV 日期校验', () {
    const header = '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态\n';

    test('2 月 31 日必须跳过（不能被 DateTime 静默滚到 3 月 3 日）', () {
      final r = parseBillCsv(
        '$header'
        '2026-02-31 10:00:00,商户消费,某店,午饭,支出,35.00,零钱,支付成功\n'
        '2026-02-28 10:00:00,商户消费,某店,晚饭,支出,20.00,零钱,支付成功\n',
      );
      // 旧实现：DateTime(2026, 2, 31) → 2026-03-03，这笔账会跑进 3 月统计
      expect(r.rows.length, 1, reason: '只有 2/28 那条合法');
      expect(r.skipped, 1);
      expect(r.rows.single.day, DateTime(2026, 2, 28));
    });

    test('闰年 2 月 29 日合法', () {
      final r = parseBillCsv(
        '$header'
        '2024-02-29 10:00:00,商户消费,某店,午饭,支出,35.00,零钱,支付成功\n',
      );
      expect(r.rows.length, 1);
      expect(r.rows.single.day, DateTime(2024, 2, 29));
    });

    test('4 月 31 日也跳过（小月）', () {
      final r = parseBillCsv(
        '$header'
        '2026-04-31 10:00:00,商户消费,某店,午饭,支出,35.00,零钱,支付成功\n'
        '2026-04-30 10:00:00,商户消费,某店,晚饭,支出,20.00,零钱,支付成功\n',
      );
      expect(r.rows.length, 1);
      expect(r.rows.single.day, DateTime(2026, 4, 30));
    });
  });

  group('账单 CSV 金额解析', () {
    const header = '交易时间,交易类型,交易对方,商品,收/支,金额(元),支付方式,当前状态\n';

    test('两位小数按分精确落库', () {
      final r = parseBillCsv(
        '$header'
        '2026-10-01 10:00:00,商户消费,某店,a,支出,1234.56,零钱,支付成功\n'
        '2026-10-02 10:00:00,商户消费,某店,b,支出,0.29,零钱,支付成功\n'
        '2026-10-03 10:00:00,商户消费,某店,c,支出,1.15,零钱,支付成功\n',
      );
      expect(r.rows.map((e) => e.cents).toList(), [123456, 29, 115]);
    });

    test('千分位逗号与货币符号都能容错', () {
      final r = parseBillCsv(
        '$header'
        '2026-10-01 10:00:00,商户消费,某店,a,支出,"¥1,234.50",零钱,支付成功\n',
      );
      expect(r.rows.single.cents, 123450);
    });
  });
}
