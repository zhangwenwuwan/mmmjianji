import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/scheme.dart';
import 'services/app_log.dart';
import 'services/offline_speech.dart';
import 'services/reminder_service.dart';
import 'services/scheme_service.dart';
import 'state/settings.dart';
import 'ui/boot_reveal.dart';
import 'ui/editor_page.dart';
import 'ui/lock_gate.dart';
import 'ui/motion.dart' show AppPageRoute;
import 'ui/shell.dart';
import 'ui/splash_page.dart';
import 'ui/theme.dart';
import 'ui/voice_entry_page.dart';
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

  // 后台预热离线语音识别引擎：冷启动先把 82MB 模型加载好，
  // 用户点麦克风时不再转几秒的圈（见 OfflineSpeechService.warmUp）。
  OfflineSpeechService.warmUp();

  runApp(const ProviderScope(child: JianjiApp()));
}

class JianjiApp extends ConsumerStatefulWidget {
  const JianjiApp({super.key});

  @override
  ConsumerState<JianjiApp> createState() => _JianjiAppState();
}

/// scheme 去重：同一链接 2 秒内只处理一次。
///
/// 冷启动（pullInitial）和热启动（onScheme 回调）可能先后送来同一条链接
/// （例如冷启动瞬间系统又补发了一次 intent），共用同一份去重状态，
/// 否则一次链接开两个页面。
String? _lastScheme;
DateTime _lastSchemeAt = DateTime.fromMillisecondsSinceEpoch(0);

bool _schemeSeen(String raw) {
  final now = DateTime.now();
  if (raw == _lastScheme &&
      now.difference(_lastSchemeAt) < const Duration(seconds: 2)) {
    return true;
  }
  _lastScheme = raw;
  _lastSchemeAt = now;
  return false;
}

/// 规范键：把「完整 URI」和「引擎剥掉 scheme 的残体」折算成同一个串，
/// 否则同一链接从两条路进来（`jianji:///voice` 与 `/voice`）会漏判重复，
/// 开两个页面。以 path+query 为准（host 形式折算成 /host）。
String _canonicalScheme(String raw) {
  final Uri uri;
  try {
    uri = Uri.parse(raw.trim());
  } on FormatException {
    return raw;
  }
  final path = uri.host.isNotEmpty ? '/${uri.host}' : uri.path;
  final q = uri.hasQuery && uri.query.isNotEmpty ? '?${uri.query}' : '';
  return '$path$q';
}

/// 透明直通路由：链接不认识/已处理时用它垫住框架（onGenerateRoute
/// 返回 null 会让框架抛 onUnknownRoute 异常）。
Route<dynamic> _passThroughRoute(RouteSettings settings) => PageRouteBuilder(
      settings: settings,
      opaque: false,
      pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    );

/// 把一条 jianji:// 链接变成路由。
///
/// 引擎热启动转发会把链接剥掉 scheme（`jianji:///voice` → `/voice`、
/// `jianji:///add?...` → `/add?...`），所以 `/` 开头的残体也交给
/// parseScheme 试试。残体不认识时给透明直通路由（返回 null 会让框架
/// 抛 onUnknownRoute 异常）；非 jianji 的普通路由名维持原样返回 null。
Route<dynamic>? schemeRoute(RouteSettings settings) {
  final name = settings.name;
  if (name == null) return null;
  final isSchemeish = name.startsWith('jianji://') ||
      (name.startsWith('/') && parseScheme(name) != null);
  if (!isSchemeish && !name.startsWith('/')) return null;
  final cmd = parseScheme(name);
  if (cmd == null) {
    // 不认识的 jianji 链接 / 剥残体：透明直通路由，home 照常可见。
    return _passThroughRoute(settings);
  }
  if (_schemeSeen(_canonicalScheme(name))) {
    // 已处理过（冷启动兜底和引擎转发同时到）：给透明直通路由，
    // 返回 null 会让框架抛 onUnknownRoute 异常。
    return _passThroughRoute(settings);
  }
  AppLog.info('scheme', '打开：$name');
  switch (cmd.action) {
    case 'add':
      return AppPageRoute(page: EntryEditorPage(schemeDraft: cmd.draft));
    case 'voice':
      return AppPageRoute(page: const VoiceEntryPage());
  }
  return null;
}

class _JianjiAppState extends ConsumerState<JianjiApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // 冷/热启动链接统一投递：
    //  - 冷启动：原生存着 launch intent 的 jianji://，Dart 就绪后 pullInitial 来取；
    //  - 热启动：原生 onNewIntent 经 'onScheme' 回调把原始完整 URI 推过来。
    // （引擎自带的转发会剥掉 scheme，不可用，见 MainActivity.onNewIntent 注释。）
    // 两条路共用 [_schemeSeen] 去重。
    SchemeService.install(_deliverScheme);
    unawaited(SchemeService.pullInitial().then(_deliverScheme));
  }

  /// 把一条原始 URI 变成页面推上栈。
  ///
  /// 冷启动时 initState 比 Navigator 首帧还早，`_navigatorKey.currentState`
  /// 可能还是 null —— 轮询等它就绪（最多 1 秒），而不是直接丢掉链接。
  Future<void> _deliverScheme(String? raw) async {
    if (raw == null || raw.isEmpty) return;
    final cmd = parseScheme(raw);
    if (cmd == null || _schemeSeen(_canonicalScheme(raw))) return;
    for (var i = 0; i < 20; i++) {
      final nav = _navigatorKey.currentState;
      if (nav != null) {
        AppLog.info('scheme', '打开：$raw');
        switch (cmd.action) {
          case 'add':
            unawaited(nav.push(
                AppPageRoute(page: EntryEditorPage(schemeDraft: cmd.draft))));
          case 'voice':
            unawaited(nav.push(AppPageRoute(page: const VoiceEntryPage())));
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    AppLog.warn('scheme', 'Navigator 未就绪，链接丢弃：$raw');
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    // 封面取色生效时，用它接管全 App 配色（settings.coverSeedColor 已内置
    // 「有封面 + 取到色 + 用户没关跟随」三重判断）。
    final seed = settings.coverSeedColor;
    return MaterialApp(
      title: '简记',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      // 原生层覆盖 getInitialRoute() 返回 "/"，引擎不会把 jianji:// 链接
      // 当初始路由（否则首页不进栈、目标页成根路由、按返回黑屏）；
      // 深链接页面由 SchemeService 推在首页之上。
      // 注意：框架的 _initialRouteName 会无条件覆盖 initialRoute，光在 Dart
      // 侧写 initialRoute:'/' 没用，必须在原生侧挡住。
      initialRoute: '/',
      // 兜底：万一某条路把完整 jianji:// URI 送进框架路由（pushRoute），
      // 也能接住。onGenerateRoute 返回 null 会让框架抛 onUnknownRoute 异常。
      onGenerateRoute: schemeRoute,
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
      // 应用锁必须包在 builder 里（= Navigator 之上）。
      // 挂在首页路由内部的话，push 出来的页面永远盖在锁屏上面，
      // 切后台回来看到的是原来那页而不是锁屏（真机复现过）。
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: settings.fontScale,
        maxScaleFactor: settings.fontScale,
        child: LockGate(child: child ?? const SizedBox.shrink()),
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

  /// 上次播完启动动画的时刻（毫秒时间戳）。
  ///
  /// 2026-10-28 加：引擎首帧只要 443ms，动画再压到 600ms 也还是"每次开都等"。
  /// 记账工具一天开七八次，仪式感只在第一次有意义 —— 所以**24 小时内只播一次**。
  /// 用 SharedPreferences 存，不动数据库（这个值丢了最多多播一次动画，不值得进 schema）。
  static const _kBootPlayedAt = 'boot_played_at';

  static const _kBootInterval = Duration(hours: 24);

  /// 首页内容开始浮上来的时刻：呼吸 + 幕张开到 120ms 处。
  ///
  /// 用绝对时刻而不是「从现在起 delay」，因为各块是数据驱动陆续创建的，
  /// 晚创建 400ms 的那一块不该再从头排一次队。
  late final BootRevealTimeline _timeline = BootRevealTimeline(
    startAt: DateTime.now().add(kBootBreath + kBootContentDelay),
  );

  bool _showSplash = true;

  /// 默认 true：万一读偏好失败，也不要每次都弹欢迎页
  bool _onboarded = true;

  /// initState 的时刻，用来判断"prefs 回来时动画进行到哪了"。
  late final DateTime _bootStartedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      var onboarded = true;
      var playedRecently = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        onboarded = prefs.getBool(_kOnboarded) ?? false;
        final lastAt = prefs.getInt(_kBootPlayedAt) ?? 0;
        if (lastAt > 0) {
          playedRecently = DateTime.now().millisecondsSinceEpoch - lastAt <
              _kBootInterval.inMilliseconds;
        }
      } catch (e) {
        AppLog.warn('boot', '读取引导状态失败: $e');
      }
      if (!mounted) return;

      // 24 小时内播过 → 直接进首页，不演幕。
      //
      // ⚠️ 只在**呼吸阶段还没结束**时才允许中途跳过：
      // prefs 首次读取可能要 50~100ms，万一 slow 到 200ms 以上，幕已经在张开了，
      // 这时把 _showSplash 置 false 会让画面从"圆开到一半"直接跳到首页 —— 更难看。
      // 判断窗口放在 kBootBreath 内，跳过就是干净的「底色 → 首页」。
      final elapsed = DateTime.now().difference(_bootStartedAt);
      final canSkip = playedRecently && elapsed < kBootBreath;

      setState(() {
        _onboarded = onboarded;
        if (canSkip) _showSplash = false;
      });
      if (canSkip) _timeline.active = false;
    });
  }

  /// 记下"这一轮动画播完了"，下次 24 小时内不再播。
  ///
  /// 故意放在播完时写、而不是开始时写：用户中途杀掉进程的话，下次还能看到完整的。
  Future<void> _markBootPlayed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kBootPlayedAt, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      AppLog.warn('boot', '记录启动动画时刻失败: $e');
    }
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
    // 幕摘掉之后，首页在 children 里从下标 1 变成 0。
    // 不给 key 的话 Flutter 按下标配对，会以为下标 0 从「幕」变成了「首页」，
    // 直接把首页的 State 扔掉重建 —— 滚动位置、已加载的数据全丢（等于白启动一次）。
    return BootRevealScope(
      timeline: _timeline,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 首页**始终**垫在幕底下（2026-10-28 起首帧就插，不再等幕张开）。
          // 这样幕张开时露出的是真的、已经加载完数据的首页，不是空壳。
          Positioned.fill(
            key: const ValueKey('boot-target'),
            child: target,
          ),
          if (_showSplash)
            Positioned.fill(
              key: const ValueKey('boot-curtain'),
              child: SplashCurtain(
                // 首页已经在首帧插好，这里不用再做事。
                // 保留回调是因为 SplashCurtain 用它做时序锚点（"幕开始张开了"）。
                onOpenStart: () {},
                onDone: () {
                  // 启动这一轮结束了：之后新建的内容块不再排队浮入
                  _timeline.active = false;
                  _markBootPlayed();
                  if (mounted) setState(() => _showSplash = false);
                },
              ),
            ),
        ],
      ),
    );
  }
}
