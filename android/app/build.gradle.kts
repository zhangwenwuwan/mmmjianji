plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.jianji.ledger"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

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
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
