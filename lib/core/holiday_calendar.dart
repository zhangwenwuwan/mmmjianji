/// 官方法定节假日与调休（「休 / 班」标记）。
///
/// ## 为什么单独一个文件
///
/// `lunar.dart` 里的 `calendarLabel()` 回答的是「今天是什么日子」（春节 / 清明 /
/// 国庆 / 霜降…）。它回答不了「今天上不上班」：
///
/// - 「国庆节」是 10 月 1 日这一天的**名称**，而 10/1~10/7 才是**假期区间**；
/// - 春节 9 天长假里，有些天既不是初一也不是十五，但都放假；
/// - 调休上班日（比如 2026-02-14 周六上班）在农历上**没有任何特征**。
///
/// 所以节日名称与休/班状态必须分开建模。
///
/// ## 硬约束
///
/// **调休不能靠算法推算**。网上流传的「按星期几推调休」全部不可靠——每年的
/// 安排由国务院办公厅单独发文确定，只能逐年录入。未录入的年份 `holidayOf()`
/// 返回 null，调用方回退到原有节日 / 节气显示，不崩、不猜。
///
/// ## 数据来源
///
/// - 2025：《国务院办公厅关于 2025 年部分节假日安排的通知》
///   （国办发明电〔2024〕7 号，2024-11-12）
/// - 2026：《国务院办公厅关于 2026 年部分节假日安排的通知》
///   （国办发明电〔2025〕7 号，2025-11-04）
///
/// TODO(数据)：**2027 年的安排尚未发布**（国办通常在每年 11 月才发次年的通知），
/// 所以这里没有编造。等官方发文后按 2025/2026 的格式补，补之前务必核对原文。
/// 未录入的年份 `holidayOf()` 返回 null，UI 自动回退到节日/节气显示。
library;

import 'rules.dart';

/// 休假状态。
enum HolidayKind {
  /// 法定放假（含调休放进来的日子）。
  rest,

  /// 调休上班（本该休息的周末要上班）。
  work,
}

/// 某一天的官方节假日信息。
class HolidayDay {
  const HolidayDay(this.kind, this.label);

  final HolidayKind kind;

  /// 假期名称，如「春节」「国庆」；调休上班日沿用所属假期的名称。
  final String label;

  bool get isRest => kind == HolidayKind.rest;
}

/// 按年份、按 `dayKey`（`yyyy-MM-dd`）索引的官方安排。
const Map<int, Map<String, HolidayDay>> kOfficialHolidays = {
  // 2025：《国务院办公厅关于 2025 年部分节假日安排的通知》
  // （国办发明电〔2024〕7 号，2024-11-12）。注意 2025 起法定假日增加 2 天，
  // 春节 8 天（含除夕）、劳动节 5 天，且中秋与国庆合并放假 8 天。
  2025: {
    // ---- 元旦：1/1(三) 放假 1 天，不调休
    '2025-01-01': HolidayDay(HolidayKind.rest, '元旦'),

    // ---- 春节：1/28(除夕,二)~2/4(初七,二) 放假 8 天；1/26(日)、2/8(六) 上班
    '2025-01-26': HolidayDay(HolidayKind.work, '春节'),
    '2025-01-28': HolidayDay(HolidayKind.rest, '春节'),
    '2025-01-29': HolidayDay(HolidayKind.rest, '春节'),
    '2025-01-30': HolidayDay(HolidayKind.rest, '春节'),
    '2025-01-31': HolidayDay(HolidayKind.rest, '春节'),
    '2025-02-01': HolidayDay(HolidayKind.rest, '春节'),
    '2025-02-02': HolidayDay(HolidayKind.rest, '春节'),
    '2025-02-03': HolidayDay(HolidayKind.rest, '春节'),
    '2025-02-04': HolidayDay(HolidayKind.rest, '春节'),
    '2025-02-08': HolidayDay(HolidayKind.work, '春节'),

    // ---- 清明：4/4(五)~4/6(日) 放假 3 天，无调休
    '2025-04-04': HolidayDay(HolidayKind.rest, '清明'),
    '2025-04-05': HolidayDay(HolidayKind.rest, '清明'),
    '2025-04-06': HolidayDay(HolidayKind.rest, '清明'),

    // ---- 劳动节：5/1(四)~5/5(一) 放假 5 天；4/27(日) 上班
    '2025-04-27': HolidayDay(HolidayKind.work, '劳动节'),
    '2025-05-01': HolidayDay(HolidayKind.rest, '劳动节'),
    '2025-05-02': HolidayDay(HolidayKind.rest, '劳动节'),
    '2025-05-03': HolidayDay(HolidayKind.rest, '劳动节'),
    '2025-05-04': HolidayDay(HolidayKind.rest, '劳动节'),
    '2025-05-05': HolidayDay(HolidayKind.rest, '劳动节'),

    // ---- 端午：5/31(六)~6/2(一) 放假 3 天，无调休
    '2025-05-31': HolidayDay(HolidayKind.rest, '端午'),
    '2025-06-01': HolidayDay(HolidayKind.rest, '端午'),
    '2025-06-02': HolidayDay(HolidayKind.rest, '端午'),

    // ---- 国庆 + 中秋合并：10/1(三)~10/8(三) 放假 8 天；
    //      9/28(日)、10/11(六) 上班
    '2025-09-28': HolidayDay(HolidayKind.work, '国庆'),
    '2025-10-01': HolidayDay(HolidayKind.rest, '国庆'),
    '2025-10-02': HolidayDay(HolidayKind.rest, '国庆'),
    '2025-10-03': HolidayDay(HolidayKind.rest, '国庆'),
    '2025-10-04': HolidayDay(HolidayKind.rest, '国庆'),
    '2025-10-05': HolidayDay(HolidayKind.rest, '国庆'),
    '2025-10-06': HolidayDay(HolidayKind.rest, '国庆'),
    '2025-10-07': HolidayDay(HolidayKind.rest, '国庆'),
    '2025-10-08': HolidayDay(HolidayKind.rest, '国庆'),
    '2025-10-11': HolidayDay(HolidayKind.work, '国庆'),
  },
  2026: {
    // ---- 元旦：1/1(四)~1/3(六) 放假；1/4(日) 上班
    '2026-01-01': HolidayDay(HolidayKind.rest, '元旦'),
    '2026-01-02': HolidayDay(HolidayKind.rest, '元旦'),
    '2026-01-03': HolidayDay(HolidayKind.rest, '元旦'),
    '2026-01-04': HolidayDay(HolidayKind.work, '元旦'),

    // ---- 春节：2/15(日)~2/23(一) 放假 9 天；2/14(六)、2/28(六) 上班
    '2026-02-14': HolidayDay(HolidayKind.work, '春节'),
    '2026-02-15': HolidayDay(HolidayKind.rest, '春节'),
    '2026-02-16': HolidayDay(HolidayKind.rest, '春节'),
    '2026-02-17': HolidayDay(HolidayKind.rest, '春节'),
    '2026-02-18': HolidayDay(HolidayKind.rest, '春节'),
    '2026-02-19': HolidayDay(HolidayKind.rest, '春节'),
    '2026-02-20': HolidayDay(HolidayKind.rest, '春节'),
    '2026-02-21': HolidayDay(HolidayKind.rest, '春节'),
    '2026-02-22': HolidayDay(HolidayKind.rest, '春节'),
    '2026-02-23': HolidayDay(HolidayKind.rest, '春节'),
    '2026-02-28': HolidayDay(HolidayKind.work, '春节'),

    // ---- 清明：4/4(六)~4/6(一) 放假，无调休
    '2026-04-04': HolidayDay(HolidayKind.rest, '清明'),
    '2026-04-05': HolidayDay(HolidayKind.rest, '清明'),
    '2026-04-06': HolidayDay(HolidayKind.rest, '清明'),

    // ---- 劳动节：5/1(五)~5/5(二) 放假；5/9(六) 上班
    '2026-05-01': HolidayDay(HolidayKind.rest, '劳动节'),
    '2026-05-02': HolidayDay(HolidayKind.rest, '劳动节'),
    '2026-05-03': HolidayDay(HolidayKind.rest, '劳动节'),
    '2026-05-04': HolidayDay(HolidayKind.rest, '劳动节'),
    '2026-05-05': HolidayDay(HolidayKind.rest, '劳动节'),
    '2026-05-09': HolidayDay(HolidayKind.work, '劳动节'),

    // ---- 端午：6/19(五)~6/21(日) 放假，无调休
    '2026-06-19': HolidayDay(HolidayKind.rest, '端午'),
    '2026-06-20': HolidayDay(HolidayKind.rest, '端午'),
    '2026-06-21': HolidayDay(HolidayKind.rest, '端午'),

    // ---- 中秋：9/25(五)~9/27(日) 放假，无调休
    '2026-09-25': HolidayDay(HolidayKind.rest, '中秋'),
    '2026-09-26': HolidayDay(HolidayKind.rest, '中秋'),
    '2026-09-27': HolidayDay(HolidayKind.rest, '中秋'),

    // ---- 国庆：10/1(四)~10/7(三) 放假；9/20(日)、10/10(六) 上班
    '2026-09-20': HolidayDay(HolidayKind.work, '国庆'),
    '2026-10-01': HolidayDay(HolidayKind.rest, '国庆'),
    '2026-10-02': HolidayDay(HolidayKind.rest, '国庆'),
    '2026-10-03': HolidayDay(HolidayKind.rest, '国庆'),
    '2026-10-04': HolidayDay(HolidayKind.rest, '国庆'),
    '2026-10-05': HolidayDay(HolidayKind.rest, '国庆'),
    '2026-10-06': HolidayDay(HolidayKind.rest, '国庆'),
    '2026-10-07': HolidayDay(HolidayKind.rest, '国庆'),
    '2026-10-10': HolidayDay(HolidayKind.work, '国庆'),
  },
};

/// 查某一天的官方安排；未录入的年份 / 普通日子返回 null。
HolidayDay? holidayOf(DateTime day) => kOfficialHolidays[day.year]?[dayKey(day)];

/// 是否已录入该年份的官方安排（UI 可据此决定要不要提示"数据未覆盖"）。
bool hasHolidayData(int year) => kOfficialHolidays.containsKey(year);
