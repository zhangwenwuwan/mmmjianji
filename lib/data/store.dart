/// 本地存储 v2：sqflite + 手写 SQL。
///
/// v2 相比 v0.1 的变化（对应 0.2.0 的功能块）：
/// - 多账本：books 表；pockets/buckets/entries/goals/recurring 全部挂 book_id
/// - 多币种：账户带币种；rates 存「1 单位外币 = 多少主币」
/// - 转账：entries.flow 增加 'transfer'，to_pocket_id 记对方账户
/// - 信用卡/负债：pockets.kind（cash/bank/credit/debt），还款 = 转账到该账户
/// - 标签：entries.tags（逗号分隔，搜索用）
/// - 报销：entries.reimburse（0 无 / 1 待报销 / 2 已报销）
/// - 储蓄目标 / 周期记账模板：goals / recurring
///
/// 金额仍是整数分，全部存「账户自己的币种」；跨币种统计在 Dart 侧折算
/// （见 core/convert.dart），聚合 SQL 只做分组求和。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/rules.dart';

/// 账本
class Book {
  const Book(
      {required this.id,
      required this.title,
      required this.glyph,
      required this.baseCurrency});

  final int id;
  final String title;
  final String glyph;

  /// 主币种（ISO 代码）。统计都折算成它。
  final String baseCurrency;
}

enum PocketKind {
  cash('现金'),
  bank('银行卡'),
  credit('信用卡'),
  debt('负债');

  const PocketKind(this.label);
  final String label;

  /// 信用卡/负债的余额语义是「还欠多少」（正数=欠款）。
  bool get isLiability => this == credit || this == debt;

  String get dbValue => name;
  static PocketKind fromDb(String v) => switch (v) {
        'bank' => bank,
        'credit' => credit,
        'debt' => debt,
        _ => cash,
      };
}

class Pocket {
  const Pocket({
    required this.id,
    required this.bookId,
    required this.title,
    required this.glyph,
    required this.kind,
    required this.currency,
    required this.openingCents,
    required this.archived,
    this.creditLimitCents = 0,
    this.billingDay,
    this.paymentDueDay,
    this.alias = '',
    this.cardNo = '',
    this.typeId = '',
    this.note = '',
    this.includeInAssets = true,
    this.glyphDark = '',
    this.sharedLimit = false,
    this.billNextPeriod = false,
    this.annualFee = '无',
    this.incomeSync = '无',
    this.recordable = true,
    this.visibleBookIds = '',
    this.annualRate = 0,
    this.periods = 0,
    this.repaymentMethod = 0,
  });

  final int id;
  final int bookId;
  final String title;
  final String glyph;
  final PocketKind kind;
  final String currency;

  /// 期初余额（本账户币种的分）。信用卡/负债填「当前欠款」，之后还款=转入。
  final int openingCents;
  final bool archived;

  /// 信用额度（分），只有信用卡/负债有意义；0 表示没设
  final int creditLimitCents;

  /// 每月账单日（1-28）；null = 没设
  final int? billingDay;

  /// 每月还款日（1-28）；null = 没设
  final int? paymentDueDay;

  /// 简称（如「工资卡」「农行」）。留空 = 用 [title]。
  /// 多账户时列表里认「工资卡」比认「银行卡 2」快得多。
  final String alias;

  /// 卡号（仅个人备忘，不参与任何计算）。
  final String cardNo;

  /// 账户类型预设 id（见 core/pocket_types.dart），如 'alipay' / 'huabei'。
  /// 只影响展示（图标、文案），计算口径仍然只看 [kind]。
  final String typeId;

  /// 备注（账户级，仅个人备忘）。
  final String note;

  /// 是否计入总资产 / 净资产。false 时该账户不进资产页与净资产走势。
  final bool includeInAssets;

  /// 夜间模式图标（深色主题下用）；空 = 跟随日间图标 [glyph]。
  final String glyphDark;

  /// 额度共享（信贷账户）：与主卡共享同一信用额度。仅偏好标记，
  /// 共享额度的实际摊算尚未实现（需账单/额度子系统）。
  final bool sharedLimit;

  /// 出账日消费是否计入下一期账单。仅偏好标记。
  final bool billNextPeriod;

  /// 年费设置：'无' / '减免' / '有年费'。仅展示/偏好。
  final String annualFee;

  /// 收益同步：'无' / '每日' / '每月'。仅偏好标记（自动同步需云端，暂未实现）。
  final String incomeSync;

  /// 是否可被选择去记账。false 时该账户不出现在记账页的选账户列表。
  final bool recordable;

  /// 选择生效账本：逗号分隔的 book id；空 = 全部账本。
  /// 非空时，记账页的选账户列表只在当前账本命中时才显示该账户。
  final String visibleBookIds;

  /// 贷款年利率（百分比，例如 5.8 表示年利率 5.8%）。仅信贷/负债账户有意义。
  final double annualRate;

  /// 贷款期数（月）。0 表示未设置。
  final int periods;

  /// 还款方式：0 等额本息 / 1 等额本金 / 2 先息后本 / 3 一次性还本付息。
  final int repaymentMethod;

  /// 列表/选择器里该显示的名字：优先简称。
  String get displayName => alias.trim().isEmpty ? title : alias.trim();

  /// 可用额度（分）。⚠️ 必须传「当前余额」，不能用 [openingCents]：
  /// 期初只有开卡那天是对的，之后每刷一笔欠款都会变。
  int? availableFrom(int balanceCents) =>
      creditLimitCents <= 0 ? null : creditLimitCents - balanceCents;

  /// 距离下一个还款日还有几天（0 = 今天）。没设还款日返回 null。
  int? daysUntilPaymentDue([DateTime? now]) {
    final day = paymentDueDay;
    if (day == null || day <= 0) return null;
    final today = now ?? DateTime.now();
    final todayOnly = DateTime(today.year, today.month, today.day);
    var target = DateTime(today.year, today.month, day);
    if (target.isBefore(todayOnly)) {
      target = DateTime(today.year, today.month + 1, day);
    }
    return target.difference(todayOnly).inDays;
  }
}

class Bucket {
  const Bucket({
    required this.id,
    required this.bookId,
    required this.title,
    required this.glyph,
    required this.flow,
    required this.archived,
    this.parentId,
  });

  final int id;
  final int bookId;
  final String title;
  final String glyph;
  final String flow; // 'in' / 'out'
  final bool archived;

  /// 上级分类 id；null = 一级分类
  final int? parentId;

  bool get isTop => parentId == null;
}

class Entry {
  const Entry({
    required this.id,
    required this.bookId,
    required this.pocketId,
    required this.toPocketId,
    required this.bucketId,
    required this.flow,
    required this.amountCents,
    required this.memo,
    required this.day,
    required this.tags,
    required this.reimburse,
    this.mood = 0,
    this.feeCents = 0,
    this.discountCents = 0,
    this.excludeFromStats = false,
    this.excludeFromBudget = false,
    this.currency,
    this.toAmountCents,
    this.refundOfId,
    this.reimburseEntryId,
    this.deletedAt,
    this.adjustment = false,
  });

  final int id;
  final int bookId;

  /// 记账方账户（转账时是「转出方」）
  final int pocketId;

  /// 转入方账户，仅转账
  final int? toPocketId;
  final int? bucketId;

  /// 'out' / 'in' / 'transfer'
  final String flow;

  /// 金额（pocketId 账户币种的分）
  final int amountCents;
  final String memo;
  final DateTime day;

  /// 逗号分隔标签
  final String tags;

  /// 0 无 / 1 待报销 / 2 已报销
  final int reimburse;

  /// 情绪：0 未标 / 1 值 / 2 一般 / 3 后悔
  final int mood;

  /// 转账手续费（分），仅转账
  final int feeCents;

  /// 转账优惠/折扣（分），仅转账
  final int discountCents;

  /// 不计入收支统计（内部调账、代付等）。余额照算，只是不进合计/占比/趋势。
  final bool excludeFromStats;

  /// 不计入预算（预算已花不统计这一笔）
  final bool excludeFromBudget;

  /// 本笔币种；null = 跟随账户币种。非空时 amountCents 是这个币种的分。
  final String? currency;

  /// 转账到账金额（转入账户币种的分）；null = 与 amountCents 相同
  final int? toAmountCents;

  /// 退款关联的原始记录 id
  final int? refundOfId;

  /// 报销入账关联：标记「已报销」时自动记入的那笔收入流水的 id。
  ///
  /// 撤回报销要把它删掉（否则账户余额会多出一截），所以必须留个指针；
  /// 用 memo/tags 反查是不可靠的（用户会改备注）。
  final int? reimburseEntryId;

  /// 软删除时间；null = 正常在账。已删除的流水只出现在回收站。
  final DateTime? deletedAt;

  /// 余额校准流水（对账产生的差额调整）。
  ///
  /// 为什么要单列一个标记而不是靠 memo 判断：memo 可以被用户随手改掉，
  /// 一改「只看校准」就筛不出来；而且导出给别人时语义也该跟着走。
  final bool adjustment;

  /// 本笔实际币种（没有单独指定就跟随账户）
  String currencyWith(String pocketCurrency) => currency ?? pocketCurrency;

  /// 转账实际到账金额
  int toAmountOr(int fallback) => toAmountCents ?? fallback;

  bool get isExpense => flow == 'out';
  bool get isTransfer => flow == 'transfer';

  Entry copyWith({
    int? pocketId,
    int? toPocketId,
    int? bucketId,
    String? flow,
    int? amountCents,
    String? memo,
    DateTime? day,
    String? tags,
    int? reimburse,
    int? mood,
    int? feeCents,
    int? discountCents,
    bool? excludeFromStats,
    bool? excludeFromBudget,
    String? currency,
    int? toAmountCents,
    int? refundOfId,
    int? reimburseEntryId,
    DateTime? deletedAt,
    bool? adjustment,
    // 显式清除开关。
    // `x ?? this.x` 的写法没法把字段改成 null，而这三件事都需要写 null：
    //   ① 取消退款关联  ② 币种改回「跟随账户」  ③ 转账改回普通支出
    // 以前它们全都静默失效 —— 界面显示改了，库里还是旧值。
    bool clearToPocket = false,
    bool clearBucket = false,
    bool clearCurrency = false,
    bool clearToAmount = false,
    bool clearRefund = false,
  }) =>
      Entry(
        id: id,
        bookId: bookId,
        pocketId: pocketId ?? this.pocketId,
        toPocketId: clearToPocket ? null : (toPocketId ?? this.toPocketId),
        bucketId: clearBucket ? null : (bucketId ?? this.bucketId),
        flow: flow ?? this.flow,
        amountCents: amountCents ?? this.amountCents,
        memo: memo ?? this.memo,
        day: day ?? this.day,
        tags: tags ?? this.tags,
        reimburse: reimburse ?? this.reimburse,
        mood: mood ?? this.mood,
        feeCents: feeCents ?? this.feeCents,
        discountCents: discountCents ?? this.discountCents,
        excludeFromStats: excludeFromStats ?? this.excludeFromStats,
        excludeFromBudget: excludeFromBudget ?? this.excludeFromBudget,
        currency: clearCurrency ? null : (currency ?? this.currency),
        toAmountCents:
            clearToAmount ? null : (toAmountCents ?? this.toAmountCents),
        refundOfId: clearRefund ? null : (refundOfId ?? this.refundOfId),
        reimburseEntryId: reimburseEntryId ?? this.reimburseEntryId,
        deletedAt: deletedAt ?? this.deletedAt,
        adjustment: adjustment ?? this.adjustment,
      );
}

class Goal {
  const Goal({
    required this.id,
    required this.bookId,
    required this.title,
    required this.glyph,
    required this.targetCents,
    required this.savedCents,
    required this.dueDay,
  });

  final int id;
  final int bookId;
  final String title;
  final String glyph;
  final int targetCents;
  final int savedCents;
  final DateTime? dueDay;
}

class Recurring {
  const Recurring({
    required this.id,
    required this.bookId,
    required this.title,
    required this.bucketId,
    required this.pocketId,
    required this.flow,
    required this.amountCents,
    required this.dayOfMonth,
    required this.lastRunMonth,
    required this.enabled,
  });

  final int id;
  final int bookId;
  final String title;
  final int? bucketId;
  final int pocketId;
  final String flow; // 'in' / 'out'
  final int amountCents;

  /// 每月几号生成（1-28，避开月底歧义）
  final int dayOfMonth;

  /// 最后生成的月份（'2026-10'），没跑过是 ''
  final String lastRunMonth;
  final bool enabled;
}

/// 借贷：direction = lend（我借出去，别人欠我）/ borrow（我借进来，我欠别人）
class Debt {
  const Debt({
    required this.id,
    required this.bookId,
    required this.direction,
    required this.counterparty,
    required this.channel,
    required this.principalCents,
    required this.currency,
    required this.borrowedOn,
    required this.dueOn,
    required this.note,
    required this.interestRate,
    required this.closed,
  });

  final int id;
  final int bookId;
  final String direction;
  final String counterparty;
  final String channel; // bank / online / personal
  final int principalCents;
  final String currency;
  final DateTime borrowedOn;
  final DateTime? dueOn;
  final String note;
  final double? interestRate;
  final bool closed;

  bool get isLend => direction == 'lend';

  Debt copyWith({
    String? direction,
    String? counterparty,
    String? channel,
    int? principalCents,
    String? currency,
    DateTime? borrowedOn,
    DateTime? dueOn,
    String? note,
    double? interestRate,
    bool? closed,
    // 与 Entry.copyWith 同一套问题：null 被 `?? this.x` 吃掉，
    // 「编辑借贷 → 清掉到期日」永远清不掉。
    bool clearDueOn = false,
  }) =>
      Debt(
        id: id,
        bookId: bookId,
        direction: direction ?? this.direction,
        counterparty: counterparty ?? this.counterparty,
        channel: channel ?? this.channel,
        principalCents: principalCents ?? this.principalCents,
        currency: currency ?? this.currency,
        borrowedOn: borrowedOn ?? this.borrowedOn,
        dueOn: clearDueOn ? null : (dueOn ?? this.dueOn),
        note: note ?? this.note,
        interestRate: interestRate ?? this.interestRate,
        closed: closed ?? this.closed,
      );
}

class DebtPayment {
  const DebtPayment({
    required this.id,
    required this.debtId,
    required this.amountCents,
    required this.paidOn,
    required this.note,
  });

  final int id;
  final int debtId;
  final int amountCents;
  final DateTime paidOn;
  final String note;
}

class Wish {
  const Wish({
    required this.id,
    required this.bookId,
    required this.title,
    required this.glyph,
    required this.priceCents,
    required this.note,
    required this.coolDays,
    required this.createdOn,
    required this.status,
  });

  final int id;
  final int bookId;
  final String title;
  final String glyph;
  final int priceCents;
  final String note;
  final int coolDays;
  final DateTime createdOn;
  final String status; // waiting / bought / dropped

  /// 冷静期还剩几天（<= 0 表示可以决定了）
  int coolLeft(DateTime today) => coolDays - today.difference(createdOn).inDays;

  bool get isWaiting => status == 'waiting';

  Wish copyWith({
    String? title,
    String? glyph,
    int? priceCents,
    String? note,
    int? coolDays,
    String? status,
  }) =>
      Wish(
        id: id,
        bookId: bookId,
        title: title ?? this.title,
        glyph: glyph ?? this.glyph,
        priceCents: priceCents ?? this.priceCents,
        note: note ?? this.note,
        coolDays: coolDays ?? this.coolDays,
        createdOn: createdOn,
        status: status ?? this.status,
      );
}

class LedgerStore {
  LedgerStore._(this._db, {this.withSamplePockets = true});

  final Database _db;

  /// 要不要在空库里预置「现金 / 银行卡」两个示例账户。
  ///
  /// **简记 App 传 false**（2026-10-25 用户要求：新装 App 账户数为 0，
  /// 让用户自己建——预置的两个账户名字对不上真实账户，反而要先删再建）。
  /// 默认值保持 true 只为兼容既有测试与演示脚本：它们大量依赖
  /// `allPockets().first` 这样的默认账户，改默认值会让十几处测试同时红。
  final bool withSamplePockets;

  static const _version = 17;

  static Future<LedgerStore> open({
    String? path,
    bool withSamplePockets = true,
  }) async {
    final target = path ?? p.join(await getDatabasesPath(), 'jianji_ledger.db');
    final db = await openDatabase(
      target,
      version: _version,
      onCreate: (db, v) => _createSchema(db, v, to: _version),
      onUpgrade: (db, from, to) => _createSchema(db, from, to: to),
    );
    final store = LedgerStore._(db, withSamplePockets: withSamplePockets);
    await store._seedIfEmpty();
    // 开库时顺手修孤儿流水。
    // 统计类 SQL 都是 `JOIN pockets p ON p.id = e.pocket_id`（INNER JOIN），
    // 账户被删但账单还在时，这些行会被**整行吞掉** —— 首页算得到、
    // 分类占比/分类预算/环图算不到，于是出现「支出 200 但占比 0」。
    // 原来只有「数据管理」里一个手动按钮，用户根本想不起来点。
    for (final b in await store.books()) {
      await store.fixOrphans(b.id);
    }
    return store;
  }

  /// 解析 day 列。规范值是 'yyyy-MM-dd'，但外部导入/手改备份可能写成
  /// '2026-10-21T00:00:00.000' —— DateTime.parse 能过，
  /// 而「我的」页那里 split('-') 再 int.parse 就会抛，整页变 0 天。
  /// 统一只取前 10 位，一个入口一个行为。
  static DateTime parseDay(String raw) {
    final s = raw.length >= 10 ? raw.substring(0, 10) : raw;
    return DateTime.parse(s);
  }

  Future<void> close() => _db.close();

  // ------------------------------------------------------------ schema / 迁移

  /// from=1 时做增量迁移（补列 + 回填账本）；全新建库走同一份 v2 结构。
  static Future<void> _createSchema(Database db, int from,
      {required int to}) async {
    if (to < 2) return;

    await db.execute('''
      CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        glyph TEXT NOT NULL,
        base_currency TEXT NOT NULL DEFAULT 'CNY',
        rank INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS pockets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        glyph TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'cash',
        currency TEXT NOT NULL DEFAULT 'CNY',
        opening_cents INTEGER NOT NULL DEFAULT 0,
        rank INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        credit_limit_cents INTEGER NOT NULL DEFAULT 0,
        billing_day INTEGER,
        payment_due_day INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS buckets (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        glyph TEXT NOT NULL,
        flow TEXT NOT NULL,
        rank INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        parent_id INTEGER
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL DEFAULT 1,
        pocket_id INTEGER NOT NULL,
        to_pocket_id INTEGER,
        bucket_id INTEGER,
        flow TEXT NOT NULL,
        amount_cents INTEGER NOT NULL,
        memo TEXT NOT NULL DEFAULT '',
        day TEXT NOT NULL,
        tags TEXT NOT NULL DEFAULT '',
        reimburse INTEGER NOT NULL DEFAULT 0,
        mood INTEGER NOT NULL DEFAULT 0,
        fee_cents INTEGER NOT NULL DEFAULT 0,
        discount_cents INTEGER NOT NULL DEFAULT 0,
        exclude_from_stats INTEGER NOT NULL DEFAULT 0,
        exclude_from_budget INTEGER NOT NULL DEFAULT 0,
        currency TEXT,
        to_amount_cents INTEGER,
        refund_of_id INTEGER,
        deleted_at TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS monthly_budgets (
        month TEXT NOT NULL,
        book_id INTEGER NOT NULL DEFAULT 1,
        amount_cents INTEGER NOT NULL,
        PRIMARY KEY (month, book_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS rates (
        book_id INTEGER NOT NULL,
        code TEXT NOT NULL,
        rate REAL NOT NULL,
        PRIMARY KEY (book_id, code)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS goals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        glyph TEXT NOT NULL DEFAULT '🎯',
        target_cents INTEGER NOT NULL,
        saved_cents INTEGER NOT NULL DEFAULT 0,
        due_day TEXT,
        rank INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS debts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        direction TEXT NOT NULL,           -- lend(我借出) / borrow(我借入)
        counterparty TEXT NOT NULL,
        channel TEXT NOT NULL DEFAULT 'personal',
        principal_cents INTEGER NOT NULL,
        currency TEXT NOT NULL DEFAULT 'CNY',
        borrowed_on TEXT NOT NULL,
        due_on TEXT,
        note TEXT NOT NULL DEFAULT '',
        interest_rate REAL,
        closed INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS debt_payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        debt_id INTEGER NOT NULL,
        amount_cents INTEGER NOT NULL,
        paid_on TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS wishes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        glyph TEXT NOT NULL DEFAULT '🎁',
        price_cents INTEGER NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        cool_days INTEGER NOT NULL DEFAULT 7,
        created_on TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'waiting'   -- waiting / bought / dropped
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bucket_budgets (
        book_id INTEGER NOT NULL,
        month TEXT NOT NULL,
        bucket_id INTEGER NOT NULL,
        amount_cents INTEGER NOT NULL,
        PRIMARY KEY (book_id, month, bucket_id)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS recurring (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL,
        title TEXT NOT NULL,
        bucket_id INTEGER,
        pocket_id INTEGER NOT NULL,
        flow TEXT NOT NULL,
        amount_cents INTEGER NOT NULL,
        day_of_month INTEGER NOT NULL,
        last_run_month TEXT NOT NULL DEFAULT '',
        enabled INTEGER NOT NULL DEFAULT 1
      )
    ''');

    if (from == 1) {
      // v1 没有 books：先建默认账本，再给老表补列、回填 book_id。
      final bookCount = Sqflite.firstIntValue(
              await db.rawQuery('SELECT COUNT(*) FROM books')) ??
          0;
      if (bookCount == 0) {
        await db.insert('books', {
          'title': '默认账本',
          'glyph': '📒',
          'base_currency': 'CNY',
          'rank': 0
        });
      }
      final bookId = Sqflite.firstIntValue(
              await db.rawQuery('SELECT MIN(id) FROM books')) ??
          1;
      await _addColumnIfMissing(
          db, 'pockets', 'book_id', 'INTEGER NOT NULL DEFAULT 1');
      await _addColumnIfMissing(
          db, 'buckets', 'book_id', 'INTEGER NOT NULL DEFAULT 1');
      await _addColumnIfMissing(
          db, 'pockets', 'kind', "TEXT NOT NULL DEFAULT 'cash'");
      await _addColumnIfMissing(
          db, 'pockets', 'currency', "TEXT NOT NULL DEFAULT 'CNY'");
      await _addColumnIfMissing(
          db, 'pockets', 'archived', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(
          db, 'buckets', 'archived', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(
          db, 'entries', 'book_id', 'INTEGER NOT NULL DEFAULT 1');
      await _addColumnIfMissing(db, 'entries', 'to_pocket_id', 'INTEGER');
      await _addColumnIfMissing(
          db, 'entries', 'tags', "TEXT NOT NULL DEFAULT ''");
      await _addColumnIfMissing(
          db, 'entries', 'reimburse', 'INTEGER NOT NULL DEFAULT 0');
      await _addColumnIfMissing(
          db, 'monthly_budgets', 'book_id', 'INTEGER NOT NULL DEFAULT 1');
      for (final t in ['pockets', 'buckets', 'entries', 'monthly_budgets']) {
        await db.execute('UPDATE $t SET book_id = ?', [bookId]);
      }
    }

    // 老库（v1~v4）都没有 mood 列（情绪账本用）。
    // 注意：**不能只在 from >= 2 时补**——v1 升上来同样缺这一列，
    // 缺了之后所有 addEntry 都会 "no such column: mood" 直接失败。
    // CREATE TABLE IF NOT EXISTS 对新库无效（表已存在），所以这里补列是幂等的。
    await _addColumnIfMissing(
        db, 'entries', 'mood', 'INTEGER NOT NULL DEFAULT 0');

    // v6：二级分类（parent_id）+ 转账手续费/折扣。
    // 老库没有这些列，缺了会 no such column，所以必须无条件补（幂等）。
    await _addColumnIfMissing(db, 'buckets', 'parent_id', 'INTEGER');
    await _addColumnIfMissing(
        db, 'entries', 'fee_cents', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(
        db, 'entries', 'discount_cents', 'INTEGER NOT NULL DEFAULT 0');

    // v7：不计入收支 / 不计入预算 / 每笔币种 / 转账到账金额 / 退款关联。
    // 同样必须无条件补（幂等）——老库缺列会 no such column。
    await _addColumnIfMissing(
        db, 'entries', 'exclude_from_stats', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(
        db, 'entries', 'exclude_from_budget', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(db, 'entries', 'currency', 'TEXT');
    await _addColumnIfMissing(db, 'entries', 'to_amount_cents', 'INTEGER');
    await _addColumnIfMissing(db, 'entries', 'refund_of_id', 'INTEGER');

    // v9：信用卡/负债的信用额度（用来画「已用 / 可用」和进度条）
    await _addColumnIfMissing(
        db, 'pockets', 'credit_limit_cents', 'INTEGER NOT NULL DEFAULT 0');

    // v11：流水软删除（回收站）。老库缺列会 no such column，无条件幂等补。
    await _addColumnIfMissing(db, 'entries', 'deleted_at', 'TEXT');

    // v10：信用卡的账单日 / 还款日。只有信用卡有意义，其它类型存 null。
    await _addColumnIfMissing(db, 'pockets', 'billing_day', 'INTEGER');
    await _addColumnIfMissing(db, 'pockets', 'payment_due_day', 'INTEGER');

    // v12：账户简称 / 卡号（对齐一木：多账户靠简称快速识别）。
    // 老库缺列会 no such column，无条件幂等补。
    await _addColumnIfMissing(
        db, 'pockets', 'alias', "TEXT NOT NULL DEFAULT ''");
    await _addColumnIfMissing(
        db, 'pockets', 'card_no', "TEXT NOT NULL DEFAULT ''");

    // v13：余额校准流水标记。老库缺列会 no such column，无条件幂等补。
    // 已经对过账的旧流水（只认得 memo）顺手回填，否则「只看校准」筛不出它们。
    await _addColumnIfMissing(
        db, 'entries', 'adjustment', 'INTEGER NOT NULL DEFAULT 0');
    await db.execute(
      "UPDATE entries SET adjustment = 1 "
      "WHERE adjustment = 0 AND memo IN ('余额校准', '欠款校准')",
    );

  // v14：账户类型预设（支付宝 / 微信 / 花呗 …）。
  // 只做展示层，计算口径仍然只认 kind，所以老库补空串即可。
  await _addColumnIfMissing(
      db, 'pockets', 'type', "TEXT NOT NULL DEFAULT ''");

  // v15：账户信息页字段（对齐 iCost 的「信贷 / 其他」两类信息页）。
  // 全是展示 / 偏好类，计算口径不变；老库补默认值即可，无条件幂等补。
  await _addColumnIfMissing(db, 'pockets', 'note', "TEXT NOT NULL DEFAULT ''");
  await _addColumnIfMissing(
      db, 'pockets', 'include_in_assets', 'INTEGER NOT NULL DEFAULT 1');
  await _addColumnIfMissing(
      db, 'pockets', 'glyph_dark', "TEXT NOT NULL DEFAULT ''");
  await _addColumnIfMissing(
      db, 'pockets', 'shared_limit', 'INTEGER NOT NULL DEFAULT 0');
  await _addColumnIfMissing(
      db, 'pockets', 'bill_next_period', 'INTEGER NOT NULL DEFAULT 0');
  await _addColumnIfMissing(
      db, 'pockets', 'annual_fee', "TEXT NOT NULL DEFAULT '无'");
  await _addColumnIfMissing(
      db, 'pockets', 'income_sync', "TEXT NOT NULL DEFAULT '无'");
  await _addColumnIfMissing(
      db, 'pockets', 'recordable', 'INTEGER NOT NULL DEFAULT 1');
  await _addColumnIfMissing(
      db, 'pockets', 'visible_book_ids', "TEXT NOT NULL DEFAULT ''");

  // v16：贷款专属字段（对齐 iCost 的「贷款」信息页）。
  // 仅展示/计算辅助，不影响既有统计口径；老库补默认值即可（幂等）。
  await _addColumnIfMissing(
      db, 'pockets', 'annual_rate', 'REAL NOT NULL DEFAULT 0');
  await _addColumnIfMissing(
      db, 'pockets', 'periods', 'INTEGER NOT NULL DEFAULT 0');
  await _addColumnIfMissing(
      db, 'pockets', 'repayment_method', 'INTEGER NOT NULL DEFAULT 0');

  // v17：报销入账关联。
  // 「标记已报销」时会自动生成一笔收入流水把钱记到指定账户，这里存它的 id；
  // 撤回报销时靠它把那笔收入删掉，否则账户余额会凭空多一截。
  // 老库/老备份没有这一列，无条件幂等补。
  await _addColumnIfMissing(db, 'entries', 'reimburse_entry_id', 'INTEGER');

  // v8：附件（图片凭证）
    await db.execute('''
      CREATE TABLE IF NOT EXISTS attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL DEFAULT 1,
        entry_id INTEGER NOT NULL,
        path TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_attachments_entry ON attachments(entry_id)');

    // v12：月度总结（手写文字，按账本 + 月份唯一）。
    // 对齐一木统计页底部的「本月总结」，一句话也行，纯粹是给用户回看用的。
    await db.execute('''
      CREATE TABLE IF NOT EXISTS month_notes (
        book_id INTEGER NOT NULL DEFAULT 1,
        month TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        PRIMARY KEY (book_id, month)
      )
    ''');

    // 索引放最后：v1 老库要先补出 book_id 列，这里才能建复合索引。
    await db
        .execute('CREATE INDEX IF NOT EXISTS idx_entries_day ON entries(day)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_entries_book_day ON entries(book_id, day)');
  }

  static Future<void> _addColumnIfMissing(
      Database db, String table, String column, String def) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    if (cols.any((c) => c['name'] == column)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $column $def');
  }

  Future<void> _seedIfEmpty() async {
    final bookCount = Sqflite.firstIntValue(
            await _db.rawQuery('SELECT COUNT(*) FROM books')) ??
        0;
    if (bookCount == 0) {
      await _db.insert('books',
          {'title': '默认账本', 'glyph': '📒', 'base_currency': 'CNY', 'rank': 0});
    }
    final bookId = Sqflite.firstIntValue(
            await _db.rawQuery('SELECT MIN(id) FROM books')) ??
        1;

    final pocketCount = Sqflite.firstIntValue(
            await _db.rawQuery('SELECT COUNT(*) FROM pockets')) ??
        0;
    // 新装 App 不预置账户（见 withSamplePockets 注释）：用户自己建，
    // 否则「现金/银行卡」两个名字对不上真实账户，还得先删再建。
    if (pocketCount == 0 && withSamplePockets) {
      await _db.insert('pockets', {
        'book_id': bookId,
        'title': '现金',
        'glyph': '👛',
        'kind': 'cash',
        'currency': 'CNY',
        'opening_cents': 0,
        'rank': 0,
      });
      await _db.insert('pockets', {
        'book_id': bookId,
        'title': '银行卡',
        'glyph': '💳',
        'kind': 'bank',
        'currency': 'CNY',
        'opening_cents': 0,
        'rank': 1,
      });
    }
    final bucketCount = Sqflite.firstIntValue(
            await _db.rawQuery('SELECT COUNT(*) FROM buckets')) ??
        0;
    if (bucketCount == 0) {
      // 2026-10-26 用户要求：默认支出分类只给「衣食住行」四个，其余自己加。
      // 预置 8 个的结果是，大部分人装上 App 的头几步都在删分类。
      const outBuckets = [
        ('衣', '👕'),
        ('食', '🍜'),
        ('住', '🏠'),
        ('行', '🚌'),
      ];
      const inBuckets = [('工资', '💰'), ('兼职', '💼'), ('红包', '🧧'), ('其他', '✨')];
      var rank = 0;
      for (final b in outBuckets) {
        await _db.insert('buckets', {
          'book_id': bookId,
          'title': b.$1,
          'glyph': b.$2,
          'flow': 'out',
          'rank': rank++
        });
      }
      rank = 0;
      for (final b in inBuckets) {
        await _db.insert('buckets', {
          'book_id': bookId,
          'title': b.$1,
          'glyph': b.$2,
          'flow': 'in',
          'rank': rank++
        });
      }
    }
  }

  Future<void> wipe() async {
    await _db.transaction((txn) async {
      for (final t in [
        // attachments 必须一起清：它是按 entry_id 挂的，
        // 清空 entries 后新流水会复用自增 id，旧凭证就挂到不相干的新账上。
        'attachments',
        'entries',
        'monthly_budgets',
        'bucket_budgets',
        'rates',
        'goals',
        'recurring',
        'debts',
        'debt_payments',
        'wishes',
        // 月记也在库里：漏了它，用户「清空」之后月度总结还留着，
        // 备份里也照旧带出去 —— 以为清干净了其实没有。
        'month_notes',
        'pockets',
        'buckets',
        'books',
      ]) {
        await txn.delete(t);
      }
    });
    await _seedIfEmpty();
  }

  // ---------------------------------------------------------------- 账本

  Future<List<Book>> books() async {
    final rows = await _db.query('books', orderBy: 'rank, id');
    return rows
        .map((r) => Book(
              id: r['id'] as int,
              title: r['title'] as String,
              glyph: r['glyph'] as String,
              baseCurrency: r['base_currency'] as String,
            ))
        .toList();
  }

  /// 新建账本。**必须**同时播种默认账户和分类：空账本连一笔账都记不了
  /// （记账页要求至少一个账户），这是给自己挖坑。
  Future<int> addBook(String title, String glyph, String baseCurrency) async {
    final rank = Sqflite.firstIntValue(
            await _db.rawQuery('SELECT COUNT(*) FROM books')) ??
        0;
    final id = await _db.insert('books', {
      'title': title,
      'glyph': glyph,
      'base_currency': baseCurrency,
      'rank': rank,
    });
    await seedBookDefaults(id, baseCurrency);
    return id;
  }

  /// 给指定账本播种 4 个支出分类（衣食住行）+ 4 个收入分类。
  ///
  /// 账户**不再**播种（2026-10-25 用户要求：新装 App 账户数为 0，自己建）。
  /// 原来会建「现金 / 银行卡」，但这两个名字对不上任何真实账户，
  /// 用户第一件事就是删掉它们再建自己的 —— 预置反而多两步。
  Future<void> seedBookDefaults(int bookId, String currency) async {
    // 账户不再预置（见方法注释）。分类照旧：新账本没有分类的话，
    // 记账前得先建 8 个分类，那是纯粹的浪费。
    const outBuckets = [
        ('衣', '👕'),
        ('食', '🍜'),
        ('住', '🏠'),
        ('行', '🚌'),
      ];
    const inBuckets = [('工资', '💰'), ('兼职', '💼'), ('红包', '🧧'), ('其他', '✨')];
    var rank = 0;
    for (final b in outBuckets) {
      await _db.insert('buckets', {
        'book_id': bookId,
        'title': b.$1,
        'glyph': b.$2,
        'flow': 'out',
        'rank': rank++,
      });
    }
    rank = 0;
    for (final b in inBuckets) {
      await _db.insert('buckets', {
        'book_id': bookId,
        'title': b.$1,
        'glyph': b.$2,
        'flow': 'in',
        'rank': rank++,
      });
    }
  }

  Future<void> updateBook(Book b) => _db.update('books',
      {'title': b.title, 'glyph': b.glyph, 'base_currency': b.baseCurrency},
      where: 'id = ?', whereArgs: [b.id]);

  /// 至少保留一个账本。
  Future<void> deleteBook(int id) async {
    final all = await books();
    if (all.length <= 1) {
      throw StateError('至少保留一个账本');
    }
    // 账户跨账本共享，**不能跟着账本一起删**：
    // 别的账本还在用这个账户记账，删了它的余额就凭空消失。
    // 只删「除本账本外没有任何流水」的账户。
    final usedElsewhere = <int>{};
    for (final r in await _db.rawQuery(
      'SELECT DISTINCT pocket_id AS pid FROM entries WHERE book_id <> ? '
      'UNION SELECT DISTINCT to_pocket_id FROM entries '
      'WHERE book_id <> ? AND to_pocket_id IS NOT NULL',
      [id, id],
    )) {
      usedElsewhere.add(r['pid'] as int);
    }
    // 只删「本账本自己创建的」且「没被别的账本引用」的账户。
    // ⚠️ 少了 p.bookId == id 这个条件会误删：一个在账本 A 建、
    // 哪儿都还没用过的账户，会在删账本 B 时凭空消失。
    final ownPockets = await allPockets(includeArchived: true);
    final droppable = [
      for (final p in ownPockets)
        if (p.bookId == id && !usedElsewhere.contains(p.id)) p.id,
    ];

    await _db.transaction((txn) async {
      for (final t in [
        'attachments',
        'recurring',
        'goals',
        'rates',
        'bucket_budgets',
        'monthly_budgets',
        'debts',
        'debt_payments',
        'wishes',
        'entries',
        'buckets',
        // 月记按 book_id 存，跟着账本一起走；漏了它就是一堆指向
        // 已删账本的孤儿（导出时还会被带出去）。
        'month_notes',
      ]) {
        await txn.delete(t, where: 'book_id = ?', whereArgs: [id]);
      }
      for (final pid in droppable) {
        await txn.delete('pockets', where: 'id = ?', whereArgs: [pid]);
      }
      await txn.delete('books', where: 'id = ?', whereArgs: [id]);
    });
  }

  // ---------------------------------------------------------------- 账户

  /// 全部账户（**跨账本共享**）。
  ///
  /// 2026-10-23 起账户不再属于单个账本：余额按「所有账本的流水」汇总
  /// （用户拍板：全局余额）。`pockets.book_id` 只记录「最初在哪个账本创建」，
  /// **不参与任何列表/余额过滤**。
  ///
  /// 注意分类仍然按账本隔离（`buckets(bookId, flow)`）——
  /// 分类是账本自己的组织结构，和账户不是一回事。
  Future<List<Pocket>> allPockets({bool includeArchived = true}) async {
    final rows = await _db.query('pockets',
        where: includeArchived ? null : 'archived = 0',
        orderBy: 'rank, id');
    return rows.map(_toPocket).toList();
  }

  Pocket _toPocket(Map<String, Object?> r) => Pocket(
        id: r['id'] as int,
        bookId: r['book_id'] as int,
        title: r['title'] as String,
        glyph: r['glyph'] as String,
        kind: PocketKind.fromDb(r['kind'] as String),
        currency: r['currency'] as String,
        openingCents: r['opening_cents'] as int,
        archived: (r['archived'] as int) == 1,
        creditLimitCents: (r['credit_limit_cents'] as int?) ?? 0,
        billingDay: r['billing_day'] as int?,
        paymentDueDay: r['payment_due_day'] as int?,
        alias: (r['alias'] as String?) ?? '',
        cardNo: (r['card_no'] as String?) ?? '',
        typeId: (r['type'] as String?) ?? '',
        note: (r['note'] as String?) ?? '',
        includeInAssets: (r['include_in_assets'] as int? ?? 1) == 1,
        glyphDark: (r['glyph_dark'] as String?) ?? '',
        sharedLimit: (r['shared_limit'] as int? ?? 0) == 1,
        billNextPeriod: (r['bill_next_period'] as int? ?? 0) == 1,
        annualFee: (r['annual_fee'] as String?) ?? '无',
        incomeSync: (r['income_sync'] as String?) ?? '无',
        recordable: (r['recordable'] as int? ?? 1) == 1,
        visibleBookIds: (r['visible_book_ids'] as String?) ?? '',
        annualRate: (r['annual_rate'] as num?)?.toDouble() ?? 0,
        periods: (r['periods'] as int?) ?? 0,
        repaymentMethod: (r['repayment_method'] as int?) ?? 0,
      );

  Future<void> addPocket({
    required int bookId,
    required String title,
    required String glyph,
    required PocketKind kind,
    required String currency,
    required int openingCents,
    int creditLimitCents = 0,
    int? billingDay,
    int? paymentDueDay,
    String alias = '',
    String cardNo = '',
    String typeId = '',
    String note = '',
    bool includeInAssets = true,
    String glyphDark = '',
    bool sharedLimit = false,
    bool billNextPeriod = false,
    String annualFee = '无',
    String incomeSync = '无',
    bool recordable = true,
    String visibleBookIds = '',
    double annualRate = 0,
    int periods = 0,
    int repaymentMethod = 0,
  }) async {
    final rank = Sqflite.firstIntValue(await _db.rawQuery(
            'SELECT COUNT(*) FROM pockets WHERE book_id = ?', [bookId])) ??
        0;
    await _db.insert('pockets', {
      'book_id': bookId,
      'title': title,
      'glyph': glyph,
      'kind': kind.dbValue,
      'currency': currency,
      'opening_cents': openingCents,
      'credit_limit_cents': creditLimitCents,
      'billing_day': billingDay,
      'payment_due_day': paymentDueDay,
      'alias': alias,
      'card_no': cardNo,
      'type': typeId,
      'note': note,
      'include_in_assets': includeInAssets ? 1 : 0,
      'glyph_dark': glyphDark,
      'shared_limit': sharedLimit ? 1 : 0,
      'bill_next_period': billNextPeriod ? 1 : 0,
      'annual_fee': annualFee,
      'income_sync': incomeSync,
      'recordable': recordable ? 1 : 0,
      'visible_book_ids': visibleBookIds,
      'annual_rate': annualRate,
      'periods': periods,
      'repayment_method': repaymentMethod,
      'rank': rank,
    });
  }

  Future<void> updatePocket(Pocket pocket) => _db.update(
        'pockets',
        {
          'title': pocket.title,
          'glyph': pocket.glyph,
          'kind': pocket.kind.dbValue,
          'currency': pocket.currency,
          'opening_cents': pocket.openingCents,
          'credit_limit_cents': pocket.creditLimitCents,
          'billing_day': pocket.billingDay,
          'payment_due_day': pocket.paymentDueDay,
          'alias': pocket.alias,
          'card_no': pocket.cardNo,
          'type': pocket.typeId,
          'note': pocket.note,
          'include_in_assets': pocket.includeInAssets ? 1 : 0,
          'glyph_dark': pocket.glyphDark,
          'shared_limit': pocket.sharedLimit ? 1 : 0,
          'bill_next_period': pocket.billNextPeriod ? 1 : 0,
          'annual_fee': pocket.annualFee,
          'income_sync': pocket.incomeSync,
          'recordable': pocket.recordable ? 1 : 0,
          'visible_book_ids': pocket.visibleBookIds,
          'annual_rate': pocket.annualRate,
          'periods': pocket.periods,
          'repayment_method': pocket.repaymentMethod,
        },
        where: 'id = ?',
        whereArgs: [pocket.id],
      );

  /// 有流水的账户只能归档不能删（否则历史变孤儿）。
  /// 该账户名下的流水笔数（含作为转入方）。
  /// 用来在「改币种 / 改账户类型」时给用户一个数量级提示。
  Future<int> countEntriesOfPocket(int id) async {
    return Sqflite.firstIntValue(await _db.rawQuery(
            'SELECT COUNT(*) FROM entries WHERE pocket_id = ? OR to_pocket_id = ?',
            [id, id])) ??
        0;
  }

  Future<bool> pocketHasEntries(int id) async {
    final n = Sqflite.firstIntValue(await _db.rawQuery(
            'SELECT COUNT(*) FROM entries WHERE pocket_id = ? OR to_pocket_id = ?',
            [id, id])) ??
        0;
    return n > 0;
  }

  Future<void> archivePocket(int id, bool archived) =>
      _db.update('pockets', {'archived': archived ? 1 : 0},
          where: 'id = ?', whereArgs: [id]);

  Future<void> deletePocketIfEmpty(int id) async {
    if (await pocketHasEntries(id)) {
      throw StateError('该账户还有流水，不能删除');
    }
    // 周期记账模板也算"在用"：只看流水的话，账户能删掉，
    // 但模板到期照样生成流水 —— pocket_id 指向已删账户（没有外键拦），
    // 这笔钱在首页合计里算、在账户余额里被 JOIN 吞掉，下次启动
    // 还会被孤儿修复挪到「第一个账户」，等于悄悄记到别人账上。
    final r = await _db.query('recurring',
        columns: ['id'],
        where: 'pocket_id = ? AND enabled = 1',
        whereArgs: [id],
        limit: 1);
    if (r.isNotEmpty) {
      throw StateError('该账户还有周期记账，先删掉或关掉再删账户');
    }
    await _db.delete('pockets', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------------------------------------------------------- 分类

  Future<List<Bucket>> buckets(int bookId, String flow,
      {bool includeArchived = false}) async {
    final rows = await _db.query('buckets',
        where: includeArchived
            ? 'book_id = ? AND flow = ?'
            : 'book_id = ? AND flow = ? AND archived = 0',
        whereArgs: [bookId, flow],
        orderBy: 'rank, id');
    return rows
        .map((r) => Bucket(
              id: r['id'] as int,
              bookId: r['book_id'] as int,
              title: r['title'] as String,
              glyph: r['glyph'] as String,
              flow: r['flow'] as String,
              archived: (r['archived'] as int) == 1,
              parentId: r['parent_id'] as int?,
            ))
        .toList();
  }

  Future<void> addBucket({
    required int bookId,
    required String title,
    required String glyph,
    required String flow,
    int? parentId,
  }) async {
    final rank = Sqflite.firstIntValue(await _db.rawQuery(
            'SELECT COUNT(*) FROM buckets WHERE book_id = ? AND flow = ?',
            [bookId, flow])) ??
        0;
    await _db.insert('buckets', {
      'book_id': bookId,
      'title': title,
      'glyph': glyph,
      'flow': flow,
      'rank': rank,
      'parent_id': parentId,
    });
  }

  Future<void> updateBucket(Bucket b) => _db.update(
        'buckets',
        {'title': b.title, 'glyph': b.glyph, 'parent_id': b.parentId},
        where: 'id = ?',
        whereArgs: [b.id],
      );

  Future<void> archiveBucket(int id, bool archived) =>
      _db.update('buckets', {'archived': archived ? 1 : 0},
          where: 'id = ?', whereArgs: [id]);

  /// 分类迁移：把 [fromId] 下的所有流水批量改到 [toId]（对齐原版分类迁移页）。
  /// 返回受影响的流水条数。
  Future<int> migrateBucket(int bookId, int fromId, int toId) =>
      _db.update('entries', {'bucket_id': toId},
          where: 'book_id = ? AND bucket_id = ?', whereArgs: [bookId, fromId]);

  /// 常用备注（备注历史）：按出现次数降序，最多 [limit] 条。
  /// 原版 AmountEditorSheet 的备注框左侧有个时钟图标，点开就是这份清单。
  Future<List<String>> frequentMemos(int bookId, {int limit = 12}) async {
    final rows = await _db.rawQuery('''
      SELECT memo, COUNT(*) AS n
      FROM entries
      WHERE book_id = ? AND memo != '' AND deleted_at IS NULL
      GROUP BY memo
      ORDER BY n DESC, MAX(day) DESC
      LIMIT ?
    ''', [bookId, limit]);
    return [for (final r in rows) r['memo'] as String];
  }

  // ---------------------------------------------------------------- 汇率

  Future<Map<String, double>> rates(int bookId) async {
    final rows =
        await _db.query('rates', where: 'book_id = ?', whereArgs: [bookId]);
    return {
      for (final r in rows) r['code'] as String: (r['rate'] as num).toDouble(),
    };
  }

  Future<void> setRate(int bookId, String code, double rate) =>
      _db.insert('rates', {'book_id': bookId, 'code': code, 'rate': rate},
          conflictAlgorithm: ConflictAlgorithm.replace);

  // ---------------------------------------------------------------- 流水

  Future<int> addEntry({
    required int bookId,
    required int pocketId,
    int? toPocketId,
    int? bucketId,
    required String flow,
    required int amountCents,
    required String memo,
    required DateTime day,
    String tags = '',
    int reimburse = 0,
    int mood = 0,
    int feeCents = 0,
    int discountCents = 0,
    bool excludeFromStats = false,
    bool excludeFromBudget = false,
    String? currency,
    int? toAmountCents,
    int? refundOfId,
    bool adjustment = false,
  }) =>
      _db.insert('entries', {
        'book_id': bookId,
        'pocket_id': pocketId,
        'to_pocket_id': toPocketId,
        'bucket_id': bucketId,
        'flow': flow,
        'amount_cents': amountCents,
        'memo': memo,
        'day': dayKey(day),
        'tags': tags,
        'reimburse': reimburse,
        'mood': mood,
        'fee_cents': feeCents,
        'discount_cents': discountCents,
        'exclude_from_stats': excludeFromStats ? 1 : 0,
        'exclude_from_budget': excludeFromBudget ? 1 : 0,
        'currency': currency,
        'to_amount_cents': toAmountCents,
        'refund_of_id': refundOfId,
        'adjustment': adjustment ? 1 : 0,
        'created_at': DateTime.now().toIso8601String(),
      });

  Future<void> updateEntry(Entry e) => _db.update(
        'entries',
        {
          'pocket_id': e.pocketId,
          'to_pocket_id': e.toPocketId,
          'bucket_id': e.bucketId,
          'flow': e.flow,
          'amount_cents': e.amountCents,
          'memo': e.memo,
          'fee_cents': e.feeCents,
          'discount_cents': e.discountCents,
          'exclude_from_stats': e.excludeFromStats ? 1 : 0,
          'exclude_from_budget': e.excludeFromBudget ? 1 : 0,
          'currency': e.currency,
          'to_amount_cents': e.toAmountCents,
          'refund_of_id': e.refundOfId,
          'adjustment': e.adjustment ? 1 : 0,
          'day': dayKey(e.day),
          'tags': e.tags,
          'reimburse': e.reimburse,
          'mood': e.mood,
        },
        where: 'id = ?',
        whereArgs: [e.id],
      );

  /// 删除流水 → 移入回收站（软删除）。
  ///
  /// ⚠️ 只把 `deleted_at` 置为当前时间，**不删附件**（附件在永久删除时才清理，
  /// 这样撤销/恢复后凭证还在）。要真正删掉并清附件用 [purgeEntry]。
  Future<void> deleteEntry(int id) => softDeleteEntries([id]);

  /// 批量删除流水 → 移入回收站（软删除，返回受影响条数）。
  Future<int> softDeleteEntries(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final marks = List.filled(ids.length, '?').join(',');
    return _db.update(
      'entries',
      {'deleted_at': DateTime.now().toIso8601String()},
      where: 'id IN ($marks) AND deleted_at IS NULL',
      whereArgs: ids,
    );
  }

  /// 从回收站恢复一条流水（清空 deleted_at，附件一并回到原流水下）。
  Future<int> restoreEntry(int id) => restoreEntries([id]);

  /// 批量恢复回收站流水，返回恢复条数。
  Future<int> restoreEntries(List<int> ids) async {
    if (ids.isEmpty) return 0;
    final marks = List.filled(ids.length, '?').join(',');
    return _db.update(
      'entries',
      {'deleted_at': null},
      where: 'id IN ($marks) AND deleted_at IS NOT NULL',
      whereArgs: ids,
    );
  }

  /// 永久删除一条流水 + 清理附件记录与文件（不可撤销）。
  ///
  /// 两条 delete 必须在**同一个事务**里：先删 attachments 行、再删 entries 行，
  /// 中间被打断（进程被杀 / 磁盘满）就会留下"流水还在、凭证记录没了"的状态，
  /// 用户永远找不回那些票据。文件删除放事务外 —— 文件系统操作没法回滚，
  /// 但先删了也不影响数据一致性（文件成了孤儿，下次存储管理能看到）。
  Future<void> purgeEntry(int id) async {
    final paths = await _db.transaction((txn) async {
      final rows = await txn.query('attachments',
          columns: ['path'], where: 'entry_id = ?', whereArgs: [id]);
      final list = [for (final r in rows) r['path'] as String];
      await txn.delete('attachments', where: 'entry_id = ?', whereArgs: [id]);
      await txn.delete('entries', where: 'id = ?', whereArgs: [id]);
      return list;
    });
    for (final path in paths) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
  }

  /// 永久删除多笔流水 + 清理附件（不可撤销），返回删除条数。
  Future<int> purgeEntries(List<int> ids) async {
    if (ids.isEmpty) return 0;
    for (final id in ids) {
      await purgeEntry(id);
    }
    return ids.length;
  }

  /// 回收站里的流水（按删除时间倒序）。无删除时间的永远不该出现在这里。
  Future<List<Entry>> recycleBinEntries(int bookId) async {
    final rows = await _db.query('entries',
        where: 'book_id = ? AND deleted_at IS NOT NULL',
        whereArgs: [bookId],
        orderBy: 'deleted_at DESC, id DESC');
    return rows.map(_toEntry).toList();
  }

  /// 清空回收站（永久删除该账本下所有已删除流水 + 附件）。
  Future<int> purgeAllRecycleBin(int bookId) async {
    final entries = await recycleBinEntries(bookId);
    if (entries.isEmpty) return 0;
    await purgeEntries([for (final e in entries) e.id]);
    return entries.length;
  }

  Entry _toEntry(Map<String, Object?> r) => Entry(
        id: r['id'] as int,
        bookId: r['book_id'] as int,
        pocketId: r['pocket_id'] as int,
        toPocketId: r['to_pocket_id'] as int?,
        bucketId: r['bucket_id'] as int?,
        flow: r['flow'] as String,
        amountCents: r['amount_cents'] as int,
        memo: r['memo'] as String,
        day: parseDay(r['day'] as String),
        tags: r['tags'] as String,
        reimburse: r['reimburse'] as int,
        mood: (r['mood'] as int?) ?? 0,
        feeCents: (r['fee_cents'] as int?) ?? 0,
        discountCents: (r['discount_cents'] as int?) ?? 0,
        excludeFromStats: ((r['exclude_from_stats'] as int?) ?? 0) == 1,
        excludeFromBudget: ((r['exclude_from_budget'] as int?) ?? 0) == 1,
        currency: r['currency'] as String?,
        toAmountCents: r['to_amount_cents'] as int?,
        refundOfId: r['refund_of_id'] as int?,
        reimburseEntryId: r['reimburse_entry_id'] as int?,
        deletedAt: _parseDeletedAt(r['deleted_at']),
        adjustment: ((r['adjustment'] as int?) ?? 0) == 1,
      );

  /// 软删除时间列可能缺失（老备份/老库），统一解析。
  static DateTime? _parseDeletedAt(Object? raw) {
    if (raw == null) return null;
    final s = raw.toString();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }

  Future<List<Entry>> entriesOfMonth(int bookId, DateTime month) async {
    final rows = await _db.query('entries',
        where: 'book_id = ? AND deleted_at IS NULL AND day >= ? AND day <= ?',
        whereArgs: [
          bookId,
          dayKey(firstDayOfMonth(month)),
          dayKey(lastDayOfMonth(month))
        ],
        orderBy: 'day DESC, id DESC');
    return rows.map(_toEntry).toList();
  }

  Future<List<Entry>> entriesOfYear(int bookId, int year) async {
    final rows = await _db.query('entries',
        where: 'book_id = ? AND deleted_at IS NULL AND day >= ? AND day <= ?',
        whereArgs: [bookId, '$year-01-01', '$year-12-31'],
        orderBy: 'day ASC, id ASC');
    return rows.map(_toEntry).toList();
  }

  /// 全量统计：总笔数 + 最早记账日（「我的」页的累计笔数 / 坚持天数用）。
  Future<({int count, String? earliestDay})> entryStats(int bookId) async {
    final rows = await _db.rawQuery(
      // substr 后再 MIN：万一有行写成 '2026-10-21T00:00:00.000'，
      // 字典序仍然按日期排，不会被时间部分带偏。
      'SELECT COUNT(*) AS c, MIN(substr(day, 1, 10)) AS d '
      'FROM entries WHERE book_id = ? AND deleted_at IS NULL',
      [bookId],
    );
    final c = (rows.first['c'] as int?) ?? 0;
    final d = rows.first['d'] as String?;
    return (count: c, earliestDay: d);
  }

  Future<List<Entry>> entriesOfDay(int bookId, DateTime day) async {
    final rows = await _db.query('entries',
        where: 'book_id = ? AND deleted_at IS NULL AND day = ?',
        whereArgs: [bookId, dayKey(day)],
        orderBy: 'id DESC');
    return rows.map(_toEntry).toList();
  }

  /// 搜索：备注 / 标签 / 分类名。空关键词返回最近的流水。
  Future<List<Entry>> searchEntries(int bookId, String keyword) async {
    final like = '%${keyword.trim()}%';
    final rows = await _db.rawQuery('''
      SELECT e.* FROM entries e
      LEFT JOIN buckets b ON b.id = e.bucket_id
      WHERE e.book_id = ?
        AND e.deleted_at IS NULL
        AND (e.memo LIKE ? OR e.tags LIKE ? OR COALESCE(b.title, '') LIKE ?)
      ORDER BY e.day DESC, e.id DESC
      LIMIT 200
    ''', [bookId, like, like, like]);
    return rows.map(_toEntry).toList();
  }

  Future<List<Entry>> reimburseEntries(int bookId, {int reimburse = 1}) async {
    final rows = await _db.query('entries',
        where: 'book_id = ? AND deleted_at IS NULL AND reimburse = ?',
        whereArgs: [bookId, reimburse],
        orderBy: 'day DESC, id DESC');
    return rows.map(_toEntry).toList();
  }

  /// 某账户某月的进出去向。
  ///
  /// 不要拿「最近 200 条」的列表去算本月合计——流水多的账户会被截断，
  /// 页面上的「本月支出」就会凭空少一截。
  ///
  /// ⚠️ **不按账本过滤**：账户是跨账本共享的，余额和下方的流水列表
  /// （[entriesOfPocket]）都是全局口径。这里原来带了 `e.book_id = ?`，
  /// 于是同一个账户在账本 A 记的钱不会出现在账本 B 的这个页面上 ——
  /// 本月支出比余额的变化小一截，切账本数字还会变。
  Future<({int outCents, int inCents, int transferOut, int transferIn})>
      pocketMonthTotals(int pocketId, DateTime month) async {
    final rows = await _db.rawQuery('''
      SELECT
        SUM(CASE WHEN e.flow = 'out' AND e.exclude_from_stats = 0
                  AND e.pocket_id = ? THEN e.amount_cents ELSE 0 END) AS out_c,
        SUM(CASE WHEN e.flow = 'in' AND e.exclude_from_stats = 0
                  AND e.pocket_id = ? THEN e.amount_cents ELSE 0 END) AS in_c,
        -- 转出方实际流出 = 本金 + 手续费 − 折扣，和余额口径保持一致
        SUM(CASE WHEN e.flow = 'transfer' AND e.pocket_id = ?
                 THEN e.amount_cents + e.fee_cents - e.discount_cents
                 ELSE 0 END) AS t_out,
        SUM(CASE WHEN e.flow = 'transfer' AND e.to_pocket_id = ?
                 THEN COALESCE(e.to_amount_cents, e.amount_cents) ELSE 0 END) AS t_in
      FROM entries e
      WHERE e.deleted_at IS NULL AND e.day >= ? AND e.day <= ?
    ''', [
      pocketId,
      pocketId,
      pocketId,
      pocketId,
      dayKey(firstDayOfMonth(month)),
      dayKey(lastDayOfMonth(month)),
    ]);
    final r = rows.isEmpty ? const <String, Object?>{} : rows.first;
    int v(String k) => (r[k] as num?)?.toInt() ?? 0;
    return (
      outCents: v('out_c'),
      inCents: v('in_c'),
      transferOut: v('t_out'),
      transferIn: v('t_in'),
    );
  }

  /// 已经被退款关联过的原支出 id（列表里给它们打「已退款」标）。
  Future<Set<int>> refundedSourceIds(int bookId) async {
    final rows = await _db.rawQuery(
      'SELECT DISTINCT refund_of_id AS id FROM entries '
      'WHERE book_id = ? AND refund_of_id IS NOT NULL AND deleted_at IS NULL',
      [bookId],
    );
    return {for (final r in rows) r['id'] as int};
  }

  // ---------------------------------------------------------------- 附件

  Future<int> addAttachment({
    required int bookId,
    required int entryId,
    required String path,
    String name = '',
  }) =>
      _db.insert('attachments', {
        'book_id': bookId,
        'entry_id': entryId,
        'path': path,
        'name': name,
        'created_at': DateTime.now().toIso8601String(),
      });

  Future<List<({int id, String path, String name})>> attachmentsOf(
      int entryId) async {
    final rows = await _db.query('attachments',
        where: 'entry_id = ?', whereArgs: [entryId], orderBy: 'id');
    return [
      for (final r in rows)
        (
          id: r['id'] as int,
          path: r['path'] as String,
          name: (r['name'] as String?) ?? '',
        ),
    ];
  }

  /// 每个流水挂了几张附件（列表里显示 📎 用，避免逐行查询）
  Future<Map<int, int>> attachmentCounts(int bookId) async {
    final rows = await _db.rawQuery(
        'SELECT entry_id, COUNT(*) AS n FROM attachments WHERE book_id = ? '
        'GROUP BY entry_id',
        [bookId]);
    return {
      for (final r in rows)
        r['entry_id'] as int: (r['n'] as num?)?.toInt() ?? 0,
    };
  }

  Future<void> deleteAttachment(int id) =>
      _db.delete('attachments', where: 'id = ?', whereArgs: [id]);

  // 2026-10-27 删掉 deleteAttachmentsOfEntry：purgeEntry 已把「查路径 + 删行」
  // 收进同一个事务里（原来是"先删行、再删流水"，中途失败就丢凭证关联），
  // 全项目再没有第二个调用点。

  /// 全书附件总字节数（存储管理页用）
  Future<int> attachmentBytes(int bookId) async {
    final rows = await _db.query('attachments',
        columns: ['path'], where: 'book_id = ?', whereArgs: [bookId]);
    var total = 0;
    for (final r in rows) {
      try {
        final f = File(r['path'] as String);
        if (f.existsSync()) total += f.lengthSync();
      } catch (_) {}
    }
    return total;
  }

  // ---------------------------------------------------------------- 批量操作
  // 对齐原版搜索页的批量模式（批量删除 / 改分类 / 改备注）

  /// 批量删除流水 → 移入回收站（软删除）。返回实际受影响条数。
  Future<int> deleteEntries(List<int> ids) => softDeleteEntries(ids);

  /// 批量改分类（[bucketId] 传 null = 置为未分类）
  Future<int> updateEntriesBucket(List<int> ids, int? bucketId) async {
    if (ids.isEmpty) return 0;
    final marks = List.filled(ids.length, '?').join(',');
    return _db.update('entries', {'bucket_id': bucketId},
        where: 'id IN ($marks)', whereArgs: ids);
  }

  /// 批量改备注
  Future<int> updateEntriesMemo(List<int> ids, String memo) async {
    if (ids.isEmpty) return 0;
    final marks = List.filled(ids.length, '?').join(',');
    return _db.update('entries', {'memo': memo},
        where: 'id IN ($marks)', whereArgs: ids);
  }

  /// 批量改日期（首页批量编辑用）。
  ///
  /// 存 `dayKey` 字符串而不是 DateTime：全库的日期比较都走字符串字典序，
  /// 格式一旦不一致（带不带时间部分）就会漏数据。
  Future<int> updateEntriesDay(List<int> ids, DateTime day) async {
    if (ids.isEmpty) return 0;
    final marks = List.filled(ids.length, '?').join(',');
    return _db.update('entries', {'day': dayKey(day)},
        where: 'id IN ($marks)', whereArgs: ids);
  }

  Future<void> setReimburse(int entryId, int reimburse) =>
      _db.update('entries', {'reimburse': reimburse},
          where: 'id = ?', whereArgs: [entryId]);

  /// 标记「已报销」，并把报销金额**记到指定账户**。
  ///
  /// 2026-10-28 用户要求：点「已报销」时要能选报销到哪个账户，确认后金额
  /// 自动加到那个账户上。所以这里生成一笔收入流水（flow='in'），
  /// 再把原流水标成已报销、并把新流水的 id 记在 `reimburse_entry_id`。
  ///
  /// 为什么是一笔新流水而不是直接改原流水：原流水是**支出**，它记的是钱出去的
  /// 那一侧；钱回来落在另一个账户上，必须有一条属于那个账户的流水，
  /// 否则余额算不出来（账户余额是按流水汇总的）。
  ///
  /// 记成收入、不排除统计：原支出还在统计里，两边一起算净额才对；
  /// 只排除一边会让"这个月净花了多少"算错。
  ///
  /// 两步必须同事务，否则中途失败会留下"已报销但没有入账"的死账。
  Future<int> reimburseTo(
    int entryId,
    int pocketId, {
    DateTime? day,
  }) async {
    final rows =
        await _db.query('entries', where: 'id = ?', whereArgs: [entryId]);
    if (rows.isEmpty) throw StateError('这笔流水不存在');
    final e = _toEntry(rows.first);
    // 已经报销过就别再记一笔（界面上按钮会消失，但重复点击/并发回调仍可能进来）。
    // 返回已有那笔的 id，没有就 -1。
    if (e.reimburse == 2) return e.reimburseEntryId ?? -1;
    final when = day ?? DateTime.now();
    final memo = e.memo.trim().isEmpty ? '报销' : '报销 · ${e.memo.trim()}';
    late int createdId;
    await _db.transaction((txn) async {
      createdId = await txn.insert('entries', {
        'book_id': e.bookId,
        'pocket_id': pocketId,
        'flow': 'in',
        'amount_cents': e.amountCents,
        'memo': memo,
        'day': dayKey(when),
        'tags': '报销',
        'reimburse': 0,
        'currency': e.currency,
        'created_at': DateTime.now().toIso8601String(),
      });
      await txn.update(
        'entries',
        {'reimburse': 2, 'reimburse_entry_id': createdId},
        where: 'id = ?',
        whereArgs: [entryId],
      );
    });
    return createdId;
  }

  /// 撤回报销：把当初自动记入的那笔收入删掉，原流水回到「待报销」。
  ///
  /// 只改标记不删流水的话，账户余额会凭空多出这笔钱 —— 用户点一下撤回，
  /// 账就对不上了。
  Future<void> unreimburse(int entryId) async {
    final rows =
        await _db.query('entries', where: 'id = ?', whereArgs: [entryId]);
    if (rows.isEmpty) return;
    final linkId = rows.first['reimburse_entry_id'] as int?;
    await _db.transaction((txn) async {
      if (linkId != null) {
        await txn.delete('entries', where: 'id = ?', whereArgs: [linkId]);
      }
      await txn.update(
        'entries',
        {'reimburse': 1, 'reimburse_entry_id': null},
        where: 'id = ?',
        whereArgs: [entryId],
      );
    });
  }

  // ---------------------------------------------------------------- 聚合（原币种分）

  Future<Map<String, int>> monthTotalsByFlow(int bookId, DateTime month) async {
    final rows = await _db.rawQuery('''
      SELECT flow, SUM(amount_cents) AS total
      FROM entries
      WHERE book_id = ? AND deleted_at IS NULL AND day >= ? AND day <= ? AND exclude_from_stats = 0
      GROUP BY flow
    ''', [
      bookId,
      dayKey(firstDayOfMonth(month)),
      dayKey(lastDayOfMonth(month))
    ]);
    return {
      for (final r in rows)
        r['flow'] as String: (r['total'] as num?)?.toInt() ?? 0,
    };
  }

  /// 分类排行（保留 bucket_id，好让排行榜能点进分类详情 / 展开子分类）。
  /// 与原版 category_rank_row 对应。
  Future<
      List<
          ({
            int? bucketId,
            String label,
            String glyph,
            String currency,
            int cents
          })>> bucketRank(
    int bookId, {
    required String flow,
    required DateTime from,
    required DateTime to,
  }) async {
    final rows = await _db.rawQuery('''
      SELECT e.bucket_id AS bid,
             COALESCE(b.title, '未分类') AS title,
             COALESCE(b.glyph, '🧾') AS glyph,
             COALESCE(e.currency, p.currency) AS currency,
             SUM(e.amount_cents) AS total
      FROM entries e
      LEFT JOIN buckets b ON b.id = e.bucket_id
      JOIN pockets p ON p.id = e.pocket_id
      WHERE e.book_id = ? AND e.deleted_at IS NULL AND e.day >= ? AND e.day <= ? AND e.flow = ?
        AND e.exclude_from_stats = 0
      GROUP BY e.bucket_id, COALESCE(e.currency, p.currency)
      ORDER BY total DESC
    ''', [bookId, dayKey(from), dayKey(to), flow]);
    return rows
        .map((r) => (
              bucketId: r['bid'] as int?,
              label: r['title'] as String,
              glyph: r['glyph'] as String,
              currency: r['currency'] as String,
              cents: (r['total'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }

  /// 分类占比（按币种分组；跨币种由上层折算合并）。
  ///
  /// 默认按 [month] 取当月；传 [from]/[to] 可覆盖成任意区间（本年 / 全部）。
  Future<List<({String label, String glyph, String currency, int cents})>>
      bucketSlices(int bookId, DateTime month,
          {String flow = 'out', DateTime? from, DateTime? to}) async {
    final startDay = dayKey(from ?? firstDayOfMonth(month));
    final endDay = dayKey(to ?? lastDayOfMonth(month));
    final rows = await _db.rawQuery('''
      SELECT COALESCE(b.title, '未分类') AS title,
             COALESCE(b.glyph, '🧾') AS glyph,
             COALESCE(e.currency, p.currency) AS currency,
             SUM(e.amount_cents) AS total
      FROM entries e
      LEFT JOIN buckets b ON b.id = e.bucket_id
      JOIN pockets p ON p.id = e.pocket_id
      WHERE e.book_id = ? AND e.deleted_at IS NULL AND e.day >= ? AND e.day <= ? AND e.flow = ?
        AND e.exclude_from_stats = 0
      GROUP BY COALESCE(b.title, '未分类'), COALESCE(b.glyph, '🧾'),
               COALESCE(e.currency, p.currency)
      ORDER BY total DESC
    ''', [bookId, startDay, endDay, flow]);
    return rows
        .map((r) => (
              label: r['title'] as String,
              glyph: r['glyph'] as String,
              currency: r['currency'] as String,
              cents: (r['total'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }

  /// 每天 flow → 分（原币种直接相加；上层折算）。
  Future<Map<String, Map<String, int>>> dailyTotalsByFlow(
      int bookId, DateTime month) async {
    final rows = await _db.rawQuery('''
      SELECT day, flow, SUM(amount_cents) AS total
      FROM entries
      WHERE book_id = ? AND deleted_at IS NULL AND day >= ? AND day <= ? AND exclude_from_stats = 0
      GROUP BY day, flow
    ''', [
      bookId,
      dayKey(firstDayOfMonth(month)),
      dayKey(lastDayOfMonth(month))
    ]);
    final map = <String, Map<String, int>>{};
    for (final r in rows) {
      map.putIfAbsent(r['day'] as String, () => {})[r['flow'] as String] =
          (r['total'] as num?)?.toInt() ?? 0;
    }
    return map;
  }

  /// 各账户余额（本账户币种分）= 期初 + 收入 − 支出 − 转出 + 转入。
  /// 信用卡/负债：余额为正是「还欠这么多」。
  /// 各账户余额（原币种分）。
  ///
  /// **跨账本汇总**：一个账户在账本 A 记的消费、在账本 B 也计入同一份余额。
  /// 这是用户拍板的「全局余额」口径。
  Future<List<({Pocket pocket, int balanceCents})>> pocketBalances() async {
    // ⚠️ 这里**不能**按 includeInAssets 过滤。
    //
    // 这个方法是「每个账户各自有多少钱」的唯一来源：账户详情页的余额、
    // 账户管理列表、搜索页的账户筛选都读它。「不计入总资产」只是一个
    // **汇总口径**（净资产/资产总额别把它加进去），不是"这个账户不存在"。
    //
    // 原来在这里 `.where((p) => p.includeInAssets)`，后果很严重：
    // 关掉开关的账户从资产页消失、详情页查不到自己的余额 →
    // 回退成「期初余额」，之后所有流水都不体现；再点一次余额校准，
    // reconcileBalance 会以那个错的期初为基准，写出一条把历史流水
    // 重复计一遍的调整分录 —— 永久错账。
    // 汇总侧要过滤请用 p.includeInAssets（见 assets_page 的合计处）。
    final list = await allPockets(includeArchived: true);
    final rowsFrom = await _db.rawQuery('''
      SELECT pocket_id AS pid,
             SUM(CASE
                   WHEN flow = 'in' THEN amount_cents
                   -- 转账：转出方扣「本金 + 手续费 − 折扣」
                   WHEN flow = 'transfer' THEN -(amount_cents + fee_cents - discount_cents)
                   ELSE -amount_cents
                 END) AS delta
      FROM entries
      -- 不按 book_id 过滤：全局余额
      WHERE deleted_at IS NULL
      GROUP BY pocket_id
    ''', const []);
    final rowsTo = await _db.rawQuery('''
      SELECT to_pocket_id AS pid,
             SUM(COALESCE(to_amount_cents, amount_cents)) AS delta
      FROM entries
      WHERE flow = 'transfer' AND to_pocket_id IS NOT NULL AND deleted_at IS NULL
      GROUP BY to_pocket_id
    ''', const []);
    final fromDelta = <int, int>{
      for (final r in rowsFrom)
        r['pid'] as int: (r['delta'] as num?)?.toInt() ?? 0,
    };
    final toDelta = <int, int>{
      for (final r in rowsTo)
        r['pid'] as int: (r['delta'] as num?)?.toInt() ?? 0,
    };
    return list.map((p) {
      final delta = (fromDelta[p.id] ?? 0) + (toDelta[p.id] ?? 0);
      // 普通账户：余额 = 期初 + 净流入。
      // 信用卡/负债：期初记的是「欠多少」，所以支出/取现(+)要加到欠款上、
      // 还款(转入)要减掉 —— 正好是普通账户的相反数。
      final balance =
          p.kind.isLiability ? p.openingCents - delta : p.openingCents + delta;
      return (pocket: p, balanceCents: balance);
    }).toList();
  }

  // ---------------------------------------------------------------- 预算

  Future<int> budgetOf(int bookId, DateTime month) async {
    final rows = await _db.query('monthly_budgets',
        where: 'month = ? AND book_id = ?',
        whereArgs: [monthKey(month), bookId],
        limit: 1);
    if (rows.isEmpty) return 0;
    // 不能 as int：外部导入的备份可能给成 REAL / NULL，一抛就整页报错。
    // 本文件其它地方早就是 (… as num?)?.toInt() ?? 0，只有这里漏了。
    return (rows.first['amount_cents'] as num?)?.toInt() ?? 0;
  }

  Future<void> setBudget(int bookId, DateTime month, int cents) async {
    if (cents <= 0) {
      await _db.delete('monthly_budgets',
          where: 'month = ? AND book_id = ?',
          whereArgs: [monthKey(month), bookId]);
      return;
    }
    await _db.insert(
      'monthly_budgets',
      {'month': monthKey(month), 'book_id': bookId, 'amount_cents': cents},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 某月各分类的支出（原币种分，按 bucket_id 分组；未分类的 bucket_id 为 null）
  Future<List<({int? bucketId, String currency, int cents})>> bucketSpent(
      int bookId, DateTime month) async {
    final rows = await _db.rawQuery('''
      SELECT e.bucket_id AS bid, COALESCE(e.currency, p.currency) AS currency,
             SUM(e.amount_cents) AS total
      FROM entries e
      JOIN pockets p ON p.id = e.pocket_id
      WHERE e.book_id = ? AND e.deleted_at IS NULL AND e.day >= ? AND e.day <= ? AND e.flow = 'out'
        AND e.exclude_from_budget = 0
      GROUP BY e.bucket_id, COALESCE(e.currency, p.currency)
    ''', [
      bookId,
      dayKey(firstDayOfMonth(month)),
      dayKey(lastDayOfMonth(month)),
    ]);
    return rows
        .map((r) => (
              bucketId: r['bid'] as int?,
              currency: r['currency'] as String,
              cents: (r['total'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }

  /// 某月按标签汇总（原始行，币种未折算）。
  ///
  /// ⚠️ 一笔账单可以有多个标签（`"出差,报销"`），它会在**每个**标签下各计一次。
  /// 所以标签合计通常大于当月总支出——这不是算错，UI 上必须说明，
  /// 否则用户拿标签金额相加发现对不上，会以为统计出 bug。
  Future<List<({String tag, String currency, int cents})>> tagSpent(
    int bookId,
    DateTime month, {
    String flow = 'out',
  }) async {
    final rows = await _db.rawQuery('''
      SELECT e.tags AS tags, COALESCE(e.currency, p.currency) AS currency,
             SUM(e.amount_cents) AS total
      FROM entries e
      JOIN pockets p ON p.id = e.pocket_id
      WHERE e.book_id = ? AND e.deleted_at IS NULL AND e.day >= ? AND e.day <= ? AND e.flow = ?
        AND e.exclude_from_stats = 0 AND e.tags <> ''
      GROUP BY e.tags, COALESCE(e.currency, p.currency)
    ''', [
      bookId,
      dayKey(firstDayOfMonth(month)),
      dayKey(lastDayOfMonth(month)),
      flow,
    ]);

    // SQL 是按"整串 tags"分组的，这里拆成单个标签后再合并同标签。
    final acc = <String, Map<String, int>>{};
    for (final r in rows) {
      final currency = (r['currency'] as String?) ?? 'CNY';
      final total = (r['total'] as num?)?.toInt() ?? 0;
      for (final raw in ((r['tags'] as String?) ?? '').split(',')) {
        final tag = raw.trim();
        if (tag.isEmpty) continue;
        final per = acc.putIfAbsent(tag, () => <String, int>{});
        per[currency] = (per[currency] ?? 0) + total;
      }
    }
    return [
      for (final e in acc.entries)
        for (final c in e.value.entries)
          (tag: e.key, currency: c.key, cents: c.value),
    ];
  }

  /// 某月按账户汇总（原始行，币种未折算）
  Future<List<({int pocketId, String currency, int cents})>> pocketSpent(
    int bookId,
    DateTime month, {
    String flow = 'out',
  }) async {
    final rows = await _db.rawQuery('''
      SELECT e.pocket_id AS pid, COALESCE(e.currency, p.currency) AS currency,
             SUM(e.amount_cents) AS total
      FROM entries e
      JOIN pockets p ON p.id = e.pocket_id
      WHERE e.book_id = ? AND e.deleted_at IS NULL AND e.day >= ? AND e.day <= ? AND e.flow = ?
        AND e.exclude_from_stats = 0
      GROUP BY e.pocket_id, COALESCE(e.currency, p.currency)
    ''', [
      bookId,
      dayKey(firstDayOfMonth(month)),
      dayKey(lastDayOfMonth(month)),
      flow,
    ]);
    return [
      for (final r in rows)
        (
          pocketId: (r['pid'] as num?)?.toInt() ?? 0,
          currency: (r['currency'] as String?) ?? 'CNY',
          cents: (r['total'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  // ---------------------------------------------------------------- 分类预算

  /// 某月各分类的预算：bucketId → 分
  Future<Map<int, int>> bucketBudgets(int bookId, DateTime month) async {
    final rows = await _db.query('bucket_budgets',
        where: 'book_id = ? AND month = ?',
        whereArgs: [bookId, monthKey(month)]);
    return {
      for (final r in rows) r['bucket_id'] as int: r['amount_cents'] as int,
    };
  }

  Future<void> setBucketBudget(
      int bookId, DateTime month, int bucketId, int cents) async {
    if (cents <= 0) {
      await _db.delete('bucket_budgets',
          where: 'book_id = ? AND month = ? AND bucket_id = ?',
          whereArgs: [bookId, monthKey(month), bucketId]);
      return;
    }
    await _db.insert(
      'bucket_budgets',
      {
        'book_id': bookId,
        'month': monthKey(month),
        'bucket_id': bucketId,
        'amount_cents': cents,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------------------------------------------------------------- 账户详情

  /// 某账户的全部流水（按日期倒序）
  /// 某账户的流水（**跨账本**：和全局余额口径一致，
  /// 否则账户详情页的列表和资产页的余额会对不上）。
  /// 某个账户的流水。
  ///
  /// [onlyAdjustment] 为 true 时只返回校准流水（账户详情的「只看校准」开关）。
  /// 校准流水方向相反时（欠更多记支出）也挂在 pocket_id 上，
  /// 所以这里不用额外处理 to_pocket_id。
  Future<List<Entry>> entriesOfPocket(int pocketId,
      {int limit = 200, bool onlyAdjustment = false}) async {
    final rows = await _db.query(
      'entries',
      where: '(pocket_id = ? OR to_pocket_id = ?) AND deleted_at IS NULL'
          '${onlyAdjustment ? ' AND adjustment = 1' : ''}',
      whereArgs: [pocketId, pocketId],
      orderBy: 'day DESC, id DESC',
      limit: limit,
    );
    return rows.map(_toEntry).toList();
  }

  /// 账户的校准流水条数（决定要不要显示「只看校准」开关）。
  Future<int> adjustmentCountOf(int pocketId) async {
    final n = Sqflite.firstIntValue(await _db.rawQuery(
      'SELECT COUNT(*) FROM entries '
      'WHERE pocket_id = ? AND adjustment = 1 AND deleted_at IS NULL',
      [pocketId],
    ));
    return n ?? 0;
  }

  /// 余额校准：把账户余额对齐到 [targetCents]。
  ///
  /// **不改期初余额**——改期初会连历史月份的统计一起改写，而且看不出
  /// 「什么时候对过账」。这里生成一条 `adjustment` 流水，既修正余额，
  /// 又留下审计痕迹（回收站里还能撤）。
  ///
  /// 方向判定必须和 [pocketBalances] 用同一套符号口径：
  /// - 普通账户 `balance = opening + delta`：
  ///   要凑到 target，需要 `delta += target - balance`，
  ///   所以 target 更大记「收入」、更小记「支出」。
  /// - 负债账户 `balance = opening - delta`（正数 = 还欠这么多）：
  ///   要凑到 target，需要 `delta += balance - target`，正好相反 ——
  ///   欠款变多（target 更大）记「支出」，欠款变少记「收入」。
  ///
  /// 余额已一致时返回 null（调用方据此提示「不用校准」）。
  Future<int?> reconcileBalance({
    required int bookId,
    required Pocket pocket,
    required int currentCents,
    required int targetCents,
    DateTime? day,
  }) async {
    if (targetCents == currentCents) return null;
    final diff = targetCents - currentCents;
    final flow = reconcileFlow(pocket.kind, diff);
    return addEntry(
      bookId: bookId,
      pocketId: pocket.id,
      flow: flow,
      amountCents: diff.abs(),
      memo: pocket.kind.isLiability ? '欠款校准' : '余额校准',
      day: day ?? DateTime.now(),
      excludeFromStats: true,
      excludeFromBudget: true,
      adjustment: true,
    );
  }

  /// 校准流水记成收入还是支出（[diff] = 目标 − 当前）。
  ///
  /// 抽出来是为了让确认弹窗的预览文案和实际写入走**同一份判定**，
  /// 不能 UI 里写一遍、store 里再写一遍（两边一旦分歧就是越校越乱）。
  static String reconcileFlow(PocketKind kind, int diff) =>
      kind.isLiability ? (diff > 0 ? 'out' : 'in') : (diff > 0 ? 'in' : 'out');

  // ---------------------------------------------------------------- 储蓄目标

  Future<List<Goal>> goals(int bookId) async {
    final rows = await _db.query('goals',
        where: 'book_id = ?', whereArgs: [bookId], orderBy: 'rank, id');
    return rows
        .map((r) => Goal(
              id: r['id'] as int,
              bookId: r['book_id'] as int,
              title: r['title'] as String,
              glyph: r['glyph'] as String,
              targetCents: r['target_cents'] as int,
              savedCents: r['saved_cents'] as int,
              dueDay: r['due_day'] == null
                  ? null
                  : DateTime.parse(r['due_day'] as String),
            ))
        .toList();
  }

  Future<void> addGoal({
    required int bookId,
    required String title,
    required String glyph,
    required int targetCents,
    required int savedCents,
    DateTime? dueDay,
  }) =>
      _db.insert('goals', {
        'book_id': bookId,
        'title': title,
        'glyph': glyph,
        'target_cents': targetCents,
        'saved_cents': savedCents,
        'due_day': dueDay == null ? null : dayKey(dueDay),
      });

  Future<void> updateGoal(Goal g) => _db.update(
        'goals',
        {
          'title': g.title,
          'glyph': g.glyph,
          'target_cents': g.targetCents,
          'saved_cents': g.savedCents,
          'due_day': g.dueDay == null ? null : dayKey(g.dueDay!),
        },
        where: 'id = ?',
        whereArgs: [g.id],
      );

  Future<void> deleteGoal(int id) =>
      _db.delete('goals', where: 'id = ?', whereArgs: [id]);

  // ---------------------------------------------------------------- 周期记账

  Future<List<Recurring>> recurrings(int bookId) async {
    final rows = await _db.query('recurring',
        where: 'book_id = ?', whereArgs: [bookId], orderBy: 'id');
    return rows
        .map((r) => Recurring(
              id: r['id'] as int,
              bookId: r['book_id'] as int,
              title: r['title'] as String,
              bucketId: r['bucket_id'] as int?,
              pocketId: r['pocket_id'] as int,
              flow: r['flow'] as String,
              amountCents: r['amount_cents'] as int,
              dayOfMonth: r['day_of_month'] as int,
              lastRunMonth: r['last_run_month'] as String,
              enabled: (r['enabled'] as int) == 1,
            ))
        .toList();
  }

  Future<void> addRecurring(Recurring r) => _db.insert('recurring', {
        'book_id': r.bookId,
        'title': r.title,
        'bucket_id': r.bucketId,
        'pocket_id': r.pocketId,
        'flow': r.flow,
        'amount_cents': r.amountCents,
        'day_of_month': r.dayOfMonth,
        'last_run_month': r.lastRunMonth,
        'enabled': r.enabled ? 1 : 0,
      });

  Future<void> updateRecurring(Recurring r) => _db.update(
        'recurring',
        {
          'title': r.title,
          'bucket_id': r.bucketId,
          'pocket_id': r.pocketId,
          'flow': r.flow,
          'amount_cents': r.amountCents,
          'day_of_month': r.dayOfMonth,
          'enabled': r.enabled ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [r.id],
      );

  Future<void> deleteRecurring(int id) =>
      _db.delete('recurring', where: 'id = ?', whereArgs: [id]);

  /// 把到期的周期账单落地成流水。
  ///
  /// 规则：从 lastRunMonth 的下个月补到本月。
  /// - 上个月及更早的月份：整月必补（补漏，哪怕当月还没到 dayOfMonth 也补在当月）
  /// - 本月：只有今天 >= dayOfMonth 才生成
  /// 每次跑到本月后记录 lastRunMonth，保证同月不重复生成。
  Future<int> applyDueRecurring(int bookId, DateTime today) async {
    final list = await recurrings(bookId);
    var created = 0;
    final currentMonth = DateTime(today.year, today.month);
    for (final r in list.where((x) => x.enabled)) {
      var month = r.lastRunMonth.isEmpty
          ? currentMonth
          : DateTime.parse('${r.lastRunMonth}-01')
              .add(const Duration(days: 32));
      month = DateTime(month.year, month.month); // 归一到月初
      while (!month.isAfter(currentMonth)) {
        // 夹到当月最后一天：dayOfMonth=31 在 30/28 天月会被 Dart 自动溢出到下月，
        // 导致本该落地的周期账单静默跳过、lastRunMonth 永不推进、周期永久卡死。
        final lastDay = DateTime(month.year, month.month + 1, 0).day;
        final dayMissing = r.dayOfMonth > lastDay; // 当月根本没有这一天（如 31 号在 4 月）
        final dueDay = DateTime(
            month.year, month.month, r.dayOfMonth.clamp(1, lastDay));
        final isCurrent = month.year == currentMonth.year &&
            month.month == currentMonth.month;
        // 本月还没到日子：什么都不做，也**不要**推进 lastRunMonth，
        // 否则到了日子那天这笔就永久漏掉了。
        // dayMissing 时该月没有这一天，月底即视为到期，进入当月就生成；
        // 否则 dayOfMonth=31 在短月会永远等不到「那一天」→ 永久卡死。
        if (isCurrent && !dayMissing && today.isBefore(dueDay)) break;
        await addEntry(
          bookId: bookId,
          pocketId: r.pocketId,
          bucketId: r.bucketId,
          flow: r.flow,
          amountCents: r.amountCents,
          memo: r.title,
          day: dueDay,
        );
        created++;
        await _db.update('recurring', {'last_run_month': monthKey(month)},
            where: 'id = ?', whereArgs: [r.id]);
        month = DateTime(month.year, month.month + 1);
      }
    }
    return created;
  }

  // ---------------------------------------------------------------- 借贷

  Future<List<Debt>> debts(int bookId, {bool includeClosed = false}) async {
    final rows = await _db.query('debts',
        where: includeClosed ? 'book_id = ?' : 'book_id = ? AND closed = 0',
        whereArgs: [bookId],
        orderBy: 'closed, borrowed_on DESC, id DESC');
    return rows.map(_toDebt).toList();
  }

  Debt _toDebt(Map<String, Object?> r) => Debt(
        id: r['id'] as int,
        bookId: r['book_id'] as int,
        direction: r['direction'] as String,
        counterparty: r['counterparty'] as String,
        channel: r['channel'] as String,
        principalCents: r['principal_cents'] as int,
        currency: r['currency'] as String,
        borrowedOn: DateTime.parse(r['borrowed_on'] as String),
        dueOn:
            r['due_on'] == null ? null : DateTime.parse(r['due_on'] as String),
        note: r['note'] as String,
        interestRate: (r['interest_rate'] as num?)?.toDouble(),
        closed: (r['closed'] as int) == 1,
      );

  Future<int> addDebt(Debt d) => _db.insert('debts', {
        'book_id': d.bookId,
        'direction': d.direction,
        'counterparty': d.counterparty,
        'channel': d.channel,
        'principal_cents': d.principalCents,
        'currency': d.currency,
        'borrowed_on': dayKey(d.borrowedOn),
        'due_on': d.dueOn == null ? null : dayKey(d.dueOn!),
        'note': d.note,
        'interest_rate': d.interestRate,
        'closed': d.closed ? 1 : 0,
        'created_at': DateTime.now().toIso8601String(),
      });

  Future<void> updateDebt(Debt d) => _db.update(
        'debts',
        {
          'direction': d.direction,
          'counterparty': d.counterparty,
          'channel': d.channel,
          'principal_cents': d.principalCents,
          'currency': d.currency,
          'borrowed_on': dayKey(d.borrowedOn),
          'due_on': d.dueOn == null ? null : dayKey(d.dueOn!),
          'note': d.note,
          'interest_rate': d.interestRate,
          'closed': d.closed ? 1 : 0,
        },
        where: 'id = ?',
        whereArgs: [d.id],
      );

  Future<void> deleteDebt(int id) async {
    await _db.transaction((txn) async {
      await txn.delete('debt_payments', where: 'debt_id = ?', whereArgs: [id]);
      await txn.delete('debts', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> setDebtClosed(int id, bool closed) =>
      _db.update('debts', {'closed': closed ? 1 : 0},
          where: 'id = ?', whereArgs: [id]);

  Future<List<DebtPayment>> debtPayments(int debtId) async {
    final rows = await _db.query('debt_payments',
        where: 'debt_id = ?',
        whereArgs: [debtId],
        orderBy: 'paid_on DESC, id DESC');
    return rows
        .map((r) => DebtPayment(
              id: r['id'] as int,
              debtId: r['debt_id'] as int,
              amountCents: r['amount_cents'] as int,
              paidOn: DateTime.parse(r['paid_on'] as String),
              note: r['note'] as String,
            ))
        .toList();
  }

  Future<void> addDebtPayment({
    required int bookId,
    required int debtId,
    required int amountCents,
    required DateTime paidOn,
    String note = '',
  }) =>
      _db.insert('debt_payments', {
        'book_id': bookId,
        'debt_id': debtId,
        'amount_cents': amountCents,
        'paid_on': dayKey(paidOn),
        'note': note,
      });

  Future<void> deleteDebtPayment(int id) =>
      _db.delete('debt_payments', where: 'id = ?', whereArgs: [id]);

  /// 每条借贷已还多少：debtId → 分，用来算「还欠 / 待收」
  Future<Map<int, int>> debtPaidMap(int bookId) async {
    final rows = await _db.rawQuery(
      "SELECT debt_id, SUM(amount_cents) AS total FROM debt_payments "
      "WHERE book_id = ? GROUP BY debt_id",
      [bookId],
    );
    return {
      for (final r in rows)
        r['debt_id'] as int: (r['total'] as num?)?.toInt() ?? 0,
    };
  }

  // ---------------------------------------------------------------- 愿望清单

  Future<List<Wish>> wishes(int bookId, {String? status}) async {
    final rows = await _db.query('wishes',
        where: status == null ? 'book_id = ?' : 'book_id = ? AND status = ?',
        whereArgs: status == null ? [bookId] : [bookId, status],
        orderBy: 'status, created_on DESC, id DESC');
    return rows
        .map((r) => Wish(
              id: r['id'] as int,
              bookId: r['book_id'] as int,
              title: r['title'] as String,
              glyph: r['glyph'] as String,
              priceCents: r['price_cents'] as int,
              note: r['note'] as String,
              coolDays: r['cool_days'] as int,
              createdOn: DateTime.parse(r['created_on'] as String),
              status: r['status'] as String,
            ))
        .toList();
  }

  Future<void> addWish(Wish w) => _db.insert('wishes', {
        'book_id': w.bookId,
        'title': w.title,
        'glyph': w.glyph,
        'price_cents': w.priceCents,
        'note': w.note,
        'cool_days': w.coolDays,
        'created_on': dayKey(w.createdOn),
        'status': w.status,
      });

  Future<void> updateWish(Wish w) => _db.update(
        'wishes',
        {
          'title': w.title,
          'glyph': w.glyph,
          'price_cents': w.priceCents,
          'note': w.note,
          'cool_days': w.coolDays,
          'status': w.status,
        },
        where: 'id = ?',
        whereArgs: [w.id],
      );

  Future<void> setWishStatus(int id, String status) => _db
      .update('wishes', {'status': status}, where: 'id = ?', whereArgs: [id]);

  Future<void> deleteWish(int id) =>
      _db.delete('wishes', where: 'id = ?', whereArgs: [id]);

  // ---------------------------------------------------------------- 标签

  /// 所有标签及使用次数（tags 是逗号分隔的字符串）
  Future<List<({String tag, int count})>> tagStats(int bookId) async {
    final rows = await _db.query('entries',
        columns: ['tags'], where: 'book_id = ? AND deleted_at IS NULL', whereArgs: [bookId]);
    final count = <String, int>{};
    for (final r in rows) {
      final raw = (r['tags'] as String?) ?? '';
      for (final t in raw.split(',')) {
        final tag = t.trim();
        if (tag.isEmpty) continue;
        count[tag] = (count[tag] ?? 0) + 1;
      }
    }
    final list = count.entries.map((e) => (tag: e.key, count: e.value)).toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return list;
  }

  /// 重命名标签：逐条改写流水里的 tags 字符串，返回影响的条数
  Future<int> renameTag(int bookId, String from, String to) async {
    final rows = await _db.query('entries',
        columns: ['id', 'tags'], where: 'book_id = ? AND deleted_at IS NULL', whereArgs: [bookId]);
    var changed = 0;
    for (final r in rows) {
      final raw = (r['tags'] as String?) ?? '';
      final parts = raw
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (!parts.contains(from)) continue;
      final next = <String>[];
      for (final t in parts) {
        final v = t == from ? to : t;
        if (!next.contains(v)) next.add(v);
      }
      await _db.update('entries', {'tags': next.join(',')},
          where: 'id = ?', whereArgs: [r['id']]);
      changed++;
    }
    return changed;
  }

  Future<int> deleteTag(int bookId, String tag) async {
    final rows = await _db.query('entries',
        columns: ['id', 'tags'], where: 'book_id = ? AND deleted_at IS NULL', whereArgs: [bookId]);
    var changed = 0;
    for (final r in rows) {
      final raw = (r['tags'] as String?) ?? '';
      final all = raw
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (!all.contains(tag)) continue;
      await _db.update(
          'entries', {'tags': all.where((t) => t != tag).join(',')},
          where: 'id = ?', whereArgs: [r['id']]);
      changed++;
    }
    return changed;
  }

  Future<List<Entry>> entriesOfTag(int bookId, String tag) async {
    final rows = await _db.rawQuery(
      "SELECT e.* FROM entries e "
      "WHERE e.book_id = ? AND e.deleted_at IS NULL AND (',' || e.tags || ',') LIKE ? "
      "ORDER BY e.day DESC, e.id DESC LIMIT 300",
      [bookId, '%,$tag,%'],
    );
    return rows.map(_toEntry).toList();
  }

  // ---------------------------------------------------------------- 分类统计

  /// 某分类近 N 个月支出（原币种分、按月分组），给分类详情页画走势
  /// 分类的月度走势。
  /// [bucketIds] 传「自身 + 子分类」，否则父分类详情和排行榜会给出两个数。
  /// [flow] 必须传：之前硬编码 'out'，收入分类的详情页走势永远是 0。
  Future<List<({String month, String currency, int cents})>> bucketMonthly(
    int bookId,
    List<int> bucketIds, {
    String flow = 'out',
    int months = 6,
    // 走势图的锚点。默认今天，但**必须允许调用方传选中月份** ——
    // 原来硬编码 DateTime.now()，翻到 2025 年 3 月看分类详情，
    // 走势图还是最近 6 个月，月份切换器等于失灵。
    DateTime? anchor,
  }) async {
    if (bucketIds.isEmpty) return const [];
    final marks = List.filled(bucketIds.length, '?').join(',');
    final now = anchor ?? DateTime.now();
    final from = DateTime(now.year, now.month - months + 1);
    final to = lastDayOfMonth(now);
    final rows = await _db.rawQuery(
      "SELECT substr(e.day, 1, 7) AS m, "
      "COALESCE(e.currency, p.currency) AS currency, "
      "SUM(e.amount_cents) AS total "
      "FROM entries e JOIN pockets p ON p.id = e.pocket_id "
      "WHERE e.book_id = ? AND e.bucket_id IN ($marks) AND e.flow = ? "
      "AND e.deleted_at IS NULL AND e.day >= ? AND e.day <= ? AND e.exclude_from_stats = 0 "
      // ⚠️ 不能写 GROUP BY m, currency：entries 和 pockets 都有 currency 列，
      // SQLite 会报 "ambiguous column name: currency" 直接查不出来。
      // 必须重复表达式来分组（本文件其它同类查询也是这么写的）。
      "GROUP BY m, COALESCE(e.currency, p.currency) ORDER BY m",
      [
        bookId,
        ...bucketIds,
        flow,
        dayKey(firstDayOfMonth(from)),
        // 上界同样重要：原来没有它，未来日期的账也会算进走势
        dayKey(to),
      ],
    );
    return rows
        .map((r) => (
              month: r['m'] as String,
              currency: r['currency'] as String,
              cents: (r['total'] as num?)?.toInt() ?? 0,
            ))
        .toList();
  }

  // ---------------------------------------------------------------- 净资产走势

  /// 逐日净资产（折算后），给蜡烛图用。
  ///
  /// 为什么需要它：蜡烛图的「开/高/低/收」四个价必须是**同一时点的总净值**，
  /// 光有月末余额只能算出「收」，影线（高/低）只能编。所以这里按天把流水累加
  /// 成一条净值曲线，再由上层按月切 OHLC。
  ///
  /// 口径与 [monthEndBalances] / [pocketBalances] 完全一致：
  /// - 普通账户贡献 = 期初 + 净流入；
  /// - 负债账户贡献 = -期初 + 净流入（期初记的是「欠多少」）；
  /// - 转账转出方扣「本金 + 手续费 − 折扣」，转入方加 COALESCE(to_amount, amount)；
  /// - 不含归档（仍计入资产）之外的过滤，已删除流水排除。
  ///
  /// [toBase] 由调用方注入（store 层不碰汇率表），把「某币种的分」折成本位币分。
  Future<({int baselineCents, List<({DateTime day, int netCents})> days})>
      netWorthDaily({
    required DateTime from,
    required int Function(int cents, String currency) toBase,
    DateTime? until,
  }) async {
    final pockets = (await allPockets(includeArchived: true))
        .where((p) => p.includeInAssets)
        .toList();
    final byId = {for (final p in pockets) p.id: p};

    // 起点：所有账户期初的净值贡献之和
    var value = 0;
    for (final p in pockets) {
      value += toBase(
        p.kind.isLiability ? -p.openingCents : p.openingCents,
        p.currency,
      );
    }

    final rowsFrom = await _db.rawQuery(
      "SELECT pocket_id AS pid, day AS d, "
      "SUM(CASE "
      "WHEN flow = 'in' THEN amount_cents "
      "WHEN flow = 'transfer' THEN -(amount_cents + fee_cents - discount_cents) "
      "ELSE -amount_cents END) AS delta "
      "FROM entries WHERE deleted_at IS NULL GROUP BY pocket_id, day",
      const [],
    );
    final rowsTo = await _db.rawQuery(
      "SELECT to_pocket_id AS pid, day AS d, "
      "SUM(COALESCE(to_amount_cents, amount_cents)) AS delta "
      "FROM entries WHERE flow = 'transfer' AND to_pocket_id IS NOT NULL "
      "AND deleted_at IS NULL GROUP BY to_pocket_id, day",
      const [],
    );

    // day -> 当天净值变化（本位币分）
    final perDay = <String, int>{};
    void take(Map<String, Object?> r) {
      final p = byId[r['pid'] as int];
      if (p == null) return;
      final delta = (r['delta'] as num?)?.toInt() ?? 0;
      if (delta == 0) return;
      final key = r['d'] as String;
      perDay[key] = (perDay[key] ?? 0) + toBase(delta, p.currency);
    }

    for (final r in rowsFrom) {
      take(r);
    }
    for (final r in rowsTo) {
      take(r);
    }

    final changeDays = perDay.keys.toList()..sort();
    final startKey = dayKey(from);

    // 先把 from 之前的全部吃进去，得到 from 当天的起点
    var idx = 0;
    while (idx < changeDays.length && changeDays[idx].compareTo(startKey) < 0) {
      value += perDay[changeDays[idx]]!;
      idx++;
    }

    // 区间起点之前的净值 = 当月第一天任何流水发生前的值，就是「月开盘价」
    final baseline = value;
    final end = until ?? DateTime.now();
    final out = <({DateTime day, int netCents})>[];
    var cursor = DateTime(from.year, from.month, from.day);
    while (!cursor.isAfter(end)) {
      final key = dayKey(cursor);
      while (idx < changeDays.length && changeDays[idx] == key) {
        value += perDay[changeDays[idx]]!;
        idx++;
      }
      out.add((day: cursor, netCents: value));
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
    }
    return (baselineCents: baseline, days: out);
  }

  /// 近 N 个月「月末」各账户余额（原币种分），给净资产曲线用。
  /// 口径：期初 + 截至该月末的所有流水（转账两边都算）。
  Future<
      List<
          ({
            DateTime month,
            int pocketId,
            String currency,
            int balanceCents
          })>> monthEndBalances({int months = 6}) async {
    final pockets = (await allPockets(includeArchived: true))
        .where((p) => p.includeInAssets)
        .toList();
    final opened = {for (final p in pockets) p.id: p.openingCents};
    final result =
        <({DateTime month, int pocketId, String currency, int balanceCents})>[];
    final now = DateTime.now();
    for (var i = months - 1; i >= 0; i--) {
      final month = DateTime(now.year, now.month - i);
      final endKey = dayKey(lastDayOfMonth(month));
      final rowsFrom = await _db.rawQuery(
        "SELECT pocket_id AS pid, "
        // 口径必须与 pocketBalances 一致：转账要扣「本金 + 手续费 − 折扣」。
        // 以前只减本金，带手续费的转账会让曲线和账户余额永久差那笔手续费。
        "SUM(CASE "
        "WHEN flow = 'in' THEN amount_cents "
        "WHEN flow = 'transfer' THEN -(amount_cents + fee_cents - discount_cents) "
        "ELSE -amount_cents END) AS delta "
        "FROM entries WHERE day <= ? AND deleted_at IS NULL GROUP BY pocket_id",
        [endKey],
      );
      final rowsTo = await _db.rawQuery(
        "SELECT to_pocket_id AS pid, "
        "SUM(COALESCE(to_amount_cents, amount_cents)) AS delta "
        "FROM entries WHERE day <= ? AND flow = 'transfer' "
        "AND to_pocket_id IS NOT NULL AND deleted_at IS NULL GROUP BY to_pocket_id",
        [endKey],
      );
      final delta = <int, int>{};
      for (final r in rowsFrom) {
        delta[r['pid'] as int] = (r['delta'] as num?)?.toInt() ?? 0;
      }
      for (final r in rowsTo) {
        final pid = r['pid'] as int;
        delta[pid] = (delta[pid] ?? 0) + ((r['delta'] as num?)?.toInt() ?? 0);
      }
      for (final p in pockets) {
        final opening = opened[p.id] ?? 0;
        final d = delta[p.id] ?? 0;
        // 普通账户：期初 + 净流入。
        // 负债账户：期初记的是「欠多少」，对净资产的贡献是 -期初；
        // 之后每次支出 delta 为负，但欠款增加，所以贡献要 +delta
        // （还款 delta 为正，欠款减少，贡献也 +delta）。合并起来就是 -期初 + delta。
        final contribution = p.kind.isLiability ? -opening + d : opening + d;
        result.add((
          month: month,
          pocketId: p.id,
          currency: p.currency,
          balanceCents: contribution,
        ));
      }
    }
    return result;
  }

  // ---------------------------------------------------------------- 高级搜索

  /// 搜索 + 多条件筛选。
  ///
  /// [matchAny] 是「满足任一」开关：
  /// - false（默认）= 所有条件 AND（我要找「上月 · 餐饮 · 200 元以上」）；
  /// - true = 条件之间 OR（我要找「备注里有星巴克，或者分类是咖啡」）。
  ///
  /// book_id 永远用 AND 拼在最外层 —— 跨账本搜索会把两个账本的钱混在一起，
  /// 用户看到的总数就是错的。作用域不属于"筛选条件"。
  /// 搜索条件构造。列表查询和合计查询共用一份，避免两边漂移。
  ({String where, List<Object?> args}) _searchWhere(
    int bookId, {
    String keyword = '',
    String? flow,
    int? bucketId,
    List<int>? bucketIds,
    List<int>? pocketIds,
    List<String>? tags,
    int? reimburse,
    int? minCents,
    int? maxCents,
    DateTime? from,
    DateTime? to,
    bool matchAny = false,
  }) {
    final conds = <String>[];
    final condArgs = <Object?>[];

    void add(String sql, List<Object?> args) {
      conds.add(sql);
      condArgs.addAll(args);
    }

    if (keyword.trim().isNotEmpty) {
      add("(e.memo LIKE ? OR e.tags LIKE ? OR COALESCE(b.title,'') LIKE ?)",
          ['%${keyword.trim()}%', '%${keyword.trim()}%', '%${keyword.trim()}%']);
    }
    if (flow != null && flow.isNotEmpty) {
      add('e.flow = ?', [flow]);
    }
    if (bucketId != null) {
      add('e.bucket_id = ?', [bucketId]);
    }
    if (bucketIds != null && bucketIds.isNotEmpty) {
      final marks = List.filled(bucketIds.length, '?').join(',');
      add('e.bucket_id IN ($marks)', bucketIds);
    }
    if (pocketIds != null && pocketIds.isNotEmpty) {
      final marks = List.filled(pocketIds.length, '?').join(',');
      add('(e.pocket_id IN ($marks) OR e.to_pocket_id IN ($marks))',
          [...pocketIds, ...pocketIds]);
    }
    if (tags != null && tags.isNotEmpty) {
      for (final t in tags) {
        final v = t.trim();
        if (v.isEmpty) continue;
        // ⚠️ 必须整串匹配，不能 LIKE '%v%'：
        // 有「出差」「出差报销」两个标签时，选「出差」会把两条都算进来，
        // 而标签详情页（entriesOfTag）用的是整串匹配 → 同一个标签两个金额。
        // tags 是逗号分隔、无空格（见记账页的 split）。
        add("(',' || e.tags || ',') LIKE ?", ['%,$v,%']);
      }
    }
    if (reimburse != null && reimburse > 0) {
      add('e.reimburse = ?', [reimburse]);
    }
    if (minCents != null) {
      add('e.amount_cents >= ?', [minCents]);
    }
    if (maxCents != null) {
      add('e.amount_cents <= ?', [maxCents]);
    }
    if (from != null) {
      add('e.day >= ?', [dayKey(from)]);
    }
    if (to != null) {
      add('e.day <= ?', [dayKey(to)]);
    }

    final where = <String>['e.book_id = ?', 'e.deleted_at IS NULL'];
    final args = <Object?>[bookId];
    if (conds.isNotEmpty) {
      where.add(matchAny ? '(${conds.join(' OR ')})' : conds.join(' AND '));
      args.addAll(condArgs);
    }
    return (where: where.join(' AND '), args: args);
  }

  /// 搜索 + 多条件筛选（列表用，最多 300 条）。
  ///
  /// [matchAny] 是「满足任一」开关：
  /// - false（默认）= 所有条件 AND；
  /// - true = 条件之间 OR。
  /// book_id 永远用 AND 拼在最外层 —— 跨账本搜索会把两个账本的钱混在一起。
  Future<List<Entry>> searchEntriesEx(
    int bookId, {
    String keyword = '',
    String? flow,
    int? bucketId,
    List<int>? bucketIds,
    List<int>? pocketIds,
    List<String>? tags,
    int? reimburse,
    int? minCents,
    int? maxCents,
    DateTime? from,
    DateTime? to,
    bool matchAny = false,
  }) async {
    final c = _searchWhere(
      bookId,
      keyword: keyword,
      flow: flow,
      bucketId: bucketId,
      bucketIds: bucketIds,
      pocketIds: pocketIds,
      tags: tags,
      reimburse: reimburse,
      minCents: minCents,
      maxCents: maxCents,
      from: from,
      to: to,
      matchAny: matchAny,
    );
    final rows = await _db.rawQuery(
      "SELECT e.* FROM entries e LEFT JOIN buckets b ON b.id = e.bucket_id "
      "WHERE ${c.where} ORDER BY e.day DESC, e.id DESC LIMIT 300",
      c.args,
    );
    return rows.map(_toEntry).toList();
  }

  /// 搜索合计（**不带 LIMIT**）。
  ///
  /// 原来页面拿前 300 条当全量合计：搜「餐饮」命中 512 条时，
  /// 合计少算 212 条，而界面没有任何提示 —— 用户拿去对账就是错的。
  /// 同时排除「不计入收支」，和首页/统计口径一致。
  /// 返回未折算的原始行，币种交给上层折算。
  Future<List<({String flow, String currency, int cents})>> searchTotals(
    int bookId, {
    String keyword = '',
    String? flow,
    int? bucketId,
    List<int>? bucketIds,
    List<int>? pocketIds,
    List<String>? tags,
    int? reimburse,
    int? minCents,
    int? maxCents,
    DateTime? from,
    DateTime? to,
    bool matchAny = false,
  }) async {
    final c = _searchWhere(
      bookId,
      keyword: keyword,
      flow: flow,
      bucketId: bucketId,
      bucketIds: bucketIds,
      pocketIds: pocketIds,
      tags: tags,
      reimburse: reimburse,
      minCents: minCents,
      maxCents: maxCents,
      from: from,
      to: to,
      matchAny: matchAny,
    );
    final rows = await _db.rawQuery(
      "SELECT e.flow AS flow, COALESCE(e.currency, p.currency) AS currency, "
      "SUM(e.amount_cents) AS total "
      "FROM entries e "
      "LEFT JOIN buckets b ON b.id = e.bucket_id "
      "LEFT JOIN pockets p ON p.id = e.pocket_id "
      "WHERE ${c.where} AND e.exclude_from_stats = 0 "
      "GROUP BY e.flow, COALESCE(e.currency, p.currency)",
      c.args,
    );
    return [
      for (final r in rows)
        (
          flow: r['flow'] as String,
          currency: (r['currency'] as String?) ?? 'CNY',
          cents: (r['total'] as num?)?.toInt() ?? 0,
        ),
    ];
  }

  /// 本账本里用过的全部标签，按出现次数降序。
  ///
  /// tags 是逗号分隔的一列（`"出差,报销"`），SQL 里没法直接 DISTINCT，
  /// 所以拉出来在 Dart 侧拆。只取 5000 行上限，避免多年账本一次拉爆内存。
  Future<List<String>> allTags(int bookId) async {
    final rows = await _db.rawQuery(
      "SELECT tags FROM entries WHERE book_id = ? AND tags <> '' "
      "AND deleted_at IS NULL "
      "ORDER BY day DESC LIMIT 5000",
      [bookId],
    );
    final count = <String, int>{};
    for (final r in rows) {
      final raw = (r['tags'] as String?) ?? '';
      for (final t in raw.split(',')) {
        final v = t.trim();
        if (v.isEmpty) continue;
        count[v] = (count[v] ?? 0) + 1;
      }
    }
    final list = count.keys.toList()
      ..sort((a, b) {
        final c = count[b]!.compareTo(count[a]!);
        return c != 0 ? c : a.compareTo(b);
      });
    return list;
  }

  /// 取一段日期内的活跃流水（导入去重用；软删除的不算，可重新导入）
  Future<List<Entry>> entriesBetween(
      int bookId, DateTime from, DateTime to) async {
    final rows = await _db.query('entries',
        where: 'book_id = ? AND deleted_at IS NULL AND day >= ? AND day <= ?',
        whereArgs: [bookId, dayKey(from), dayKey(to)],
        orderBy: 'day, id');
    return rows.map(_toEntry).toList();
  }

  // ---------------------------------------------------------------- CSV 导出

  /// 导出 CSV（带 BOM，Excel 双击不乱码）
  Future<String> exportCsv(int bookId, {DateTime? from, DateTime? to}) async {
    final where = <String>['e.book_id = ?', 'e.deleted_at IS NULL'];
    final args = <Object?>[bookId];
    if (from != null) {
      where.add('e.day >= ?');
      args.add(dayKey(from));
    }
    if (to != null) {
      where.add('e.day <= ?');
      args.add(dayKey(to));
    }
    final rows = await _db.rawQuery(
      "SELECT e.day, e.flow, e.amount_cents, e.memo, e.tags, e.reimburse, "
      "COALESCE(b.title, '') AS bucket, COALESCE(p.title, '') AS pocket, "
      // 币种必须优先取这一笔自己的：一笔 USD 支出记在 CNY 账户上时，
      // 用账户币种会把它导成「10.00 CNY」，和实际差一个汇率。
      "COALESCE(e.currency, p.currency) AS currency, "
      "COALESCE(p2.title, '') AS to_pocket "
      "FROM entries e "
      "LEFT JOIN buckets b ON b.id = e.bucket_id "
      "LEFT JOIN pockets p ON p.id = e.pocket_id "
      "LEFT JOIN pockets p2 ON p2.id = e.to_pocket_id "
      "WHERE ${where.join(' AND ')} ORDER BY e.day, e.id",
      args,
    );

    String esc(Object? v) {
      var t = (v ?? '').toString();
      if (t.contains(',') || t.contains('"') || t.contains('\n')) {
        t = '"${t.replaceAll('"', '""')}"';
      }
      return t;
    }

    final buf = StringBuffer('\uFEFF');
    // 用 CRLF：Excel / WPS 对 \n 结尾的 CSV 兼容性差
    buf.write('日期,类型,金额,币种,分类,账户,转入账户,备注,标签,报销\r\n');
    for (final r in rows) {
      final cents = (r['amount_cents'] as num?)?.toInt() ?? 0;
      final flowText = switch (r['flow']) {
        'in' => '收入',
        'transfer' => '转账',
        _ => '支出',
      };
      final reimburseText = switch (r['reimburse'] as int?) {
        1 => '待报销',
        2 => '已报销',
        _ => '',
      };
      buf.write([
        esc(r['day']),
        esc(flowText),
        esc((cents / 100).toStringAsFixed(2)),
        esc(r['currency']),
        esc(r['bucket']),
        esc(r['pocket']),
        esc(r['to_pocket']),
        esc(r['memo']),
        esc(r['tags']),
        esc(reimburseText),
      ].join(','));
      buf.write('\r\n');
    }
    return buf.toString();
  }

  // ---------------------------------------------------------------- 洞察用查询

  /// 最近 N 天的流水（预测/热力/情绪都用它）
  Future<List<Entry>> entriesRecent(int bookId, {int days = 90}) async {
    final now = DateTime.now();
    final from = now.subtract(Duration(days: days));
    return entriesBetween(bookId, from, now);
  }

  /// 数据概况：每张表的行数（「数据管理」页展示 + 出问题时排查用）
  Future<Map<String, int>> tableCounts() async {
    const tables = [
      'books',
      'pockets',
      'buckets',
      'entries',
      'monthly_budgets',
      'bucket_budgets',
      'rates',
      'goals',
      'recurring',
      'debts',
      'debt_payments',
      'wishes',
    ];
    final out = <String, int>{};
    for (final t in tables) {
      final n =
          Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM $t'));
      out[t] = n ?? 0;
    }
    return out;
  }

  /// 数据库文件大小（字节）
  Future<int> databaseBytes() async {
    try {
      final f = File(_db.path);
      if (!await f.exists()) return 0;
      return await f.length();
    } catch (_) {
      return 0;
    }
  }

  /// 孤儿数据：指向已删除账户/分类的流水
  ///
  /// 正常路径不会产生（账户/分类只能归档、不能删有流水的），但导入外部数据、
  /// 或者手工改过备份之后可能出现，所以给一个扫描 + 修复入口。
  Future<({int badPocket, int badBucket})> orphanStats(int bookId) async {
    final badPocket = Sqflite.firstIntValue(await _db.rawQuery(
          "SELECT COUNT(*) FROM entries e "
          "LEFT JOIN pockets p ON p.id = e.pocket_id "
          "WHERE e.book_id = ? AND p.id IS NULL",
          [bookId],
        )) ??
        0;
    final badBucket = Sqflite.firstIntValue(await _db.rawQuery(
          "SELECT COUNT(*) FROM entries e "
          "LEFT JOIN buckets b ON b.id = e.bucket_id "
          "WHERE e.book_id = ? AND e.bucket_id IS NOT NULL AND b.id IS NULL",
          [bookId],
        )) ??
        0;
    return (badPocket: badPocket, badBucket: badBucket);
  }

  /// 修复孤儿：缺失账户的流水挪到该账本第一个账户；缺失分类的置为「未分类」
  Future<int> fixOrphans(int bookId) async {
    final pockets = await allPockets(includeArchived: true);
    var fixed = 0;
    if (pockets.isNotEmpty) {
      final fallback = pockets.first.id;
      fixed += await _db.rawUpdate(
        "UPDATE entries SET pocket_id = ? WHERE book_id = ? AND pocket_id NOT IN "
        "(SELECT id FROM pockets)",
        [fallback, bookId],
      );
    }
    fixed += await _db.rawUpdate(
      "UPDATE entries SET bucket_id = NULL WHERE book_id = ? AND bucket_id IS NOT NULL "
      "AND bucket_id NOT IN (SELECT id FROM buckets)",
      [bookId],
    );
    // 转入方的孤儿也要清：转出方照常扣了钱、转入方却加不上，
    // 这笔钱就凭空蒸发，而 orphanStats 只查 pocket_id，用户一点线索都没有。
    // 置 NULL（而不是塞进第一个账户）：塞过去等于把这笔钱记到别人账上。
    fixed += await _db.rawUpdate(
      "UPDATE entries SET to_pocket_id = NULL WHERE book_id = ? "
      "AND to_pocket_id IS NOT NULL AND to_pocket_id NOT IN (SELECT id FROM pockets)",
      [bookId],
    );
    return fixed;
  }

  // ---------------------------------------------------------------- 备份

  // ---------------------------------------------------------------- 月度总结

  static String _monthKey(DateTime m) =>
      '${m.year}-${m.month.toString().padLeft(2, '0')}';

  /// 读某账本某月的手写总结；没有返回空串。
  Future<String> monthNote(int bookId, DateTime month) async {
    final rows = await _db.query('month_notes',
        where: 'book_id = ? AND month = ?',
        whereArgs: [bookId, _monthKey(month)],
        limit: 1);
    if (rows.isEmpty) return '';
    return (rows.first['note'] as String?) ?? '';
  }

  /// 这个账本写过的所有月度总结，按月份倒序。
  ///
  /// 统计页只能看到「当前月份」那一条，写过的历史月份在 App 里没有任何入口，
  /// 等于白记 —— 数据管理页用这个把它列出来。
  Future<List<({String month, String note})>> monthNotes(int bookId) async {
    final rows = await _db.query('month_notes',
        where: 'book_id = ?',
        whereArgs: [bookId],
        orderBy: 'month DESC');
    return [
      for (final r in rows)
        (
          month: (r['month'] as String?) ?? '',
          note: (r['note'] as String?) ?? '',
        )
    ]..removeWhere((e) => e.month.isEmpty || e.note.isEmpty);
  }

  /// 写月度总结。传空串 = 删掉该月记录（不留空行）。
  Future<void> setMonthNote(int bookId, DateTime month, String note) async {
    final text = note.trim();
    if (text.isEmpty) {
      await _db.delete('month_notes',
          where: 'book_id = ? AND month = ?',
          whereArgs: [bookId, _monthKey(month)]);
      return;
    }
    await _db.insert(
      'month_notes',
      {'book_id': bookId, 'month': _monthKey(month), 'note': text},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<String> exportJson() async {
    final payload = {
      'app': 'jianji',
      'schema': _version,
      'exportedAt': DateTime.now().toIso8601String(),
      'books': await _db.query('books'),
      'pockets': await _db.query('pockets'),
      'buckets': await _db.query('buckets'),
      'entries': await _db.query('entries'),
      'budgets': await _db.query('monthly_budgets'),
      'bucketBudgets': await _db.query('bucket_budgets'),
      'debts': await _db.query('debts'),
      'debtPayments': await _db.query('debt_payments'),
      'wishes': await _db.query('wishes'),
      'rates': await _db.query('rates'),
      'goals': await _db.query('goals'),
      'recurring': await _db.query('recurring'),
      'monthNotes': await _db.query('month_notes'),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<void> importJson(String raw) async {
    final decoded = jsonDecode(raw);
    if (decoded is! Map || decoded['app'] != 'jianji') {
      throw const FormatException('不是简记的备份文件');
    }
    const tables = {
      'books': 'books',
      'pockets': 'pockets',
      'buckets': 'buckets',
      'entries': 'entries',
      'budgets': 'monthly_budgets',
      'bucketBudgets': 'bucket_budgets',
      'debts': 'debts',
      'debtPayments': 'debt_payments',
      'wishes': 'wishes',
      'rates': 'rates',
      'goals': 'goals',
      'recurring': 'recurring',
      'monthNotes': 'month_notes',
    };
    await _db.transaction((txn) async {
      for (final t in tables.values) {
        await txn.delete(t);
      }
      // 备份里不含凭证，但本机的 attachments 还按旧 entry_id 挂着；
      // 不清理的话，恢复完别人的备份会看到自己的发票挂在别人的账上。
      await txn.delete('attachments');
      for (final key in tables.keys) {
        final rows = (decoded[key] as List?) ?? const [];
        for (final row in rows) {
          await txn.insert(tables[key]!, Map<String, Object?>.from(row as Map));
        }
      }
    });
    await _seedIfEmpty();
  }
}
