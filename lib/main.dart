import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/app_log.dart';
import 'services/reminder_service.dart';
import 'state/settings.dart';
import 'ui/shell.dart';
import 'ui/splash_page.dart';
import 'ui/theme.dart';
import 'ui/welcome_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 先接管全局错误，之后所有异常都会进「日志中心」
  AppLog.installGlobalHandlers();
  AppLog.info('app', '应用启动');

  // 启动路径上**不 await 任何插件**：runApp 立刻执行，首帧必然渲染出来。
  // 偏好由 SettingsNotifier 异步补水，日志回填和提醒重排也放后台。
  AppLog.restore();
  ReminderService.resync();

  runApp(const ProviderScope(child: JianjiApp()));
}

class JianjiApp extends ConsumerWidget {
  const JianjiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    // 封面取色生效时，用它接管全 App 配色（settings.coverSeedColor 已内置
    // 「有封面 + 取到色 + 用户没关跟随」三重判断）。
    final seed = settings.coverSeedColor;
    return MaterialApp(
      title: '简记',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light,
          paletteId: settings.paletteId, seedOverride: seed),
      darkTheme: buildTheme(Brightness.dark,
          paletteId: settings.paletteId, seedOverride: seed),
      themeMode: settings.themeMode,
      // 字体缩放走 MediaQuery，比改 textTheme 更可靠（所有文字一起缩）
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: settings.fontScale,
        maxScaleFactor: settings.fontScale,
        child: child ?? const SizedBox.shrink(),
      ),
      locale: const Locale('zh', 'CN'),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      home: const RootGate(),
    );
  }
}

/// 启动闸门：启动页 → （首次）欢迎引导 → 主界面。
///
/// 启动页本身不 await 任何插件，所以首帧立刻可见；
/// 「是否首次」在后台读，读到了再切，绝不会卡在启动页。
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  static const _kOnboarded = 'onboarded_v1';

  bool _showSplash = true;

  /// 默认 true：万一读偏好失败，也不要每次都弹欢迎页
  bool _onboarded = true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      var onboarded = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        onboarded = prefs.getBool(_kOnboarded) ?? false;
      } catch (e) {
        AppLog.warn('boot', '读取引导状态失败: $e');
      }
      // 让启动页至少露一下，避免一闪而过
      await Future<void>.delayed(const Duration(milliseconds: 560));
      if (!mounted) return;
      setState(() {
        _onboarded = onboarded;
        _showSplash = false;
      });
    });
  }

  Future<void> _finishWelcome() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kOnboarded, true);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _onboarded = true);
  }

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (_showSplash) {
      child = const SplashPage(key: ValueKey('splash'));
    } else if (!_onboarded) {
      child =
          WelcomePage(key: const ValueKey('welcome'), onDone: _finishWelcome);
    } else {
      child = const Shell(key: ValueKey('shell'));
    }
    // 两个页面都不透明，交叉淡入不会露出底色
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOut,
      child: child,
    );
  }
}
