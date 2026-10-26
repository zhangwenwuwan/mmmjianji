# 简记 JianjiApp · 协作看板 (COLLAB)

> **用途**：供两个 AI 协作维护——`WorkBuddy (Hy3)` 与 `豆包`。
> **唯一共享态 = 文件系统**（两个 AI 之间无直连通道，用户负责在两边中转信息）。
> **铁律**：动任何文件前先读本文件最新版；改完立刻回填对应章节。谁改坏了一起背锅。

---

## 0. 一句话现状
本地优先的 Flutter 个人记账 App。**v1.1.0+33 已交付**（release 为 debug 签名），完成全局紧凑化与 Clean 设计规范统一。
两个 AI 协作继续完善功能与体验。本项目是蜜蜂记账 BeeCount 的修改版（BUSL 类协议，含强制开源义务）。

## 1. 技术栈与环境铁律（踩过坑，必读）
- Flutter 3.44.2 / Dart ^3.6.0；Riverpod + sqflite（原 Drift 已移除）+ Material 3。
- **⚠️ 中文路径跑不了 `flutter analyze`**（LSP 截断 rootUri）→ 构建副本在 **`C:\builds\jj`**（ASCII 路径）。
  源码在中文路径 `...\记账软件\JianjiApp`，改完 `rm -rf && cp -r` 同步过去再构建。
- **⚠️ 代理端口会漂移**（高频）：构建前 `env | grep -i proxy` 取当前端口，写进
  `android/gradle.properties` 的 `systemProp.http[s].proxyHost/Port` 四行。
  端口过期的症状是 **Gradle 无限挂起**（java 占内存却不产出），不是报错。
- **⚠️ release 必须 `flutter clean` 全量**（2026-10-23 修订，原来写的「`:app:clean` 就够」是错的）。
  两个不同的陈旧产物都会被打进包：
  1. `merged_native_libs` 被 Gradle 判 up-to-date → 打旧 `libapp.so`
  2. **`build/<插件名>/` 里的旧 `classes.jar`** —— `:app:clean` **清不到**（Flutter 给每个 plugin
     建独立 subproject，产物落在工程根 `build/<plugin>/`）。插件版本一变，旧 variant 的 jar 被
     UP-TO-DATE 复用 → **新 Dart 调旧 Java 方法 → `NoSuchMethodError`**。
     实测后果：SharedPreferences 整块失效，**所有设置每次启动退回默认值，而 UI 完全看不出异常**
     （只表现为"封面/配色/首页模块顺序被重置"）。
  判据：`ls -l build/<plugin>/intermediates/aar_main_jar/release/*/classes.jar` 时间戳早于今天 → 必全量 clean。
- **⚠️ 交付前必须 grep 一次 logcat**（装 release 包后）：
  `adb logcat -d | grep -iE 'flutter' | grep -iE 'exception|NoSuchMethodError|failed'` → 必须为空。
  「界面能显示」不等于「功能正常」。

- **⚠️ 产物校验**：解出 APK 的 `lib/arm64-v8a/libapp.so`，用 **UTF-16LE** 搜新加的中文字符串
  （Dart String 是 UTF-16；用 UTF-8 搜必然搜不到，会误判）。
  版本名 `x.y.z` 在 `AndroidManifest.xml` 的 string pool（**不在** libapp.so）；`+build` 是整数，别当字符串搜。
- **⚠️ `flutter test` 必须清代理**（小写+大写都清），否则 `WebSocketException`：
  `env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy -u ALL_PROXY -u all_proxy NO_PROXY=localhost,127.0.0.1 flutter test`
- **⚠️ 同步和分析要分两条命令**：串在一条里输出会被吞成空。

## 2. 协作守则（防冲突，最重要）
1. **改前占坑**：动任何 `.dart` 前，先在 §4「当前占用」登记 `文件名 + 负责人 + 预计完成`，改完立刻删。
2. **模块归属**：见 §3。跨模块改动先经用户中转说一声，避免两边同时改。
3. **测试同步**：`test/` 的改动必须同步进 `/c/builds/jj/test`（构建副本只认那边的测试）。
4. **出包只由 WorkBuddy 执行**（掌握构建副本、clean 流程、签名现状），豆包不要直接出包。
5. 每次实质性改动后，更新 §5 已改文件 + §6 待办。

## 3. 模块分工（认领制）
| 模块 | 负责人 | 状态 |
|---|---|---|
| 构建 / 出包 / 构建副本维护 | WorkBuddy | 已掌握 |
| 主题系统 `theme.dart` / `illustrations.dart` | WorkBuddy | 已落地薄荷青绿 |
| 数据层 `store.dart` / `ledger_state.dart` / `lunar.dart` | WorkBuddy | 已落地 |
| 壳与导航 `shell.dart`（五平 tab） | WorkBuddy | 已落地 |
| 首页 `ledger_page.dart` | 待认领 | |
| 日历 `calendar_page.dart` | 待认领 | |
| 资产 `assets_page.dart` | 待认领 | |
| 我的 `profile_page.dart` | 待认领 | |
| 编辑器 `editor_page.dart` | 待认领 | |
| 统计 `insights*` / 搜索 / 账单导入 | 待认领 | |
| 设置（外观/预算/周期/提醒/数据管理） | 待认领 | |
| 附件 / 启动页 / 欢迎页 / 日志中心 / 桌面小组件 | 待认领 | 已落地，维护中 |
| 关于 / 开源许可页 `about_page.dart` | WorkBuddy | 1.0.3 已完成 |

> **豆包认领方式**：在「待认领」行把负责人填成 `豆包`，并在 §4 占坑即可。
> 同一文件两人都要动时，**拆到函数级**而非整文件重写，降低冲突概率。

## 4. 当前占用（改前填，改完删）
- 无

## 5. 已改文件清单（最近一轮：1.1.0 UI 改版）
- 安装 `bergside/awesome-design-skills` 的 `clean` 技能到 `C:\Users\Administrator\.codex\skills\clean`
- `lib/ui/theme.dart`：中性纸面、8px 卡片/控件圆角、紧凑字体刻度、统一按钮/表单/角标密度
- `lib/ui/common.dart`：Panel 去阴影、内边距 16→12、输入/下拉/空态/月份条全面收紧
- `lib/ui/shell.dart`：底栏 58→52，选中指示与图标缩小
- `lib/ui/ledger_page.dart` / `lib/ui/calendar_page.dart` / `lib/ui/assets_page.dart` / `lib/ui/insights_page.dart` / `lib/ui/profile_page.dart`：五个主页面压缩空白、字号与金额层级
- `lib/ui/profile_page.dart` / `lib/ui/about_page.dart`：去除 emoji 头像，改用线性图标
- 全 UI：移除 `w800` 字重，卡片/控件 12–18px 圆角统一到 8px
- `lib/core/version.dart` / `pubspec.yaml`：版本提升为 `1.1.0+33`

## 6. 待办（按优先级）
- [x] 应用内「关于 / 开源许可」页（1.0.3 已完成）
- [ ] **误删保护**：软删除 + 回收站 / Snackbar 撤销
- [ ] 统计页自定义起止时间范围
- [ ] 资产页、统计页空态引导条
- [ ] 头部皮肤 30+（用户**暂缓**）
- [ ] 多语言（用户**不要**）
- （豆包可在此追加认领的任务）

## 7. 出包记录
| 版本 | 日期 | 说明 |
|---|---|---|
| 0.9.4+22 | 2026-10-22 | 薄荷青绿重设计全套，无会员模式，五平 tab |
| 0.9.5+23 | 2026-10-22 | 首页右上角日历按钮移除（日历仍保留为底部 tab）；出包改用 gradlew :app:clean 提速 |
| 1.0.3+31 | 2026-10-24 | 版本显示修复、许可页与许可资产、日历收入双行展示；SHA-256 `F4D4F78FED77AF0F96A5FDEB224FD566F2EAC063B88152A146298AD0B79D9ED2` |
| 1.0.4+32 | 2026-10-24 | 日历下方流水、节日节气、报销角标、借贷方向与余额口径修复；SHA-256 `59E716AEBB81EA29F834E4259ADCBF361F34139D203BC7BC4D0B4B0CEB7F3FF2` |
| 1.1.0+33 | 2026-10-24 | Clean 设计规范、全局紧凑化、五主页面重排、去重字重与 emoji；SHA-256 `1F65E5DDF794078BA4F588D5F09963B3E678EF670A2FC9F4DECD83CCBEEFEFD0` |

## 8. 构建 / 出包标准流程（仅 WorkBuddy 执行）
> **一键脚本** `build_jianji.sh`（Git Bash 里跑）：自动同步代理端口、同步源码、按模式清理、出包、改名。
> 默认即「安全快速」模式（`gradlew :app:clean`，保留 Dart 增量缓存）。
> - `./build_jianji.sh`：标准出包（推荐，最快且不会陈旧）
> - `./build_jianji.sh --no-clean`：纯增量（仅改 Dart 且确信无陈旧时）
> - `./build_jianji.sh --full-clean`：旧流程 `flutter clean`（怀疑陈旧 AOT 兜底，最慢）
> - `./build_jianji.sh --profile`：跳过 R8，本地自测最快（不上架）
> - `./build_jianji.sh --check`：只同步、分析和测试，不出包
> - `--test-file test/xxx_test.dart`：可重复传，只跑指定测试
> - `--no-tests`：仅构建；静态分析仍会运行

手动流程（等价于脚本）：
1. （脚本自动）`env` 取代理端口 → 写进源码 `android/gradle.properties`
2. 升 `pubspec.yaml` 的 `version`（如 `1.0.2+30` → `1.0.3+31`）
3. 同步 `lib` + `assets` + `pubspec.yaml` + android 三件套 + `test/` 到 `/c/builds/jj`
4. `cd /c/builds/jj && flutter analyze --no-pub` → 0 问题；测试阶段临时使用系统 `winsqlite3.dll`，出包前恢复原配置
5. 清理：`gradlew :app:clean`（默认）或 `flutter clean`（兜底），**不必每次全量 clean**
6. `flutter pub get` + `flutter build apk --release --target-platform android-arm64`（带代理，约 10 分钟；改用 :app:clean 后通常明显更快）
7. 解 APK 用 **UTF-16LE** 搜新中文串 + manifest 查版本名；改名 `jianji<版本>-arm64.apk` 交付源码目录
8. 更新 §7 出包记录

---
*本文件由 WorkBuddy 于 2026-10-22 创建，作为两 AI 协作的单一事实来源。*
