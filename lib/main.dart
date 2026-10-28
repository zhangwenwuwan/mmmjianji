import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/app_log.dart';
import 'services/reminder_service.dart';
import 'state/settings.dart';
import 'ui/boot_reveal.dart';
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
          paletteId: settings.paletteId,
          seedOverride: seed,
          fontStyle: settings.fontStyle),
      darkTheme: buildTheme(Brightness.dark,
          paletteId: settings.paletteId,
          seedOverride: seed,
          fontStyle: settings.fontStyle),
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

/// 启动闸门：启动幕 → （首次）欢迎引导 → 主界面。
///
/// 启动幕本身不 await 任何插件，所以首帧立刻可见；
/// 「是否首次」在后台读，读到了再切，绝不会卡在启动页。
///
/// 2026-10-26：启动改成「开幕」——
/// 幕和首页同时挂在 [Stack] 里，幕在上面。呼吸 600ms 后 [SplashCurtain]
/// 回调 onOpenStart，这时才把首页插到幕底下（首页取数据的时间因此和
/// 「幕张开」的 700ms 重叠，露出来的时候基本已经就绪）；
/// 幕张开到一半时，首页各块按 boot_reveal 的时间线依次浮上来。
class RootGate extends StatefulWidget {
  const RootGate({super.key});

  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  static const _kOnboarded = 'onboarded_v1';

  /// 首页内容开始浮上来的时刻：呼吸 600ms + 幕张开 350ms。
  ///
  /// 用绝对时刻而不是「从现在起 delay」，因为各块是数据驱动陆续创建的，
  /// 晚创建 400ms 的那一块不该再从头排一次队。
  late final BootRevealTimeline _timeline = BootRevealTimeline(
    startAt: DateTime.now().add(kBootBreath + kBootContentDelay),
  );

  bool _showSplash = true;

  /// 首页是否已经插到幕底下（幕开始张开时才插）。
  bool _targetIn = false;

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
      if (!mounted) return;
      setState(() => _onboarded = onboarded);
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
    final Widget target = _onboarded
        ? const Shell(key: ValueKey('shell'))
        : WelcomePage(key: const ValueKey('welcome'), onDone: _finishWelcome);

    // ⚠️ 两个 child 必须各自带 key：
    // 首页是在幕开始张开时才插入的，插进来之后幕在 children 里从下标 0 变成 1。
    // 不给 key 的话 Flutter 按下标配对，会以为下标 0 从「幕」变成了「首页」，
    // 直接把幕的 State 扔掉重建 —— 幕张开到一半会瞬间归零、闪一下首页。
    return BootRevealScope(
      timeline: _timeline,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_targetIn)
            Positioned.fill(
              key: const ValueKey('boot-target'),
              child: target,
            ),
          if (_showSplash)
            Positioned.fill(
              key: const ValueKey('boot-curtain'),
              child: SplashCurtain(
                onOpenStart: () {
                  if (mounted) setState(() => _targetIn = true);
                },
                onDone: () {
                  // 启动这一轮结束了：之后新建的内容块不再排队浮入
                  _timeline.active = false;
                  if (mounted) setState(() => _showSplash = false);
                },
              ),
            ),
        ],
      ),
    );
  }
}
