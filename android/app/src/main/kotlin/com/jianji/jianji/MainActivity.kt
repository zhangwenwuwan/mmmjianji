package com.jianji.jianji

import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * 两条原生通道：
 *  - `jianji/widget`：Flutter 同步完本月数据后让桌面小组件刷新。
 *  - `jianji/update`：应用内更新的「安装」那一步。
 *
 * ⚠️ 2026-10-25：基类从 FlutterActivity 换成 **FlutterFragmentActivity**。
 * local_auth（指纹/面容）在 Android 上要靠 Fragment + BiometricPrompt，
 * FlutterActivity 没有 Fragment 容器，调用会直接抛
 * "FlutterFragmentActivity required for local_auth" 。
 */
class MainActivity : FlutterFragmentActivity() {

    private val widgetChannel = "jianji/widget"
    private val updateChannel = "jianji/update"
    private val schemeChannel = "jianji/scheme"

    /// scheme 通道引用，热启动 onNewIntent 时直接把原始 URI 推给 Dart。
    private var schemeMethodChannel: MethodChannel? = null

    /// 冷启动时带进来的 jianji:// 链接。
    /// 不能在 configureFlutterEngine 里直接 invokeMethod 推给 Dart——
    /// 那一刻 Dart 的 MethodCallHandler 还没挂上，消息会被静默丢弃。
    /// 所以这里只存着，等 Dart 就绪后主动来取（getInitialScheme）。
    private var pendingScheme: String? = null

    /**
     * 引擎在 getInitialRoute() 返回 null 时会拿 launch intent 的 data 当初始
     * 路由。框架的 _initialRouteName 又会无条件覆盖 MaterialApp.initialRoute，
     * 结果：带 jianji:// 链接冷启动时首页根本不进栈，目标页成了根路由，
     * 按返回直接黑屏/退出（真机实锤）。
     *
     * 覆盖成 "/"，引擎就走普通启动；链接存在 [pendingScheme] 里，
     * 由 Dart 侧 pullInitial 取走后推在首页之上。
     */
    override fun getInitialRoute(): String = "/"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // 冷启动链接：launch intent 里若带了 jianji://，先存起来等 Dart 来取
        intent?.let { if (it.data?.scheme == "jianji") pendingScheme = it.dataString }
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, schemeChannel).also {
            schemeMethodChannel = it
        }.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialScheme" -> {
                    result.success(pendingScheme)
                    pendingScheme = null
                }
                else -> result.notImplemented()
            }
        }


        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, widgetChannel)
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canInstall" -> result.success(canInstall())

                    "openInstallSettings" -> {
                        try {
                            openInstallSettings()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("open_failed", e.message, null)
                        }
                    }

                    // 校验 + 安装。**必须放后台线程**：27MB 要完整拷贝一次
                    // （PackageInstaller 会写到 /data/app/vmdl*.tmp），
                    // 在主线程做会卡出一个肉眼可见的停顿。
                    "installApk" -> {
                        val path = call.argument<String>("path")
                        val sha256 = call.argument<String>("sha256")
                        Thread {
                            val status = installApk(path, sha256)
                            runOnUiThread { result.success(status) }
                        }.start()
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 热启动深链接（2026-11-09 真机实锤，绕了四轮弯的最终方案）：
     *
     * Flutter 引擎的 FlutterActivity.onNewIntent 会把带 data 的 intent 自动
     * 转成 flutter/navigation 的 pushRouteInformation；而 WidgetsApp 收到后
     * 会**剥掉 scheme**（jianji:///voice → "/voice"、旧式 jianji://voice →
     * "/"，后者直接命中 home 又压一个首页盖住目标页）。同时我们自建通道也
     * 推一次 → 一次链接开两个页面、按返回要按好几次。
     *
     * 解法：给 super 传一个**剥掉 data 的副本**，引擎就不会转发（插件仍能
     * 收到 onNewIntent）；原始完整 URI 由 jianji/scheme 通道推给 Dart。
     * 冷启动的初始路由则由 main.dart 显式 initialRoute:'/' 兜住。
     */
    override fun onNewIntent(intent: Intent) {
        val uri = intent.dataString
        super.onNewIntent(Intent(intent).apply { data = null })
        if (intent.data?.scheme == "jianji" && !uri.isNullOrEmpty()) {
            schemeMethodChannel?.invokeMethod("onScheme", uri)
        }
    }

    private fun canInstall(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            packageManager.canRequestPackageInstalls()
        } else {
            true
        }

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:$packageName")
                )
            )
        }
    }

    /**
     * 校验 SHA-256 → 用 PackageInstaller 会话安装。
     *
     * 为什么不用「FileProvider + ACTION_VIEW」这条更常见的路：
     * 2026-10-29 在 OPPO PBEM00（Android 10）上实测，URI 能生成、安装器也被拉起，
     * 但安装器报「解析程序包时出现问题」—— 它读不到 content:// 的内容
     * （部分 ROM 的安装器对 grant 处理不规范）。
     * PackageInstaller 是系统自己的安装通道，把 APK 内容直接写进安装会话，
     * 不经过「另一个进程读我的文件」这一步，兼容性最好，Google Play 内部更新也用它。
     *
     * 返回状态码：ok / missing_file / hash_mismatch / no_permission / error:*
     */
    private fun installApk(path: String?, expectedSha256: String?): String {
        if (path.isNullOrEmpty()) return "missing_file"
        val file = File(path)
        if (!file.exists() || file.length() == 0L) return "missing_file"

        if (!expectedSha256.isNullOrEmpty()) {
            val actual = try {
                sha256Of(file)
            } catch (e: Exception) {
                return "error:hash:${e.message}"
            }
            if (!actual.equals(expectedSha256, ignoreCase = true)) {
                return "hash_mismatch"
            }
        }

        if (!canInstall()) return "no_permission"

        val installer = packageManager.packageInstaller
        var sessionId = -1
        return try {
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            )
            // 只装自己：显式声明包名，系统据此判断是升级而不是新装
            params.setAppPackageName(packageName)
            sessionId = installer.createSession(params)

            installer.openSession(sessionId).use { session ->
                file.inputStream().use { input ->
                    session.openWrite("base.apk", 0, file.length()).use { out ->
                        input.copyTo(out, 64 * 1024)
                        session.fsync(out)
                    }
                }
                // 安装是**异步**的：commit 只负责提交，成功/失败由系统稍后广播。
                // 必须接这个回执，否则失败时界面毫无反应（只能靠翻 logcat）。
                val pending = PendingIntent.getBroadcast(
                    this,
                    sessionId,
                    Intent(this, InstallResultReceiver::class.java)
                        .setPackage(packageName),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                session.commit(pending.intentSender)
            }
            "ok"
        } catch (e: Exception) {
            if (sessionId >= 0) {
                runCatching { installer.abandonSession(sessionId) }
            }
            "error:session:${e.message}"
        }
    }

    private fun sha256Of(file: File): String {
        val md = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(1 shl 16)
            while (true) {
                val n = input.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }
}
