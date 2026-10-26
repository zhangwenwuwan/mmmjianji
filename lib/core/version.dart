/// 应用版本（界面展示用）。
///
/// 与 pubspec 的 version 保持一致。构建时可用
/// `--dart-define=APP_VERSION=x.y.z --dart-define=APP_BUILD=n` 覆盖，
/// 不传则用下面的常量 —— 常量也要跟着 pubspec 一起改。
const String appVersion =
    String.fromEnvironment('APP_VERSION', defaultValue: '1.4.15');
const int appBuild = int.fromEnvironment('APP_BUILD', defaultValue: 54);
