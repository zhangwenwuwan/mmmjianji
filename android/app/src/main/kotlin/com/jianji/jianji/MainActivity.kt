package com.jianji.jianji

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 只加了一条通道：Flutter 同步完本月数据后让桌面小组件刷新。
 * 小组件本身不启动 Flutter 引擎，避免为了显示一个数字把整个 App 拉起来。
 *
 * ⚠️ 2026-10-25：基类从 FlutterActivity 换成 **FlutterFragmentActivity**。
 * local_auth（指纹/面容）在 Android 上要靠 Fragment + BiometricPrompt，
 * FlutterActivity 没有 Fragment 容器，调用会直接抛
 * "FlutterFragmentActivity required for local_auth" 。
 */
class MainActivity : FlutterFragmentActivity() {

    private val channel = "jianji/widget"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "refresh" -> {
                        try {
                            SummaryWidgetProvider.refresh(this)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("refresh_failed", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
