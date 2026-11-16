import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/entry_guard.dart';
import 'package:jianji/data/store.dart';

/// 防手滑重复记账：只判断「刚刚保存的那一笔」，不碰金额口径。
/// 注意这里刻意不放行补记历史的流水（timeMinutes 为空），
/// 否则补昨天的账会把今天的同额记账误判成重复。

Entry _entry({
  required int id,
  required DateTime day,
  int? timeMinutes,
  int amountCents = 2550,
  String memo = '午饭',
  int pocketId = 1,
  String flow = 'out',
  DateTime? deletedAt,
}) =>
    Entry(
      id: id,
      bookId: 1,
      pocketId: pocketId,
      toPocketId: null,
      bucketId: 1,
      flow: flow,
      amountCents: amountCents,
      memo: memo,
      day: day,
      tags: '',
      reimburse: 0,
      timeMinutes: timeMinutes,
      deletedAt: deletedAt,
    );

void main() {
  final now = DateTime(2026, 11, 16, 12, 30, 30);

  test('同日 + 60 秒内 → 判重复', () {
    expect(
      isRecentDuplicate(
        candidate: _entry(
          id: 1,
          day: DateTime(2026, 11, 16),
          timeMinutes: 12 * 60 + 30,
        ),
        now: now,
      ),
      isTrue,
    );
  });

  test('分钟粒度：同一分钟内算重复，早于窗口就不算', () {
    final base = _entry(
      id: 1,
      day: DateTime(2026, 11, 16),
      timeMinutes: 12 * 60 + 30,
    );
    expect(isRecentDuplicate(candidate: base, now: now), isTrue);
    expect(
      isRecentDuplicate(
        candidate: base,
        now: now.add(const Duration(minutes: 2)),
      ),
      isFalse,
    );
  });

  test('补记历史（timeMinutes 为空）不拦今天的记账', () {
    expect(
      isRecentDuplicate(
        candidate: _entry(id: 2, day: DateTime(2026, 11, 15)),
        now: now,
      ),
      isFalse,
    );
  });

  test('不同日期不判重复', () {
    expect(
      isRecentDuplicate(
        candidate: _entry(
          id: 3,
          day: DateTime(2026, 11, 15),
          timeMinutes: 12 * 60 + 30,
        ),
        now: now,
      ),
      isFalse,
    );
  });

  test('已软删除的流水不判重复', () {
    expect(
      isRecentDuplicate(
        candidate: _entry(
          id: 4,
          day: DateTime(2026, 11, 16),
          timeMinutes: 12 * 60 + 30,
          deletedAt: DateTime(2026, 11, 16, 12, 30, 45),
        ),
        now: now,
      ),
      isFalse,
    );
  });

  test('时间在未来（时钟回拨等）不判重复', () {
    expect(
      isRecentDuplicate(
        candidate: _entry(
          id: 5,
          day: DateTime(2026, 11, 16),
          timeMinutes: 12 * 60 + 31,
        ),
        now: now,
      ),
      isFalse,
    );
  });

  test('anyRecentDuplicate：一命中即返回', () {
    expect(
      anyRecentDuplicate(
        candidates: [
          _entry(id: 6, day: DateTime(2026, 11, 16)),
          _entry(
            id: 7,
            day: DateTime(2026, 11, 16),
            timeMinutes: 12 * 60 + 30,
          ),
        ],
        now: now,
      ),
      isTrue,
    );
  });
}
