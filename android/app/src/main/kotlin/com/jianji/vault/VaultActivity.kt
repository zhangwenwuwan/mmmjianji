package com.jianji.vault

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.fragment.app.FragmentActivity

/**
 * LaClave 密码库宿主 Activity（嵌入简记 APK，无 INTERNET 权限依赖）。
 *
 * 前端产物位于 app/src/main/assets/laclave/dist/，由构建脚本从
 * LaClaveApp/dist-embedded/ 同步过来。
 */
class VaultActivity : FragmentActivity() {

    private lateinit var webView: WebView
    private var bridge: VaultBridge? = null
    private var lastBackAt = 0L

    /** 等待文件选择结果的 WebView 回调（<input type="file"> 触发） */
    private var pendingFileCallback: ValueCallback<Array<Uri>>? = null

    companion object {
        private const val ASSET_URL = "file:///android_asset/laclave/dist/index.html"
        private const val REQUEST_PICK_FILE = 0x4C43 // 'LC'

        fun launch(context: Context) {
            context.startActivity(Intent(context, VaultActivity::class.java))
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 防截屏：默认开启，前端可通过 PrivacyScreen.disable() 按需关闭
        window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            window.decorView.systemUiVisibility = window.decorView.systemUiVisibility and
                    View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv()
        }
        window.statusBarColor = Color.parseColor("#000000")

        webView = WebView(this).apply {
            setBackgroundColor(Color.parseColor("#000000"))
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT
            )
        }
        setContentView(webView)

        webView.settings.apply {
            javaScriptEnabled = true
            allowFileAccess = true
            allowContentAccess = true
            // file:// 下加载同目录 assets 图片/字体/JS 需要
            allowFileAccessFromFileURLs = true
            allowUniversalAccessFromFileURLs = true
            domStorageEnabled = true
            databaseEnabled = true
            // 锁定系统无障碍字号，避免破坏布局。
            // 保持 100：前端 main.tsx 已按「屏宽/392」做过一次整体缩放，
            // 这里再压到 83 会让嵌入版比独立版小约 17%，两端观感不一致。
            textZoom = 100
            cacheMode = WebSettings.LOAD_NO_CACHE
        }
        webView.setOverScrollMode(View.OVER_SCROLL_NEVER)
        webView.isVerticalScrollBarEnabled = false
        webView.isHorizontalScrollBarEnabled = false

        bridge = VaultBridge(this, webView)
        webView.addJavascriptInterface(bridge!!, "AndroidVault")

        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                // 首帧就绪后再通知前端，避免 appStateChange 早于监听器注册
                bridge?.fireEvent("appStateChange", org.json.JSONObject().put("isActive", true))
            }
        }

        // 关键：没有 WebChromeClient 时，前端 <input type="file"> 的 click() 会被 WebView 静默丢弃，
        // 设置页「从 KeePass 导入」「从 CSV 导入」就会表现为「点了没反应」。
        webView.webChromeClient = object : WebChromeClient() {
            override fun onShowFileChooser(
                view: WebView?,
                filePathCallback: ValueCallback<Array<Uri>>?,
                fileChooserParams: FileChooserParams?
            ): Boolean {
                // 上一次选择若未完成，先回收，避免回调泄漏导致后续全部失效
                pendingFileCallback?.onReceiveValue(null)
                pendingFileCallback = filePathCallback

                // 一律用 */* 打开系统文件选择器：
                // .kdbx 没有统一 MIME（常被识别成 application/octet-stream），
                // 按 acceptTypes 过滤会让用户根本选不到文件。类型校验交给前端。
                val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }
                return try {
                    startActivityForResult(
                        Intent.createChooser(intent, "选择文件"),
                        REQUEST_PICK_FILE
                    )
                    true
                } catch (e: Exception) {
                    pendingFileCallback = null
                    filePathCallback?.onReceiveValue(null)
                    false
                }
            }
        }

        webView.loadUrl(ASSET_URL)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_PICK_FILE) {
            val callback = pendingFileCallback
            pendingFileCallback = null
            if (callback != null) {
                val uris: Array<Uri>? = when {
                    resultCode != Activity.RESULT_OK || data == null -> null
                    data.clipData != null -> {
                        val clip = data.clipData!!
                        Array(clip.itemCount) { clip.getItemAt(it).uri }
                    }
                    data.data != null -> arrayOf(data.data!!)
                    else -> null
                }
                callback.onReceiveValue(uris)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onResume() {
        super.onResume()
        bridge?.checkExpiredClipboard()
        bridge?.fireEvent("appStateChange", org.json.JSONObject().put("isActive", true))
    }

    override fun onPause() {
        bridge?.fireEvent("appStateChange", org.json.JSONObject().put("isActive", false))
        super.onPause()
    }

    /**
     * 返回键交给前端处理：先推 backButton 事件，
     * 前端若无弹窗可关会自行调用 App.exitApp() → finish()。
     * 这里不直接 finish，避免打断前端的逐级返回拦截逻辑。
     */
    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            val now = System.currentTimeMillis()
            // 兜底：1.5 秒内连按两次返回直接退出。
            // 防止前端 JS 异常 / bridge 未建立时，返回键被这里吞掉导致卡死。
            if (now - lastBackAt < 1500) {
                finish()
                return true
            }
            lastBackAt = now
            bridge?.fireEvent("backButton")
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        pendingFileCallback?.onReceiveValue(null)
        pendingFileCallback = null
        webView.apply {
            removeJavascriptInterface("AndroidVault")
            destroy()
        }
        super.onDestroy()
    }
}
