package com.jianji.vault

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * LaClave 嵌入简记后的原生桥。
 *
 * 前端通过 window.LaClaveBridge.invoke(method, args) 调用，
 * 该 shim（在 JS 侧）把请求转成 AndroidVault.invoke(method, argsJson, callbackId)，
 * 原生完成后 evaluateJavascript("window.__laclaveResolve(...)") 回传。
 *
 * 安全边界：
 *  - Android Keystore 按 UID 隔离：独立 APK（com.jc.laclave）的 laclave_kek 无法在
 *    简记（com.jianji.ledger）中复用。因此旧账本不能靠拷贝数据文件读回，
 *    必须走应用内「加密备份导出 → 导入」（该备份用用户口令派生密钥，与 KEK 无关）。
 *    内嵌版首次启动会生成自己的 laclave_kek。
 *  - 生物识别走 BiometricPrompt 真正异步校验，成功后才 resolve。
 */
class VaultBridge(
    private val activity: FragmentActivity,
    private val webView: WebView
) {

    companion object {
        private const val TAG = "VaultBridge"
        const val KEY_ALIAS = "laclave_kek"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val AES_GCM = "AES/GCM/NoPadding"
        private const val GCM_TAG = 128
        private const val PREFS_NAME = "CapacitorStorage"
        private const val SENSITIVE_CLIP_LABEL = "LaClave:Secret"
        private const val CLIP_TTL_MS = 60_000L

        private var lastCopiedAt = 0L
        private val mainHandler = Handler(Looper.getMainLooper())
        private var clearClipRunnable: Runnable? = null
    }

    private val prefs: SharedPreferences = activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    /**
     * 导出目录：宿主 targetSdk >= 30 时写不了公共 /storage/emulated/0/Documents
     * （分区存储且未申请 MANAGE_EXTERNAL_STORAGE），所以先探测可写性，不可写回退到应用专属目录。
     */
    private val documentsDir: File by lazy {
        val publicDir = File(
            android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOCUMENTS),
            "LaClave"
        )
        if (isDirWritable(publicDir)) publicDir else fallbackDocumentsDir
    }

    private val fallbackDocumentsDir: File by lazy {
        File(
            activity.getExternalFilesDir(android.os.Environment.DIRECTORY_DOCUMENTS) ?: activity.filesDir,
            "LaClave"
        ).also { runCatching { it.mkdirs() } }
    }

    private fun isDirWritable(dir: File): Boolean = runCatching {
        if (!dir.exists() && !dir.mkdirs()) return false
        val probe = File(dir, ".write_probe")
        probe.writeText("1")
        probe.delete()
        true
    }.getOrDefault(false)

    fun checkExpiredClipboard() {
        if (lastCopiedAt <= 0) return
        if (System.currentTimeMillis() - lastCopiedAt < CLIP_TTL_MS) return
        val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return
        if (cm.hasPrimaryClip() && cm.primaryClipDescription?.label == SENSITIVE_CLIP_LABEL) {
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) cm.clearPrimaryClip()
                else cm.setPrimaryClip(ClipData.newPlainText("", ""))
            }
            lastCopiedAt = 0
        }
    }

    @JavascriptInterface
    fun invoke(method: String, argsJson: String?, callbackId: String) {
        val args = try {
            if (argsJson.isNullOrEmpty() || argsJson == "null") JSONObject() else JSONObject(argsJson)
        } catch (e: Exception) {
            reject(callbackId, "参数解析失败: ${e.message}")
            return
        }

        // 生物识别是异步方法，单独走异步分支
        if (method == "NativeBiometric.verifyIdentity") {
            verifyBiometricAsync(args, callbackId)
            return
        }

        try {
            resolve(callbackId, dispatch(method, args))
        } catch (e: Exception) {
            Log.w(TAG, "invoke($method) failed", e)
            reject(callbackId, e.message ?: e.javaClass.simpleName)
        }
    }

    private fun resolve(callbackId: String, json: String) {
        // 关键：invoke() 运行在 WebView 的 JavaBridge 线程，而 WebView 方法必须在主线程调用。
        // 直接在桥线程 evaluateJavascript 会抛 "WebView methods must be called on the same thread"，
        // 被 runCatching 静默吞掉后 JS Promise 永远不 resolve → 初始化卡死。
        mainHandler.post {
            runCatching {
                webView.evaluateJavascript("window.__laclaveResolve('$callbackId',true,$json)", null)
            }.onFailure { Log.w(TAG, "resolve($callbackId) failed", it) }
        }
    }

    private fun reject(callbackId: String, message: String) {
        val msg = JSONObject().put("message", message).toString()
        mainHandler.post {
            runCatching {
                webView.evaluateJavascript("window.__laclaveResolve('$callbackId',false,$msg)", null)
            }.onFailure { Log.w(TAG, "reject($callbackId) failed", it) }
        }
    }

    fun fireEvent(event: String, payload: JSONObject = JSONObject()) {
        mainHandler.post {
            runCatching {
                webView.evaluateJavascript("window.__laclaveFireEvent && window.__laclaveFireEvent('$event',$payload)", null)
            }.onFailure { Log.w(TAG, "fireEvent($event) failed", it) }
        }
    }

    private fun dispatch(method: String, a: JSONObject): String {
        return when (method) {
            // ---------- Capacitor 核心 ----------
            "App.exitApp" -> { mainHandler.post { activity.finish() }; "null" }
            "App.getInfo" -> JSONObject()
                .put("name", "La Clave")
                .put("id", "com.jianji.ledger")
                .put("version", "1.3.3")
                .put("build", "24").toString()
            "App.removeAllListeners", "App.addListener" -> "null"

            // ---------- Preferences ----------
            "Preferences.get" -> {
                val key = a.getString("key")
                JSONObject().put("value", if (prefs.contains(key)) prefs.getString(key, null) else null).toString()
            }
            "Preferences.set" -> {
                prefs.edit().putString(a.getString("key"), a.getString("value")).apply()
                "null"
            }
            "Preferences.remove" -> {
                prefs.edit().remove(a.getString("key")).apply()
                "null"
            }
            "Preferences.keys" -> {
                // Capacitor 约定返回 string[]，之前塞的是字符串化数组，调用方拿到的不是数组
                val arr = JSONArray()
                for (k in prefs.all.keys) arr.put(k)
                JSONObject().put("keys", arr).toString()
            }
            "Preferences.clear" -> { prefs.edit().clear().apply(); "null" }
            "Preferences.migrate", "Preferences.removeOld" -> "null"

            // ---------- Filesystem ----------
            "Filesystem.readFile" -> {
                val f = resolvePath(a)
                if (!f.exists()) throw IllegalArgumentException("文件不存在: ${f.path}")
                val raw = f.readBytes()
                val enc = a.optString("encoding", "")
                val data = if (enc == "utf8" || enc == "UTF8") String(raw, Charsets.UTF_8)
                           else Base64.encodeToString(raw, Base64.NO_WRAP)
                JSONObject().put("data", data).toString()
            }
            "Filesystem.writeFile" -> {
                val f = resolvePath(a)
                val enc = a.optString("encoding", "")
                val bytes = if (enc == "utf8" || enc == "UTF8")
                    a.getString("data").toByteArray(Charsets.UTF_8)
                else Base64.decode(a.getString("data"), Base64.NO_WRAP)

                val isDocuments = a.optString("directory", "DOCUMENTS") == "DOCUMENTS"
                val target = try {
                    f.parentFile?.mkdirs()
                    f.writeBytes(bytes)
                    f
                } catch (e: Exception) {
                    if (!isDocuments) throw e
                    // 兜底：公共 Documents 写不进去时改用应用专属目录，至少导出不失败
                    val fallback = File(fallbackDocumentsDir, f.name)
                    fallback.parentFile?.mkdirs()
                    fallback.writeBytes(bytes)
                    fallback
                }
                JSONObject()
                    .put("uri", target.toURI().toString())
                    .put("path", target.absolutePath)
                    .toString()
            }
            "Filesystem.deleteFile" -> {
                val f = resolvePath(a)
                if (f.exists() && !f.delete()) throw IllegalStateException("删除失败: ${f.path}")
                "null"
            }
            "Filesystem.mkdir" -> {
                val f = resolvePath(a)
                if (!f.exists() && !f.mkdirs()) throw IllegalStateException("创建目录失败: ${f.path}")
                "null"
            }
            "Filesystem.readdir" -> {
                val f = resolvePath(a)
                if (!f.exists() || !f.isDirectory) throw IllegalArgumentException("目录不存在: ${f.path}")
                val arr = JSONArray()
                for (child in (f.listFiles() ?: emptyArray()).sortedBy { it.name }) {
                    arr.put(JSONObject()
                        .put("name", child.name)
                        .put("type", if (child.isDirectory) "directory" else "file")
                        .put("size", if (child.isFile) child.length() else 0)
                        .put("uri", child.toURI().toString()))
                }
                JSONObject().put("files", arr).toString()
            }
            "Filesystem.stat" -> {
                val f = resolvePath(a)
                if (!f.exists()) throw IllegalArgumentException("文件不存在: ${f.path}")
                JSONObject()
                    .put("type", if (f.isDirectory) "directory" else "file")
                    .put("size", if (f.isFile) f.length() else 0)
                    .put("mtime", f.lastModified())
                    .put("uri", f.toURI().toString()).toString()
            }

            // ---------- Security: Keystore ----------
            "LaClaveSecurity.getOrGenerateWrappedKey" -> getOrGenerateWrappedKey()
            "LaClaveSecurity.unwrapKey" -> unwrapKey(a.getString("wrappedDek"), a.getString("wrapIv"))

            // ---------- Security: 剪贴板 ----------
            "LaClaveSecurity.copySensitive" -> {
                copySensitive(a.getString("text"))
                JSONObject().put("success", true).put("ttlMs", CLIP_TTL_MS).toString()
            }
            "LaClaveSecurity.clearClipboard" -> {
                clearClipboardNow()
                JSONObject().put("success", true).toString()
            }
            "Clipboard.write" -> { copySensitive(a.optString("string")); "null" }
            "Clipboard.read" -> {
                val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
                val s = cm?.primaryClip?.getItemAt(0)?.text?.toString() ?: ""
                JSONObject().put("value", s).toString()
            }

            // ---------- 状态栏 / 防截屏 ----------
            "StatusBar.setOverlaysWebView" -> "null"
            "StatusBar.setStyle" -> {
                val dark = a.optString("style") == "DARK" ||
                           a.optJSONObject("style")?.optString("style") == "DARK"
                mainHandler.post {
                    val w = activity.window
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        @Suppress("DEPRECATION")
                        var flags = w.decorView.systemUiVisibility
                        @Suppress("DEPRECATION")
                        flags = if (dark) flags and View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR.inv()
                                else flags or View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
                        @Suppress("DEPRECATION")
                        w.decorView.systemUiVisibility = flags
                    }
                }
                "null"
            }
            "StatusBar.setBackgroundColor" -> {
                val color = a.optString("color")
                mainHandler.post {
                    runCatching {
                        @Suppress("DEPRECATION")
                        activity.window.statusBarColor = android.graphics.Color.parseColor(color)
                    }
                }
                "null"
            }
            "StatusBar.hide" -> {
                mainHandler.post { activity.window.addFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN) }
                "null"
            }
            "StatusBar.show" -> {
                mainHandler.post { activity.window.clearFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN) }
                "null"
            }
            "PrivacyScreen.enable" -> {
                mainHandler.post {
                    activity.window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
                }
                "null"
            }
            "PrivacyScreen.disable" -> {
                mainHandler.post { activity.window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
                "null"
            }

            // ---------- 生物识别可用性 ----------
            "NativeBiometric.isAvailable" -> {
                val ok = BiometricManager.from(activity)
                    .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG) ==
                          BiometricManager.BIOMETRIC_SUCCESS
                JSONObject().put("isAvailable", ok).toString()
            }

            // ---------- 触感 ----------
            "Haptics.impact", "Haptics.notification" -> { performHaptic(); "null" }
            "Haptics.selectionStart", "Haptics.selectionChanged", "Haptics.selectionEnd" -> "null"

            else -> throw IllegalArgumentException("未知的 bridge 方法: $method")
        }
    }

    private fun resolvePath(a: JSONObject): File {
        val rel = a.getString("path").trimStart('/')
        return when (a.optString("directory", "DOCUMENTS")) {
            "CACHE" -> File(activity.cacheDir, rel)
            "DATA" -> File(activity.filesDir, rel)
            "EXTERNAL", "EXTERNAL_STORAGE" -> File(activity.getExternalFilesDir(null), rel)
            else -> File(documentsDir, rel)
        }
    }

    // ================= Keystore =================

    @Synchronized
    private fun getOrCreateKek(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val spec = KeyGenParameterSpec.Builder(KEY_ALIAS,
                    KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256).setIsStrongBoxBacked(true).build()
                kg.init(spec)
                return kg.generateKey()
            } catch (_: Exception) { /* 回退标准 TEE */ }
        }
        val spec = KeyGenParameterSpec.Builder(KEY_ALIAS,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256).build()
        kg.init(spec)
        return kg.generateKey()
    }

    private fun getOrGenerateWrappedKey(): String {
        val kek = getOrCreateKek()
        val dek = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val cipher = Cipher.getInstance(AES_GCM).apply { init(Cipher.ENCRYPT_MODE, kek) }
        return JSONObject()
            .put("dek", b64(dek))
            .put("wrappedDek", b64(cipher.doFinal(dek)))
            .put("wrapIv", b64(cipher.iv))
            .put("type", "ANDROID_KEYSTORE_AES_GCM").toString()
    }

    private fun unwrapKey(wrappedDek: String, wrapIv: String): String {
        if (wrappedDek.isEmpty() || wrapIv.isEmpty()) throw IllegalArgumentException("缺少 wrappedDek 或 wrapIv")
        val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        if (!ks.containsAlias(KEY_ALIAS)) throw IllegalStateException("KEYSTORE_KEY_NOT_FOUND")
        val cipher = Cipher.getInstance(AES_GCM).apply {
            init(Cipher.DECRYPT_MODE, getOrCreateKek(), GCMParameterSpec(GCM_TAG, b64dec(wrapIv)))
        }
        return JSONObject().put("dek", b64(cipher.doFinal(b64dec(wrappedDek)))).toString()
    }

    // ================= 剪贴板 =================

    private fun copySensitive(text: String) {
        mainHandler.post {
            val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return@post
            val clip = ClipData.newPlainText(SENSITIVE_CLIP_LABEL, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                clip.description.extras = PersistableBundle().apply {
                    putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true)
                }
            }
            cm.setPrimaryClip(clip)
            lastCopiedAt = System.currentTimeMillis()
            clearClipRunnable?.let { mainHandler.removeCallbacks(it) }
            clearClipRunnable = Runnable { clearClipboardNow() }
            mainHandler.postDelayed(clearClipRunnable!!, CLIP_TTL_MS)
        }
    }

    private fun clearClipboardNow() {
        mainHandler.post {
            val cm = activity.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager ?: return@post
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) cm.clearPrimaryClip()
                else cm.setPrimaryClip(ClipData.newPlainText("", ""))
            }
            lastCopiedAt = 0
            clearClipRunnable?.let { mainHandler.removeCallbacks(it) }
        }
    }

    private fun performHaptic() {
        mainHandler.post {
            @Suppress("DEPRECATION")
            val v = activity.getSystemService(Context.VIBRATOR_SERVICE) as? android.os.Vibrator ?: return@post
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v.vibrate(android.os.VibrationEffect.createOneShot(20, 80))
            } else {
                @Suppress("DEPRECATION")
                v.vibrate(20)
            }
        }
    }

    // ================= 生物识别（异步） =================

    private fun verifyBiometricAsync(a: JSONObject, callbackId: String) {
        val reason = a.optString("reason", "验证身份")
        val title = a.optString("title", "安全验证")
        // BiometricPrompt 必须在主线程创建并 authenticate，桥线程直接调用不会弹窗
        mainHandler.post {
            try {
                val canAuth = BiometricManager.from(activity)
                    .canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                if (canAuth != BiometricManager.BIOMETRIC_SUCCESS) {
                    reject(callbackId, "BIOMETRIC_UNAVAILABLE")
                    return@post
                }
                val executor = ContextCompat.getMainExecutor(activity)
                val prompt = BiometricPrompt(activity, executor, object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        resolve(callbackId, "null")
                    }
                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                        reject(callbackId, "BIOMETRIC_ERROR: $errString")
                    }
                    override fun onAuthenticationFailed() {
                        // 单次失败不结束，允许用户重试；连续失败由系统回调 onAuthenticationError
                    }
                })
                prompt.authenticate(
                    BiometricPrompt.PromptInfo.Builder()
                        .setTitle(title)
                        .setSubtitle(reason)
                        .setNegativeButtonText("取消")
                        .build()
                )
            } catch (e: Exception) {
                Log.w(TAG, "verifyBiometricAsync failed", e)
                reject(callbackId, e.message ?: e.javaClass.simpleName)
            }
        }
    }

    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.NO_WRAP)
    private fun b64dec(s: String) = Base64.decode(s, Base64.NO_WRAP)
}
