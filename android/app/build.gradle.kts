import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// release 签名配置：读 android/key.properties（含 keystore 路径/别名/密码）。
// 这个文件不进版本库；丢了它 = release 包签不了名。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.jianji.jianji"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications v19+ 需要 Java 8+ API 反糖化
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        create("release") {
            // 【硬要求】没有 key.properties 就直接报错，**绝不静默退回 debug 签名**。
            // debug 签名的 release 包能装、能跑、UI 完全看不出区别，
            // 直到某天想覆盖升级时才发现「装不上」（签名不一致），那时已经晚了。
            // 2026-10-26 之前的包全是用 debug key 签的，就是吃了这个亏。
            if (!keystorePropertiesFile.exists()) {
                throw GradleException(
                    "缺少 android/key.properties —— release 包必须用 jianji-release.jks 签名。" +
                        " 见交接清单「签名」一节。"
                )
            }
            storeFile = file(keystoreProperties.getProperty("storeFile"))
            storePassword = keystoreProperties.getProperty("storePassword")
            keyAlias = keystoreProperties.getProperty("keyAlias")
            keyPassword = keystoreProperties.getProperty("keyPassword")
        }
    }

    defaultConfig {
        applicationId = "com.jianji.ledger"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // 只交付 arm64-v8a。
        //
        // ⚠️ 别只依赖 `flutter build apk --target-platform android-arm64`：
        // 那个参数只决定编译哪个 ABI 的 libapp.so / libflutter.so，
        // 插件 AAR 里的 .so 仍由 AGP 按 abiFilters 全量合并。
        // Flutter Gradle 插件在 apply() 阶段会先执行 configureAbis()：
        //   abiFilters.clear(); abiFilters.addAll(PLATFORM_ABI_LIST)  // 3 个 ABI
        // 所以这里必须再 clear() 一次（本块在插件 apply 之后求值，能覆盖它）。
        // 2026-11-06 实测：offline ASR 的 libonnxruntime.so 被打了 arm64/v7a/x86_64
        // 三份且 Stored 不压缩，APK 从 ~28MB 直接涨到 173MB。
        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }
    }

    // ABI 过滤之外的第二道保险：就算将来有人换了构建方式（或 Flutter 插件改了
    // configureAbis 的时机），也不要把非 arm64 的原生库塞进 APK。
    // 同时写 lib/<abi>/** 与 **/<abi>/** 两种形态，兼容不同 AGP 版本的匹配基准。
    packaging {
        jniLibs {
            excludes += setOf(
                "lib/armeabi-v7a/**", "**/armeabi-v7a/**",
                "lib/x86/**", "**/x86/**",
                "lib/x86_64/**", "**/x86_64/**",
            )
        }
    }

    buildTypes {
        release {
            // 正式签名（jianji-release.jks）。**不要再改回 debug**。
            signingConfig = signingConfigs.getByName("release")

            // ⚠️ 必须关掉 R8 收缩/混淆（2026-10-23 实测，别顺手打开）
            //
            // shared_preferences_android 2.5.x 起改用 Dart JNI 直调 Java 方法，
            // 而 JNI 是按**字面签名**在运行时查找方法的。R8 会把
            //   kotlin.coroutines.Continuation  改名成  W0.c
            // dex 里的真实签名于是变成 (String, List, LW0/c;)Object，
            // 而 Dart 侧仍在找 (String, List, Lkotlin/coroutines/Continuation;)Object
            // → NoSuchMethodError → SharedPreferences 整块失效
            // → **所有设置每次启动退回默认值，而 UI 完全看不出异常**（只像"设置被重置"）。
            //
            // 这个 bug 只在 release 出现（debug 不跑 R8），排查极费时间。
            // 若将来确实需要开 R8，至少要为 JNI 反射的目标补 keep 规则：
            //   -keep class kotlin.coroutines.Continuation { *; }
            //   -keep class io.flutter.plugins.sharedpreferences.** { *; }
            isMinifyEnabled = false
            isShrinkResources = false
        }

        // profile 也用正式签名（2026-11-08 加）。
        //
        // 原因：真机验证要**覆盖安装**在 release 之上，否则
        // `INSTALL_FAILED_UPDATE_INCOMPATIBLE`；卸载重装会清掉数据库 ——
        // 拿自己的账本当测试数据时这等于删库。profile 比 release 快得多，
        // 是最适合做视觉/交互验证的档位，所以必须能直接盖上去。
        //
        // ⚠️ 不能写 `profile { ... }`：Flutter 的 profile 不是 AGP 内建 buildType，
        // 是 Flutter Gradle 插件在运行时注册的，Kotlin DSL 编译期没有这个访问器
        // （报 "Expression 'profile' cannot be invoked as a function"）。
        // 用 configureEach 按名字兜住 —— 对后注册的 buildType 同样生效。
        configureEach {
            if (name == "profile") {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // FileProvider：应用内更新要把下载好的 APK 以 content:// 交给系统安装器。
    // 别的插件大概率已经传递引入了 androidx.core，但显式声明才不会因为
    // 某个插件换实现/降版本而编译失败。版本跟随 compileSdk 34+ 的稳定线。
    implementation("androidx.core:core-ktx:1.13.1")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
