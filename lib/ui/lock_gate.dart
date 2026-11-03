import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/lock_rules.dart';
import '../services/biometric_service.dart';
import '../state/settings.dart';
import 'motion.dart';
import 'theme.dart';

/// 应用锁：冷启动就要锁；切到后台超过 [_LockGateState._gracePeriod] 再回来也要锁。
///
/// ⚠️ 这里的状态来源是「本次会话是否已解锁」，**不是**一个一次性的 `_locked` 布尔。
///
/// 之前的写法是在 `initState` 的 postFrame 里读一次 `settingsProvider.lockEnabled`
/// 来决定是否上锁。问题在于 `SettingsNotifier.build()` 首帧返回的是
/// `const AppSettings()`（`lockEnabled = false`），真正的偏好在
/// `Future.microtask(_hydrate)` 里 `await SharedPreferences.getInstance()` 之后才写回。
/// postFrame 回调早于 platform channel 回包 → 永远读到 `false` → 永远不上锁。
///
/// 现象：用户开了应用锁，杀掉进程重开，**一次 PIN 都不用输就能看全部账目**。
/// 只有「切后台 >30 秒再回来」那条路径才真的会锁，所以手工测很容易测漏。
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
  /// 2026-10-25 起这个值由用户在「外观与显示 → 应用锁」里自选
  /// （0 = 每次切回都锁），不再是写死的 30 秒。
  ///
  /// ⚠️ 偏好没补水完时（settingsHydratedProvider == false）按**最严格**处理，
  /// 即 grace = 0：宁可多锁一次，也不能出现"重启后短时间内免锁"的反向漏洞。
  static const _fallbackGrace = Duration.zero;

  /// 本次会话是否已经解锁过。进程重启即归零（这正是要的语义）。
  bool _unlocked = false;

  /// 已经自动弹过一次指纹验证：避免每次 rebuild 都弹
  bool _bioTried = false;

  /// 正在等系统生物识别弹窗返回。期间 App 可能被判成"切到后台"，
  /// 不能因此回锁，否则 grace=0 时会「验证成功 → 立刻回锁 → 再弹」死循环。
  bool _authing = false;

  /// 指纹没通过时给一句人话，别让按钮按了跟没按一样。
  String? _bioHint;

  /// 最近一次成功解锁的时间。**3 秒内不再回锁** —— 生物识别/系统凭据弹窗
  /// 本身会触发 resumed，不当心就「解锁成功 → 立刻回锁 → 再弹指纹」死循环，
  /// 表现就是"指纹根本用不了"。这招在 1.2.8 验证过。
  DateTime? _lastUnlockAt;

  DateTime? _pausedAt;
  final _pinCtrl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pinCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!ref.read(settingsProvider).lockEnabled) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // 自己弹的生物识别框也会让 App 进入后台；这种不算真的切走。
      // 不排除的话，grace=0 时验证一通过就立刻又被锁上（表现为「指纹根本用不了」）。
      if (_authing) return;
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      _pausedAt = null;
      // 刚解锁 3 秒内一律不回锁：系统生物识别/凭据弹窗本身会触发 resumed，
      // 这是 1.2.8 就修过的坑，不搬过来会「解开又立刻锁上」。
      final last = _lastUnlockAt;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(seconds: 3)) {
        return;
      }
      if (pausedAt != null && shouldLockAfter(
            pausedAt: pausedAt,
            now: DateTime.now(),
            grace: _grace(),
          )) {
        setState(() {
          _unlocked = false;
          _bioTried = false;
          _pinCtrl.clear();
          _error = null;
          _bioHint = null;
        });
      }
    }
  }

  /// 当前生效的宽限期。偏好没补水完 → 按 0（最严格）处理。
  Duration _grace() {
    final hydrated = ref.read(settingsHydratedProvider);
    if (!hydrated) return _fallbackGrace;
    final s = ref.read(settingsProvider).lockGraceSeconds;
    return Duration(seconds: s < 0 ? 0 : s);
  }

  /// 弹系统生物识别。成功直接解锁；失败/取消就留在 PIN 输入界面。
  Future<void> _tryBiometric() async {
    if (_authing) return;
    _authing = true;
    // 清掉可能被系统弹窗记下的 pausedAt：这次后台是我们自己弹的框造成的。
    _pausedAt = null;
    bool ok = false;
    try {
      ok = await BiometricService.authenticate();
    } finally {
      _authing = false;
    }
    if (!mounted) return;
    if (ok) {
      _lastUnlockAt = DateTime.now();
      setState(() {
        _unlocked = true;
        _error = null;
        _bioHint = null;
        _pinCtrl.clear();
      });
    } else {
      // 以前这里直接 return，用户按了指纹毫无反应 —— 硬件没录、被系统锁、
      // 用户点了取消，三种情况长得一模一样。给一句提示，至少知道要用 PIN。
      setState(() => _bioHint = '指纹没通过，请输入 PIN 解锁');
    }
  }

  /// 输到 PIN 的位数就自动解锁，不用再去够下面的按钮。
  ///
  /// 为什么按「长度」而不是「输入了就提交」：PIN 允许 4~8 位，
  /// 只有知道当初设了几位才能在不误判的前提下自动提交。位数存在偏好里
  /// （settings.pinLength）；老数据没记长度（0）就退回手动点「解锁」。
  ///
  /// 自动提交**不弹键盘之外的反馈**：错了照旧在 errorText 里显示「PIN 不正确」，
  /// 用户继续输即可（控件不会自己清空，避免"还没看清就没了"）。
  void _onPinChanged(String v) {
    if (_error != null) setState(() => _error = null);
    final want = ref.read(settingsProvider).pinLength;
    if (want <= 0) return; // 老数据没记长度：只能手动点「解锁」
    if (v.length != want) return;
    _submit();
  }

  void _submit() {
    final pin = _pinCtrl.text.trim();
    if (pin.isEmpty) return;
    final notifier = ref.read(settingsProvider.notifier);
    if (notifier.verifyPin(pin)) {
      // 老数据没记长度（0）：这次成功了就补上，下次起「输满即解锁」生效
      if (ref.read(settingsProvider).pinLength <= 0) {
        notifier.rememberPinLength(pin.length);
      }
      _lastUnlockAt = DateTime.now();
      setState(() {
        _unlocked = true;
        _error = null;
        _bioHint = null;
        _pinCtrl.clear();
      });
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

    // 没开锁，或本次会话已解锁 → 正常显示
    if (!settings.lockEnabled || _unlocked) return widget.child;

    // 指纹：开着就让系统自己弹一次（省一次点击），失败就老老实实输 PIN
    if (settings.biometricEnabled && !_bioTried) {
      _bioTried = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _tryBiometric());
    }

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
                if (settings.biometricEnabled) ...[
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
