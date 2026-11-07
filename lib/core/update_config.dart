/// 更新清单（version.json）的地址。
///
/// 默认值已写死为本仓库的清单直链（清单体积小，走 `latest/download` 没问题；
/// **apkUrl 字段**必须用具体 tag 单跳，别抄这里）。出包时仍可用
/// `--dart-define=UPDATE_URL=...` 覆盖（见 build_jianji.sh）。
///
/// ⚠️ 必须是 **HTTPS**：清单和 APK 都要走 HTTPS，否则别人能在中间人位置
/// 把 apkUrl 换成别的包（我们虽然会校验 sha256，但 sha256 也在同一份清单里，
/// 一起被改就没意义了）。
const String kUpdateManifestUrl = String.fromEnvironment(
  'UPDATE_URL',
  defaultValue:
      'https://github.com/zhangwenwuwan/mmmjianji/releases/latest/download/version.json',
);
