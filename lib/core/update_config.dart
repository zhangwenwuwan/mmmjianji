/// 更新清单（version.json）的默认地址。
///
/// 默认值写死为本仓库的清单直链（清单体积小，走 `latest/download` 没问题；
/// **apkUrl 字段**必须用具体 tag 单跳，别抄这里）。出包时仍可用
/// `--dart-define=UPDATE_URL=...` 覆盖（见 build_jianji.sh）。
///
/// ⚠️ 必须是 **HTTPS**：清单和 APK 都要走 HTTPS，否则别人能在中间人位置
/// 把 apkUrl 换成别的包（我们虽然会校验 sha256，但 sha256 也在同一份清单里，
/// 一起被改就没意义了）。
const String kDefaultManifestUrl =
    'https://github.com/zhangwenwuwan/mmmjianji/releases/latest/download/version.json';

const String _kBakedManifestUrl = String.fromEnvironment(
  'UPDATE_URL',
  defaultValue: kDefaultManifestUrl,
);

/// 实际使用的清单地址。
///
/// ⚠️ 为什么要多一层判空：`String.fromEnvironment` 只要编译时**定义过**
/// `UPDATE_URL` 就返回定义值，哪怕值是空串 —— `defaultValue` 根本不生效。
/// build_jianji.sh 曾经无条件传 `--dart-define=UPDATE_URL="${UPDATE_URL:-}"`，
/// 于是「忘记 export」的包（1.4.58 那次事故、以及任何 profile 验证包）里
/// 清单地址是 `''`，检查更新永远显示「未接入更新服务」，而且 UI 上看不出原因。
/// 2026-11-08 审计 P1-2 把它从「靠出包人记得 export」改成「Dart 侧自己兜底」：
/// 空串一律视为没配置，回落到默认地址。构建脚本也同步改成「空就不注入」。
const String kUpdateManifestUrl =
    _kBakedManifestUrl == '' ? kDefaultManifestUrl : _kBakedManifestUrl;
