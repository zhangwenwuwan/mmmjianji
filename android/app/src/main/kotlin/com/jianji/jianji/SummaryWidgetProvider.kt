package com.jianji.jianji

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * 桌面小组件：显示本月支出 / 收入 / 结余。
 *
 * 数据来源：Flutter 侧用 shared_preferences 写进
 * `FlutterSharedPreferences` 的 `flutter.widget_*` 键。
 * 这样不需要起 Flutter 引擎就能渲染，点一下再打开 App。
 */
class SummaryWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val PREFS = "FlutterSharedPreferences"
        private const val KEY_EXPENSE = "flutter.widget_month_expense"
        private const val KEY_INCOME = "flutter.widget_month_income"
        private const val KEY_LABEL = "flutter.widget_month_label"

        /**
         * 「不要显示金额」标记。开了「隐藏金额」或应用锁时 Flutter 侧会置 true
         * （见 lib/services/widget_bridge.dart）。
         *
         * 为什么小组件也要挡：它贴在桌面上，是**绕过应用锁**的一块屏。
         * 应用锁只拦得住 App 内部，拦不住 RemoteViews。
         */
        private const val KEY_MASKED = "flutter.widget_masked"

        /** Flutter 同步完数据后调这里刷新所有实例 */
        fun refresh(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, SummaryWidgetProvider::class.java)
            )
            if (ids == null || ids.isEmpty()) return
            for (id in ids) render(context, manager, id)
        }

        private fun render(context: Context, manager: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.widget_summary)
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

            val expense = prefs.getLong(KEY_EXPENSE, -1L)
            val income = prefs.getLong(KEY_INCOME, 0L)
            val label = prefs.getString(KEY_LABEL, null)
            val masked = prefs.getBoolean(KEY_MASKED, false)

            val symbol = "¥"
            if (expense < 0) {
                // 还没同步过：引导用户打开 App
                views.setTextViewText(R.id.widget_title, "简记")
                views.setTextViewText(R.id.widget_amount, "打开记一笔")
                views.setTextViewText(R.id.widget_sub, "点这里开始记账")
            } else if (masked) {
                // 隐藏金额 / 应用锁：连标题里的月份都保留，只挡数字。
                views.setTextViewText(
                    R.id.widget_title,
                    if (label.isNullOrEmpty()) "本月支出" else "$label 支出"
                )
                views.setTextViewText(R.id.widget_amount, "••••")
                views.setTextViewText(R.id.widget_sub, "金额已隐藏 · 点按查看")
            } else {
                val net = income - expense
                views.setTextViewText(
                    R.id.widget_title,
                    if (label.isNullOrEmpty()) "本月支出" else "$label 支出"
                )
                views.setTextViewText(R.id.widget_amount, symbol + money(expense))
                views.setTextViewText(
                    R.id.widget_sub,
                    "收入 $symbol${money(income)} · 结余 ${if (net < 0) "-" else ""}$symbol${money(if (net < 0) -net else net)}"
                )
            }

            // 点一下打开 App
            val open = Intent(context, MainActivity::class.java)
            open.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            val pending = PendingIntent.getActivity(
                context, 0, open,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            views.setOnClickPendingIntent(R.id.widget_root, pending)

            manager.updateAppWidget(id, views)
        }

        /** 分 → 带千分位的元字符串 */
        private fun money(cents: Long): String {
            val yuan = cents / 100
            val rest = (cents % 100).toInt()
            val sb = StringBuilder()
            val s = yuan.toString()
            for ((i, ch) in s.withIndex()) {
                if (i > 0 && (s.length - i) % 3 == 0) sb.append(',')
                sb.append(ch)
            }
            return if (rest == 0) sb.toString() else "$sb.${(if (rest < 10) "0$rest" else "$rest")}"
        }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (id in appWidgetIds) render(context, appWidgetManager, id)
    }
}
