import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/currency.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
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
      // ⚠️ 小组件永远显示**当前自然月**，不跟 monthProvider 走（审计 P3-12）：
      // monthProvider 是「首页正在看哪个月」。用户翻到 3 月看一眼就退到后台，
      // 小组件会一直贴 3 月的数在桌面上 —— 标签虽写着「3 月」，但贴在桌面上
      // 没人会去读那三个字，只会当成"这个月花了这么多"。
      final month = DateTime(now.year, now.month);

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
        final base = toBaseCents(e.statsCents, from, book.baseCurrency, rates);
        if (e.flow == 'in') {
          income += base;
        } else {
          expense += base;
        }
      }

      final prefs = await SharedPreferences.getInstance();
      // 隐私闸门（2026-11-08 审计 P2-4）：
      // 桌面小组件是**绕过应用锁**的一块玻璃 —— 只要写在桌面上，谁拿起手机
      // 都能看见「本月支出 8,432」。所以两种情况下都不写真实金额：
      //   ① 用户开了「隐藏金额」；
      //   ② 用户开了应用锁（锁的意义就是不让旁人看到账目，小组件不该例外）。
      // 注意是「覆盖成 0」而不是「跳过不写」：跳过的话，之前写进去的金额会
      // 留在 prefs 里，下次小组件刷新（重启、系统重绘）又把它们捞出来显示。
      final settings = ref.read(settingsProvider);
      final masked = settings.hideAmounts || settings.lockEnabled;
      await prefs.setBool('widget_masked', masked);
      await prefs.setInt('widget_month_expense', masked ? 0 : expense);
      await prefs.setInt('widget_month_income', masked ? 0 : income);
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
