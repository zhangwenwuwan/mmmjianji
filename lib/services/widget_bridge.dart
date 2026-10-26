import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/currency.dart';
import '../state/ledger_state.dart';
import 'app_log.dart';

/// 把本月概览推给桌面小组件。
///
/// 数据走 shared_preferences（Flutter 侧键名会自动加 `flutter.` 前缀，
/// 原生侧读 `flutter.widget_*`），所以小组件不需要启动 Flutter 引擎。
/// 同步完再通过 MethodChannel 通知原生刷新一次。
class WidgetBridge {
  WidgetBridge._();

  static const _ch = MethodChannel('jianji/widget');

  /// 节流：1.5 秒内多次改动只同步一次
  static DateTime? _last;

  static Future<void> sync(WidgetRef ref, {bool force = false}) async {
    final now = DateTime.now();
    if (!force &&
        _last != null &&
        now.difference(_last!) < const Duration(milliseconds: 1500)) {
      return;
    }
    _last = now;

    try {
      final store = await ref.read(storeProvider.future);
      final book = await ref.read(activeBookProvider.future);
      final rates = await ref.read(ratesProvider.future);
      final month = ref.read(monthProvider);

      final entries = await store.entriesOfMonth(book.id, month);
      final pockets = await store.allPockets();
      final currencyOf = {for (final p in pockets) p.id: p.currency};

      var income = 0;
      var expense = 0;
      for (final e in entries) {
        if (e.flow != 'in' && e.flow != 'out') continue;
        // 和小部件展示口径保持一致：不计入收支的不算
        if (e.excludeFromStats) continue;
        final from = e.currency ?? currencyOf[e.pocketId] ?? book.baseCurrency;
        final base = toBaseCents(e.amountCents, from, book.baseCurrency, rates);
        if (e.flow == 'in') {
          income += base;
        } else {
          expense += base;
        }
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('widget_month_expense', expense);
      await prefs.setInt('widget_month_income', income);
      await prefs.setString('widget_month_label', '${month.month} 月');

      // 通知原生刷新（没有小组件实例时原生会直接返回）
      try {
        await _ch.invokeMethod<bool>('refresh');
      } on MissingPluginException {
        // 桌面/测试环境没有这个通道，忽略
      } catch (e) {
        AppLog.warn('widget', '刷新小组件失败: $e');
      }
    } catch (e) {
      AppLog.warn('widget', '同步小组件数据失败: $e');
    }
  }
}
