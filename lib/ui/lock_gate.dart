import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/lock_rules.dart';
import '../services/biometric_service.dart';
import '../state/settings.dart';
import 'motion.dart';
import 'theme.dart';

/// 解锁后这段时间内一律不回锁。
///
/// 系统生物识别/凭据弹窗自身会触发 `paused → resumed`，不排除就
/// 「解锁成功 → 立刻回锁 → 再弹」死循环（1.2.8 踩过，表现是"指纹根本用不了"）。
///
/// 为什么做成可改的顶层变量：这条规则是**时间**相关的，widget 测试里没法
/// 把 `DateTime.now()` 往前拨。测试把它设成 0 才能验证「切走就上锁」。
@visibleForTesting
Duration lockUnlockGuard = const Duration(seconds: 3);

/// 应用锁。**挂在 `MaterialApp.builder` 里，也就是 Navigator 之上。**
///
/// ⚠️ 2026-11-06 换了位置，原因是真机复现出来的结构性 bug：
/// 以前它挂在 `Shell`（首页路由）内部，而 `Navigator.push` 出来的页面
/// （设置、记账页、月报…）永远在那个路由**上面**。于是切后台再回来时，
/// `LockGate` 确实把自己切成了锁屏 —— 但用户看到的还是那个被 push 的页面，
/// 锁屏被盖在底下。现象就是「上锁的界面没有跳转」。
///
/// 现在它包住整个 Navigator：
/// - 锁定时用 [Offstage] 把整个 Navigator 摘下（**保持挂载**，不绘制、不可点、
///   不进无障碍树），所以解锁后回到原来那一页，未保存的草稿和滚动位置都还在；
/// - 锁屏是它上面的一个全屏层，盖住所有路由和弹窗。
///
/// 另一条老坑：状态来源必须是「本次会话是否已解锁」，**不是**一个一次性的
/// `_locked` 布尔。`SettingsNotifier.build()` 首帧返回 `const AppSettings()`
/// （lockEnabled = false），真要等 `_hydrate` 回来才准。否则开了锁、
/// 杀进程重开一次 PIN 都不用输 —— 手工测很容易漏。
class LockGate extends ConsumerStatefulWidget {
  const LockGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<LockGate> createState() => _LockGateState();
}

class _LockGateState extends ConsumerState<LockGate>
    with WidgetsBindingObserver {
  /// 切后台超过这个时长再回来就要重新解锁。
  ///
  /// 2026-10-25 起由用户在「外观与显示 → 应用锁」里自选（0 = 每次切回都锁）。
  /// 偏好没补水完时按**最严格**处理（0）：宁可多锁一次，
  /// 也不能出现"重启后短时间内免锁"的反向漏洞。
  static const _fallbackGrace = Duration.zero;

  /// 本次会话是否已经解锁过。进程重启即归零（这正是要的语义）。
  bool _unlocked = false;

  /// 最近一次成功解锁的时间（见 [lockUnlockGuard]）。
  DateTime? _lastUnlockAt;

  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  bool _justUnlocked() {
    final last = _lastUnlockAt;
    if (last == null || lockUnlockGuard <= Duration.zero) return false;
    return DateTime.now().difference(last) < lockUnlockGuard;
  }

  bool get _locked => ref.read(settingsProvider).lockEnabled && !_unlocked;

  void _onUnlocked() {
    _lastUnlockAt = DateTime.now();
    if (!mounted) return;
    setState(() => _unlocked = true);
  }

  /// 真正挂上锁。「切走时」和「回来时」两条路都要用。
  void _lockNow() {
    if (!mounted) return;
    setState(() => _unlocked = false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _onResumed();
    } else {
      _onBackground();
    }
  }

  /// 锁屏时吞掉系统返回键。
  ///
  /// `LockGate` 现在在 Navigator 之上，底下的路由虽然没被绘制、但依然是活的；
  /// 不拦的话返回键会去 pop 它们 —— 解锁后莫名少了一层页面。
  @override
  Future<bool> didPopRoute() async => _locked;

  /// 任何非 resumed 状态都当成「可能切走了」。
  ///
  /// 只认 `paused` 会漏锁：手势导航、下拉通知栏、最近任务里快速切一下，
  /// 系统都可能只发 `inactive → resumed`，`_pausedAt` 一直是 null，
  /// 回到前台就不上锁 —— 这就是"有时候就是不上锁"的来源。
  void _onBackground() {
    if (!ref.read(settingsProvider).lockEnabled) return;
    if (_justUnlocked()) return;
    _pausedAt ??= DateTime.now();
    if (!_unlocked) return; // 已经锁着，不用再动
    // 宽限期 0（"每次切回都上锁"）→ 现在就锁。
    // 等 resumed 再锁的话，用户回到前台会先看到一帧真实账目。
    if (_grace() != Duration.zero) return;
    _lockNow();
  }

  void _onResumed() {
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (!ref.read(settingsProvider).lockEnabled) return;
    if (_justUnlocked()) return;
    if (pausedAt == null) return;
    if (!shouldLockAfter(
      pausedAt: pausedAt,
      now: DateTime.now(),
      grace: _grace(),
    )) {
      return;
    }
    if (!_unlocked) return;
    _lockNow();
  }

  /// 当前生效的宽限期。偏好没补水完 → 按 0（最严格）处理。
  Duration _grace() {
    if (!ref.read(settingsHydratedProvider)) return _fallbackGrace;
    final s = ref.read(settingsProvider).lockGraceSeconds;
    return Duration(seconds: s < 0 ? 0 : s);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final hydrated = ref.watch(settingsHydratedProvider);

    // 偏好还没从磁盘读完时**绝不能放行**：这一瞬间 lockEnabled 恒为 false。
    // 与其闪一下真实账目再盖上锁，不如先给一张空白纸。
    if (!hydrated) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const SizedBox.shrink(),
      );
    }

    if (!settings.lockEnabled || _unlocked) return widget.child;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 保持挂载但不绘制：解锁后回到原页面，草稿/滚动位置都还在。
        // Offstage 同时让它不可点击，默认 Finder 与读屏也会跳过
        // —— 锁着的时候不该有任何内容"漏"出去。
        //
        // ExcludeFocus 是必须的：底下那棵树的焦点域虽然看不见，但仍然是"活的"，
        // 抢着 primary focus，锁屏里的 PIN 框就永远拿不到焦点 ——
        // 键盘不弹、输入法无法输入，用户等于被自己的锁锁死。
        ExcludeFocus(
          child: Offstage(offstage: true, child: widget.child),
        ),
        Positioned.fill(
          // 锁屏自带一个 Navigator。
          //
          // 两个原因：
          // ① `TextField` 需要 Overlay 祖先（放选择手柄/放大镜），而 `LockGate`
          //    在 Navigator **之上**，下面的 Overlay 层级上不算祖先，真机直接断言
          //    "No Overlay widget found"；
          // ② 更要命的是**焦点域**：没有 Navigator/Overlay 时 `autofocus` 不生效，
          //    键盘根本不弹 —— 用户面对一个输不进字的 PIN 框等于被锁死。
          //    内置 Navigator 自带 FocusScope，autofocus 才正常工作。
          //
          // 外面必须包 HeroControllerScope.none：MaterialApp 的 HeroController
          // 不能同时被两个 Navigator 共用，否则每帧断言一次。
          child: HeroControllerScope.none(
            child: Navigator(
              key: const ValueKey('lock-layer'),
              onGenerateRoute: (_) => PageRouteBuilder(
                transitionDuration: Duration.zero,
                reverseTransitionDuration: Duration.zero,
                pageBuilder: (_, __, ___) => _LockScreen(
                  biometricEnabled: settings.biometricEnabled,
                  onUnlocked: _onUnlocked,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 锁屏本体。只管"输 PIN / 指纹"，解锁成功回调给 [LockGate]。
///
/// 单独抽成 StatefulWidget：它可能被整块重建（换主题、切前后台），
/// 而输入内容、错误提示、指纹弹没弹过都该留在自己身上。
class _LockScreen extends StatefulWidget {
  const _LockScreen({
    required this.biometricEnabled,
    required this.onUnlocked,
  });

  final bool biometricEnabled;
  final VoidCallback onUnlocked;

  @override
  State<_LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<_LockScreen> with WidgetsBindingObserver {
  final _pinCtrl = TextEditingController();
  final _pinFocus = FocusNode();
  String? _error;

  /// 已经自动弹过一次指纹：避免每次 rebuild 都弹。
  bool _bioTried = false;

  /// 指纹没通过时给一句人话，别让按钮按了跟没按一样。
  String? _bioHint;

  /// 当前是否在前台。后台弹指纹只会被系统取消，
  /// 用户回到前台只看到一句「没通过」，像锁坏了。
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 锁可能是「切走那一刻」挂上的，此时 App 还在后台：别在那儿弹指纹。
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // autofocus 在这个层级（Navigator 之上、被 ExcludeFocus 隔开的兄弟节点里）
      // 不一定抢得到焦点，所以再显式要一次。
      if (mounted) _pinFocus.requestFocus();
      _autoBiometric();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pinCtrl.dispose();
    _pinFocus.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (!wasForeground && _foreground) {
      // 回到前台：还锁着且指纹一次没弹过，这时候补弹一次。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _autoBiometric();
      });
    }
  }

  void _autoBiometric() {
    if (!widget.biometricEnabled || _bioTried || !_foreground) return;
    _bioTried = true;
    _tryBiometric();
  }

  /// 弹系统生物识别。成功直接解锁；失败/取消就留在 PIN 输入界面。
  Future<void> _tryBiometric() async {
    final ok = await BiometricService.authenticate();
    if (!mounted) return;
    if (ok) {
      widget.onUnlocked();
    } else {
      // 硬件没录、被系统锁、用户点了取消，三种情况长得一模一样。
      // 给一句提示，至少知道要用 PIN。
      setState(() => _bioHint = '指纹没通过，请输入 PIN 解锁');
    }
  }

  /// 输到 PIN 的位数就自动解锁，不用再去够下面的按钮。
  ///
  /// 位数存在偏好里（settings.pinLength）；老数据没记长度（0）就退回手动点「解锁」。
  void _onPinChanged(String v) {
    if (_error != null) setState(() => _error = null);
    final want =
        ProviderScope.containerOf(context).read(settingsProvider).pinLength;
    if (want <= 0) return;
    if (v.length != want) return;
    _submit();
  }

  void _submit() {
    final pin = _pinCtrl.text.trim();
    if (pin.isEmpty) return;
    final container = ProviderScope.containerOf(context);
    final settings = container.read(settingsProvider);
    final notifier = container.read(settingsProvider.notifier);
    if (notifier.verifyPin(pin)) {
      // 老数据没记长度（0）：这次成功了就补上，下次起「输满即解锁」生效
      if (settings.pinLength <= 0) notifier.rememberPinLength(pin.length);
      widget.onUnlocked();
    } else {
      setState(() {
        _error = 'PIN 不正确';
        // 输错就清空：不清的话用户接着敲只会越敲越长，
        // 「输满自动解锁」就再也不会触发了。
        _pinCtrl.clear();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 不再包 GestureDetector「吞点击」：底下那棵树被 Offstage 摘掉后本就
    // 收不到触摸，而外层 tap 会和里面的「解锁」按钮抢手势，导致点了没反应。
    return Scaffold(
      backgroundColor: Palette.paper(context),
      body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: Palette.brand(context),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.lock_outline,
                        color: Colors.white, size: 32),
                  ),
                  const SizedBox(height: 18),
                  Text('简记已锁定',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Palette.ink(context))),
                  const SizedBox(height: 6),
                  Text('输入 PIN 继续',
                      style: TextStyle(
                          fontSize: 12, color: Palette.inkFaint(context))),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _pinCtrl,
                    focusNode: _pinFocus,
                    autofocus: true,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 20, letterSpacing: 8),
                    onChanged: _onPinChanged,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: '••••',
                      errorText: _error,
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton(
                      onPressed: _submit,
                      child: const Text('解锁'),
                    ),
                  ),
                  // 指纹是 PIN 的快捷方式：这里只提供手动触发，
                  // 失败/没录入都能继续输 PIN，锁的安全等级不降。
                  if (widget.biometricEnabled) ...[
                    const SizedBox(height: 10),
                    PressScale(
                      scale: 0.94,
                      onTap: _tryBiometric,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.fingerprint,
                                size: 18, color: Palette.brand(context)),
                            const SizedBox(width: 6),
                            Text('用指纹 / 面容解锁',
                                style: TextStyle(
                                    fontSize: 13,
                                    color: Palette.brand(context))),
                          ],
                        ),
                      ),
                    ),
                    if (_bioHint != null)
                      Text(_bioHint!,
                          style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.error)),
                  ],
                ],
              ),
            ),
          ),
        ),
    );
  }
}
