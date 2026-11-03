/// 更新清单（version.json）的地址。
///
/// 留空 = 还没接入更新服务：设置页那行会显示「未接入」，
/// 点了也只提示一句，不会去请求一个假地址。
///
/// 换成你自己的，例如：
/// `const String kUpdateManifestUrl = 'https://jianji.example.com/version.json';`
/// 也可以在出包时用 `--dart-define=UPDATE_URL=https://...` 覆盖（见 build_jianji.sh）。
///
/// ⚠️ 必须是 **HTTPS**：清单和 APK 都要走 HTTPS，否则别人能在中间人位置
/// 把 apkUrl 换成别的包（我们虽然会校验 sha256，但 sha256 也在同一份清单里，
/// 一起被改就没意义了）。
const String kUpdateManifestUrl =
    String.fromEnvironment('UPDATE_URL', defaultValue: '');
