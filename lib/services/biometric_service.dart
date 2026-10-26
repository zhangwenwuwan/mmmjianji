import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';

/// 生物识别（指纹 / 面容）封装。
///
/// 为什么单独一个文件：
/// 1. **测试环境不能碰插件**。`flutter test` 跑在桌面上，`local_auth` 的
///    MethodChannel 没人接，直接调会抛 MissingPluginException。这里所有
///    平台判断和异常都收在一个文件里，调用方只管拿 true/false。
/// 2. 语义钉死：**指纹只是 PIN 的快捷方式，不是第二把锁**。
///    `biometricOnly: true` 保证不会偷偷降级成「设备凭据」（锁屏图案/密码），
///    否则等于用系统密码替代了 App 自己的 PIN，两套语义混在一起。
///
/// ⚠️ 2026-10-25 修正：原来把「设备支持」和「已录入指纹」绑成一个条件去控制
/// 设置页开关是否可用，结果 OPPO 这台机器上 `available=[]`（系统没录指纹），
/// 开关永远是灰的、点不动 —— 用户以为功能坏了。
/// 现在拆成两个：
/// - [isSupported]  设备有没有这个能力（决定开关**能不能点**）；
/// - [hasEnrolled]  系统里现在有没有录指纹（只用来提示文案）。
/// 没录指纹也允许先把开关打开，等录完指纹回来就能用。
class BiometricService {
  const BiometricService._();

  static bool get _supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 设备是否具备生物识别能力（**不要求已录入**）。
  ///
  /// 任何异常都当"不支持"：宁可只留 PIN，也不能让锁屏卡死进不去。
  /// 但异常要打日志 —— 「设备不支持」和「插件炸了」在界面上长得一模一样
  /// （local_auth 在 Android 上要求 MainActivity 继承 FlutterFragmentActivity，
  /// 忘了改会直接抛异常，表现就是"指纹按钮永远不出现"）。
  static Future<bool> isSupported() async {
    if (!_supported) {
      debugPrint('[biometric] 当前平台不支持');
      return false;
    }
    try {
      final auth = LocalAuthentication();
      final supported = await auth.isDeviceSupported();
      final canCheck = await auth.canCheckBiometrics;
      debugPrint('[biometric] deviceSupported=$supported canCheck=$canCheck');
      return supported || canCheck;
    } catch (e) {
      debugPrint('[biometric] 能力检查失败: $e');
      return false;
    }
  }

  /// 系统里是否已经录入指纹 / 面容。
  ///
  /// 仅用于设置页提示。部分国产 ROM（如这台 OPPO）在没录指纹时
  /// `getAvailableBiometrics()` 返回空列表，这是正常的。
  static Future<bool> hasEnrolled() async {
    if (!_supported) return false;
    try {
      final list = await LocalAuthentication().getAvailableBiometrics();
      debugPrint('[biometric] available=${list.map((e) => e.name).toList()}');
      return list.isNotEmpty;
    } catch (e) {
      debugPrint('[biometric] 查询已录入失败: $e');
      return false;
    }
  }

  /// 弹系统验证。成功返回 true；用户取消/硬件异常/未录入一律 false。
  ///
  /// 文案与 1.2.8（BeeCount 系）保持一致：那句 localizedReason 会直接显示在
  /// 系统的指纹/面容弹窗上，"解锁简记" 太短，用户不知道在验证什么。
  static Future<bool> authenticate() async {
    if (!_supported) return false;
    try {
      return await LocalAuthentication().authenticate(
        localizedReason: '请验证身份以解锁简记',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } catch (e) {
      debugPrint('[biometric] 验证失败: $e');
      return false;
    }
  }
}
