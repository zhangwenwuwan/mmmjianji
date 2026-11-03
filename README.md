# 简记 (Jianji)

一款极简、清爽的个人记账 App，使用 Flutter 开发。

## 简介

简记专注于「记一笔」这件事本身：打开即记、分类清晰、统计直观、资产一目了然。
内置预算预警、报销管理、AA 分摊、月度归档、账单分享等实用功能，所有数据保存在本机，不上传云端。

主要特性：

- 多账本、多账户（现金 / 银行卡 / 信用 / 负债 / 资产），支持自定义图标与币种
- 收支、分类、标签、趋势、预算、日历、热力图等多维统计
- 记账模板、报销流转、AA 分摊与待收管理
- 预算超支预警与按月提醒
- 月度总结归档、账单分享长图
- 应用锁 + 指纹 / 面容解锁
- 内置自动更新（基于 GitHub Releases）

## 基于 BeeCount

本应用是 [BeeCount](https://github.com/TNT-Likely/BeeCount) 的修改版本，沿用其「BeeCount 软件许可协议」。
根据协议：本软件仅供**非商业用途**免费使用、修改与分发；修改后的版本**必须公开源代码**并保留原始版权声明与许可协议。
商业使用需另行获取商业授权，详见仓库内 `COMMERCIAL_LICENSE.md`（上游）或联系原作者。

协议全文见：[LICENSE](LICENSE)（中文） / [LICENSE_EN](LICENSE_EN)（English）。

## 构建

环境要求：Flutter SDK、Android SDK、JDK 17。

```
./build_jianji.sh --incr        # 增量构建并出包（含全量测试用 --check）
./build_jianji.sh --full-clean  # 全量重编（升级依赖或改原生后）
```

产物为 `jianji<版本名>-arm64.apk`。

## 自动更新

App 内的「检查更新」会读取 GitHub Releases 的 `version.json` 清单并跳转到最新 APK 下载。
发版流程见仓库内的 `release_github.sh` 与 `GitHub部署与发版.md`。

## 数据与隐私

所有账目数据仅存储于本机 SQLite 数据库，应用不收集、不上传任何个人信息。
你可以通过「我的 → 数据管理」进行导出、导入或清空。
