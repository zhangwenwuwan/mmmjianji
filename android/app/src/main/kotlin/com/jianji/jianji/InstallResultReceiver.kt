package com.jianji.jianji

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.util.Log
import android.widget.Toast

/**
 * PackageInstaller 安装会话的结果回执。
 *
 * 为什么需要它：`session.commit()` 只是把包装进安装会话，真正装成功还是失败
 * 是**异步**由系统通知的。不接这个回执的话，失败时界面上什么都不会发生
 * （2026-10-29 实测：点「下载并更新」后弹窗关闭、安装器连界面都没出现，
 * 只能靠翻 logcat 猜）。
 *
 * 生产环境可以改成写日志/发通知；现在用 Toast + Log，真机上能直接看到
 * status 码（PackageInstaller.STATUS_FAILURE_* 会附带原因文字）。
 */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, Int.MIN_VALUE)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: ""

        // 有些 ROM（实测 OPPO PBEM00 / Android 10）回执里不带 extras，只发一个空广播。
        // 这种情况静默 —— 真正的结果看包的 lastUpdateTime / PACKAGE_ADDED，
        // 弹一句 "status=-2147483648" 只会吓到用户。
        if (status == Int.MIN_VALUE) {
            Log.i("jianji", "install result received without status")
            return
        }
        Log.i("jianji", "install status=$status $message")
        val ok = status == PackageInstaller.STATUS_SUCCESS
        Toast.makeText(
            context,
            if (ok) "安装完成" else "安装失败（$status）$message",
            Toast.LENGTH_LONG
        ).show()
    }
}
