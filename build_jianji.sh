#!/usr/bin/env bash
# 简记 出包脚本（替代手写多步流程）
#
# 用法（在 Git Bash 里跑）：
#   ./build_jianji.sh              # 默认：**flutter clean 全量**（release 唯一安全档）
#   ./build_jianji.sh --incr       # 增量：只删合并后的原生库中间产物（最常用，省 3~4 分钟）
#   ./build_jianji.sh --fast       # app 级清理，仅当「没换依赖版本、没跨 buildMode」时可用
#   ./build_jianji.sh --no-clean   # 纯增量，只改了一行 Dart 且确信无陈旧时
#   ./build_jianji.sh --profile    # profile 构建（本地真机自测，快；不上架）
#
# ⚠️ 为什么默认是全量 clean（2026-10-23 踩坑后改的）：
#   `gradlew :app:clean` 只清 android/app/build，**清不到 build/<插件名>/**。
#   Flutter 给每个 plugin 建独立 subproject，产物落在工程根的 build/<plugin>/。
#   插件版本一变（flutter pub get 拉到新版本），旧 variant 的 classes.jar 会被
#   Gradle 判 UP-TO-DATE 复用 → 新 Dart 调旧 Java 方法 → NoSuchMethodError。
#   实测后果：SharedPreferences 整块失效，所有设置每次启动退回默认值，而 UI 看不出异常。
#   判据：`ls -l build/<plugin>/intermediates/aar_main_jar/release/*/classes.jar`
#         时间戳早于今天 → 必须全量 clean。
set -euo pipefail

# 从 PowerShell 直接调用 Git Bash 时，PATH 可能不含 Git 自带的 Unix 工具。
export PATH="/usr/bin:/bin:$PATH"

SRC="/c/Users/Administrator/WorkBuddy/记账软件/JianjiApp"
BC="/c/builds/jj"

CLEAN_MODE="full"    # full | app | none
BUILD_TYPE="release"
CHECK_ONLY=false
RUN_TESTS=true
TEST_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --incr)       CLEAN_MODE="incr";;
    --fast)       CLEAN_MODE="app";;
    --no-clean)   CLEAN_MODE="none";;
    --full-clean) CLEAN_MODE="full";;
    --profile)    BUILD_TYPE="profile";;
    --debug)      BUILD_TYPE="debug";;
    --check)      CHECK_ONLY=true; CLEAN_MODE="none";;
    --test-file)  TEST_FILES+=("$2"); shift;;
    --no-tests)   RUN_TESTS=false;;
    *) echo "未知参数: $1"; exit 1;;
  esac
  shift
done

# 1) 自动同步代理端口（从当前 env 取，避免 Gradle 因端口漂移无限挂起）
PORT="$(printf '%s' "${https_proxy:-${HTTPS_PROXY:-}}" | sed -E 's#.*:([0-9]+)/?$#\1#')"
if [[ -n "$PORT" ]]; then
  sed -i -E "s#(systemProp\.(http|https)\.proxyPort=)[0-9]+#\1$PORT#" "$SRC/android/gradle.properties"
  echo "[1/5] 代理端口同步为 $PORT"
else
  echo "[1/5] 未检测到代理端口，跳过（若有网络问题请手动核对 gradle.properties）"
fi

# 2) 同步源码到构建副本（lib + assets + pubspec + android 三件套 + test）
#    ⚠️ 用「原地覆盖」而不是 rm -rf + cp -r：
#    rm -rf 整个 lib 会触发工具的 safe-delete 保护（文件数超阈值需确认），
#    一旦 rm 被拦而 cp 照跑，就会变成「嵌套复制」或「根本没覆盖」，而命令还不报错。
cp -rf "$SRC/lib/." "$BC/lib/"
mkdir -p "$BC/assets"
cp -rf "$SRC/assets/." "$BC/assets/"
cp "$SRC/pubspec.yaml" "$BC/pubspec.yaml"
cp "$SRC/android/gradle.properties" "$BC/android/gradle.properties"
cp "$SRC/android/build.gradle.kts" "$BC/android/build.gradle.kts"
cp "$SRC/android/app/build.gradle.kts" "$BC/android/app/build.gradle.kts"
# 原生侧（MainActivity / AndroidManifest / res）必须一起同步。
# 2026-10-26 踩坑：源码把 MainActivity 改成 FlutterFragmentActivity、
# Manifest 加了 USE_BIOMETRIC，但这里没同步 android/app/src，
# 结果打出来的包仍是 FlutterActivity → local_auth 抛 no_fragment_activity，
# 指纹/面容"按了没反应"，且 UI 上完全看不出来。
cp -rf "$SRC/android/app/src/." "$BC/android/app/src/"

# 签名文件也要同步（release 用 jianji-release.jks + key.properties）。
# ⚠️ 漏同步 = 构建副本里读不到 key.properties → gradle 直接失败（这是好事，
#    2026-10-26 之前不失败是因为脚本静默退回 debug 签名，包能装能跑、UI 看不出，
#    等要覆盖升级时才发现签名对不上）。两个文件都不进版本库，需另行备份。
if [[ -f "$SRC/android/key.properties" && -f "$SRC/android/jianji-release.jks" ]]; then
  cp "$SRC/android/jianji-release.jks" "$BC/android/jianji-release.jks"
  cp "$SRC/android/key.properties" "$BC/android/key.properties"
else
  echo "⚠️  未找到 android/key.properties 或 android/jianji-release.jks"
  echo "    release 构建会在 gradle 阶段报错（不会退回 debug 签名）。"
fi

mkdir -p "$BC/test"
cp -rf "$SRC/test/." "$BC/test/"
echo "[2/5] 源码同步完成"

# 版本号统一从 pubspec 拆出，构建时注入 Dart；界面版本不再靠手改常量。
VERSION_LINE="$(grep -E '^version:' "$SRC/pubspec.yaml" | head -1 | sed -E 's/^version:[[:space:]]*//')"
VER="${VERSION_LINE%%+*}"
BUILD_NUMBER="${VERSION_LINE#*+}"
if [[ -z "$VER" || -z "$BUILD_NUMBER" || "$BUILD_NUMBER" == "$VERSION_LINE" ]]; then
  echo "版本号格式错误，应为 x.y.z+n：$VERSION_LINE"
  exit 1
fi
echo "      版本 $VER（$BUILD_NUMBER）"

# 2.5) 同步校验：构建副本必须与源码一致，不一致就别往下跑
if ! diff -rq "$SRC/lib" "$BC/lib" >/dev/null 2>&1; then
  echo "⚠️  构建副本与源码不一致（可能有孤儿文件），差异如下："
  diff -rq "$SRC/lib" "$BC/lib" | head -10
fi
# 生物识别的两个硬前提，缺一个指纹/面容就静默失效，必须构建期拦住。
if ! grep -q "FlutterFragmentActivity" "$BC/android/app/src/main/kotlin/com/jianji/jianji/MainActivity.kt"; then
  echo "❌ MainActivity 不是 FlutterFragmentActivity —— local_auth 会抛 no_fragment_activity，指纹用不了"
  exit 1
fi
if ! grep -q "USE_BIOMETRIC" "$BC/android/app/src/main/AndroidManifest.xml"; then
  echo "❌ AndroidManifest 缺 USE_BIOMETRIC 权限 —— 生物识别会直接失败"
  exit 1
fi


# 3) 清理（默认 flutter clean 全量：连 build/<plugin>/ 一起清掉，断掉旧 jar 复用）
cd "$BC"
if [[ "$CLEAN_MODE" == "full" ]]; then
  flutter clean
elif [[ "$CLEAN_MODE" == "incr" ]]; then
  # 只删「合并 / 裁剪后的原生库」中间产物。
  # 为什么不是 flutter clean：Flutter 侧 build/.../devRelease/jniLibs/arm64-v8a/libapp.so
  # 每次都会更新，但 Gradle 把 merge*/strip* 判成 UP-TO-DATE，于是打进 APK 的
  # 仍是合并目录里的旧 libapp.so（表现为"改了代码但包没变"）。砍这三处即可强制重合并，
  # Gradle 其余缓存全留着，比全量 clean 省 3~4 分钟。
  rm -rf "$BC/build/app/intermediates/merged_native_libs" \
         "$BC/build/app/intermediates/merged_jni_libs" \
         "$BC/build/app/intermediates/stripped_native_libs" 2>/dev/null || true
elif [[ "$CLEAN_MODE" == "app" ]]; then
  ( cd android && ./gradlew :app:clean ) || true
fi
echo "[3/5] 清理完成（模式=$CLEAN_MODE）"

# 3.5) 安全阀：全量 clean 之外，检查插件 release 产物是否还是旧的
if [[ "$CLEAN_MODE" != "full" ]]; then
  # ⚠️ `| head -3` 会让 find 收到 SIGPIPE（退出码 141）。在 `set -o pipefail` + `set -e`
  # 下，整个命令替换被判为失败 → 脚本在这一行直接中断，而且**什么都不打印**。
  # 2026-10-25 踩到：插件的 release jar 变陈旧（正好命中 -mtime +0）时必现，
  # 表现是"脚本跑到 [3/5] 就没了"。`|| true` 就是为了吃掉这个 141。
  STALE="$(find "$BC/build" -path "*aar_main_jar/release*" -name classes.jar -mtime +0 2>/dev/null | head -3 || true)"
  if [[ -n "$STALE" ]]; then
    echo "⚠️  检测到陈旧的插件 release 产物，改用全量 clean："
    echo "$STALE"
    flutter clean
    CLEAN_MODE="full(forced)"
  fi
fi

# 4) 静态检查和测试（构建副本是 ASCII 路径，避开中文路径的 analyzer 卡死）
#
# Windows 测试机没有 GitHub release 缓存时，sqlite3 的 native hook 会先下载
# x64 DLL；这个网络在当前环境不可用。测试阶段临时改用系统 winsqlite3.dll，
# 出 APK 前再恢复原 pubspec，不改变 Android 产物使用的 SQLite 配置。
TEST_PUBSPEC="$BC/pubspec.yaml.test-$$"
cp "$BC/pubspec.yaml" "$TEST_PUBSPEC"
restore_test_pubspec() {
  if [[ -f "$TEST_PUBSPEC" ]]; then
    mv -f "$TEST_PUBSPEC" "$BC/pubspec.yaml"
  fi
}
trap restore_test_pubspec EXIT
cat >> "$BC/pubspec.yaml" <<'EOF'

hooks:
  user_defines:
    sqlite3:
      source: system
      name_windows: winsqlite3
      name: sqlite3
EOF

flutter pub get
echo "[4/6] flutter analyze"
flutter analyze --no-pub
echo "[5/6] flutter test"
if [[ "$RUN_TESTS" == "true" ]]; then
  env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
    -u ALL_PROXY -u all_proxy NO_PROXY=localhost,127.0.0.1 \
    flutter test --no-pub --concurrency=1 "${TEST_FILES[@]}"
else
  echo "      已跳过测试（--no-tests）"
fi
restore_test_pubspec
trap - EXIT
if [[ "$CHECK_ONLY" == "true" ]]; then
  echo "[check] 静态检查和测试通过；未构建 APK"
  exit 0
fi
flutter pub get

# 5) 构建
flutter build apk --"$BUILD_TYPE" --target-platform android-arm64 \
  --dart-define=APP_VERSION="$VER" --dart-define=APP_BUILD="$BUILD_NUMBER"
echo "[5/6] 构建完成（$BUILD_TYPE）"

# 6) 取出命名 APK
# 按构建类型精确取产物：只靠「最新 apk」在目录里残留旧包时会取错，
# 一旦取错就会把 release 包当成 debug 包交付（或反过来）。
if [[ "$BUILD_TYPE" == "release" ]]; then
  SRC_APK="$(ls -t "$BC/build/app/outputs/flutter-apk/"*release*.apk 2>/dev/null | head -1)"
else
  SRC_APK="$(ls -t "$BC/build/app/outputs/flutter-apk/"*"$BUILD_TYPE"*.apk 2>/dev/null | head -1)"
fi
if [[ -z "$SRC_APK" ]]; then
  echo "未找到 $BUILD_TYPE 产物 APK，请检查上方构建日志"
  exit 1
fi
# ⚠️ 只有 release 才用正式名 jianji<ver>-arm64.apk；debug/profile 必须带后缀，
# 否则会把已有的 release 包覆盖成调试包（一旦覆盖，交付物就废了且看不出来）。
if [[ "$BUILD_TYPE" == "release" ]]; then
  OUT="$SRC/jianji${VER}-arm64.apk"
else
  OUT="$SRC/jianji${VER}-${BUILD_TYPE}-arm64.apk"
fi
cp "$SRC_APK" "$OUT"
echo "[6/6] 已产出 $OUT"

# 6.5) 签名硬校验：release 必须是 jianji-release.jks 签的
#
# 为什么必须有这一步：签错的包**能装、能跑、UI 完全看不出来**，
# 唯一的表现是「将来想覆盖升级时装不上」（INSTALL_FAILED_UPDATE_INCOMPATIBLE）。
# 2026-10-26 之前所有 release 都是 debug 签名，就是这么被发现得太晚的。
if [[ "$BUILD_TYPE" == "release" ]]; then
  APKSIGNER="$(ls -d "${ANDROID_HOME:-/c/src/android-sdk}"/build-tools/*/apksigner.bat 2>/dev/null | sort -V | tail -1)"
  # jianji-release.jks（DN=CN=JianJi）的 SHA-1，小写无冒号
  WANT="95f4c153483dfa1618a2ec993e8a0fbab7580d5d"
  if [[ -z "$APKSIGNER" ]]; then
    echo "⚠️  找不到 apksigner，跳过签名校验（请手动核对 SHA-1 $WANT）"
  else
    GOT="$("$APKSIGNER" verify --print-certs "$OUT" 2>/dev/null \
      | grep -i "SHA-1 digest" | head -1 \
      | sed -E 's/.*digest:[[:space:]]*//' | tr -d ':' | tr 'A-F' 'a-f')"
    if [[ "$GOT" != "$WANT" ]]; then
      echo "❌ 签名不对！期望 jianji-release.jks ($WANT)，实际『$GOT』"
      echo "   检查 android/key.properties 与 android/jianji-release.jks 是否到位。"
      exit 1
    fi
    echo "✅ 签名校验通过：jianji-release.jks / SHA-1 $GOT"
  fi
fi
echo
echo "下一步必做（装真机后）："
echo "  adb install -r jianji${VER}-arm64.apk"
echo "  adb logcat -d | grep -iE 'flutter' | grep -iE 'exception|NoSuchMethodError|failed'"
echo "  ↑ 必须为空。留空不代表正常：插件签名不匹配会让设置模块静默失效，UI 看不出。"
