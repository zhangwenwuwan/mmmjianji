import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/due_reminders.dart';
import 'package:jianji/data/store.dart';

/// 到期提醒纯逻辑测试。
///
/// buildDueReminders 不碰 Flutter / 插件，只把"某天该干嘛"算成一组 DueReminder，
/// 这部分算错会让用户漏掉信用卡还款（上征信），所以逐场景对齐。
void main() {
  group('nextMonthlyOccurrences', () {
    test('月末不跨月：2 月 31 号退回 2/28，普通月 31 号正常', () {
      // from=2/1：2 月没有 31 号 → 退回 2/28（_safeDay 兜底，不能顺延成 3 月）；
      // 3/31 距 2/1 是 58 天，落在 60 天窗口内 → 正常保留。
      final from = DateTime(2026, 2, 1);
      final occ = nextMonthlyOccurrences(31, from, withinDays: 60);
      expect(occ, [DateTime(2026, 2,28), DateTime(2026, 3, 31)]);
    });

    test('普通月份正常推进', () {
      final from = DateTime(2026, 1, 15);
      final occ = nextMonthlyOccurrences(10, from, withinDays: 45);
      // 1/10 已过；2/10 距 1/15 约 26 天；3/10 约 54 天（>45 排除）
      expect(occ, [DateTime(2026, 2, 10)]);
    });
  });

  group('nextOneTimeOccurrence', () {
    test('窗口外返回 null，窗口内返回零点归一化的日期', () {
      final from = DateTime(2026, 1, 1);
      expect(nextOneTimeOccurrence(DateTime(2026, 3, 1), from, withinDays: 30), isNull);
      expect(
        nextOneTimeOccurrence(DateTime(2026, 1, 15, 23, 59), from, withinDays: 30),
        DateTime(2026, 1, 15),
      );
    });
  });

  group('buildDueReminders', () {
    final now = DateTime(2026, 1, 1);

    test('四类都识别，且 card_bill 的 entityId 与 card_pay 错开', () {
      final pockets = [
        Pocket(
          id: 1,
          bookId: 1,
          title: '招行',
          glyph: '',
          kind: PocketKind.credit,
          currency: 'CNY',
          openingCents: 0,
          archived: false,
          paymentDueDay: 5,
          billingDay: 20,
        ),
      ];
      final goals = [
        Goal(
          id: 2,
          bookId: 1,
          title: '旅费',
          glyph: '',
          targetCents: 100000,
          savedCents: 0,
          dueDay: DateTime(2026, 1, 20),
        ),
      ];
      final debts = [
        Debt(
          id: 3,
          bookId: 1,
          direction: 'lend',
          counterparty: '小王',
          channel: 'bank',
          principalCents: 50000,
          currency: 'CNY',
          borrowedOn: DateTime(2025, 1, 1),
          dueOn: DateTime(2026, 2, 1),
          note: '',
          interestRate: null,
          closed: false,
        ),
      ];

      final rs = buildDueReminders(pockets, goals, debts,
          now: now, leadDays: 3, symbol: '¥');
      final kinds = rs.map((e) => e.kind).toSet();
      expect(kinds, contains('card_pay'));
      expect(kinds, contains('card_bill'));
      expect(kinds, contains('goal'));
      expect(kinds, contains('debt'));

      final pay = rs.firstWhere((e) => e.kind == 'card_pay');
      final bill = rs.firstWhere((e) => e.kind == 'card_bill');
      // 账单日通知必须和还款日通知用不同 entityId，否则通知 id 会撞车。
      expect(bill.entityId, pay.entityId + 100000);
    });

    test('没有还款日/账单日的账户不产生 card 提醒', () {
      final pockets = [
        Pocket(
          id: 1,
          bookId: 1,
          title: '现金',
          glyph: '',
          kind: PocketKind.cash,
          currency: 'CNY',
          openingCents: 0,
          archived: false,
        ),
      ];
      final rs = buildDueReminders(pockets, const [], const [],
          now: now, leadDays: 3, symbol: '¥');
      expect(rs.where((e) => e.kind.startsWith('card_')), isEmpty);
    });

    test('金额按币种符号格式化', () {
      final goals = [
        Goal(
          id: 1,
          bookId: 1,
          title: 'x',
          glyph: '',
          targetCents: 100000,
          savedCents: 0,
          dueDay: DateTime(2026, 2, 1),
        ),
      ];
      final rs = buildDueReminders(const [], goals, const [],
          now: now, leadDays: 3, symbol: '¥');
      expect(rs.first.body, contains('¥1000'));
    });

    test('借还款方向区分标题', () {
      final lend = [
        Debt(
          id: 1,
          bookId: 1,
          direction: 'lend',
          counterparty: 'A',
          channel: 'bank',
          principalCents: 100,
          currency: 'CNY',
          borrowedOn: DateTime(2025, 1, 1),
          dueOn: DateTime(2026, 2, 1),
          note: '',
          interestRate: null,
          closed: false,
        ),
      ];
      final borrow = [
        Debt(
          id: 2,
          bookId: 1,
          direction: 'borrow',
          counterparty: 'B',
          channel: 'bank',
          principalCents: 100,
          currency: 'CNY',
          borrowedOn: DateTime(2025, 1, 1),
          dueOn: DateTime(2026, 2, 1),
          note: '',
          interestRate: null,
          closed: false,
        ),
      ];
      final rLend = buildDueReminders(const [], const [], lend,
          now: now, leadDays: 3, symbol: '¥');
      final rBorrow = buildDueReminders(const [], const [], borrow,
          now: now, leadDays: 3, symbol: '¥');
      expect(rLend.first.title, '借出应收回');
      expect(rBorrow.first.title, '借款应归还');
    });
  });
}
