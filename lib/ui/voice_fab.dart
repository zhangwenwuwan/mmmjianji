import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/offline_speech.dart';
import '../state/settings.dart';
import 'boot_reveal.dart';
import 'theme.dart';
import 'voice_entry_page.dart';

// ---------------------------------------------------------------- 间距口径
//
// 底栏是悬浮胶囊：高 54、底部最小内边距 8（见 shell.dart 的 _BottomBar）。
// 首页 `extendBody: true`，所以按钮必须坐在底栏**上方**，并且要按系统手势条 /
// 三键导航的高度一起抬升，否则在部分机型上会被底栏压住。

const double _kBottomBarHeight = 54;
const double _kBottomBarInset = 8;
const double _kVoiceFabGap = 14;

/// 底栏上沿距屏幕底部的距离。
double _bottomBarTopInset(BuildContext context) {
  final sys = MediaQuery.of(context).padding.bottom;
  return _kBottomBarHeight + (sys > _kBottomBarInset ? sys : _kBottomBarInset);
}

/// 语音按钮下边缘距屏幕底部：底栏上沿再留一点呼吸空间。
double voiceFabBottom(BuildContext context) =>
    _bottomBarTopInset(context) + _kVoiceFabGap;

/// 列表尾部留白：滚到底时最后一笔流水要能完整露在按钮上方，
/// 不能出现「被悬浮层压住、又滚不出去」的内容。
double voiceFabClearance(BuildContext context) =>
    voiceFabBottom(context) + VoiceFab.size + 12;

/// 首页右下角那颗**只有麦克风图标**的圆形悬浮按钮。
///
/// 交互（用户定稿 2026-11-07）：
///   点一下 → 首次会弹麦克风权限 → 按钮原地变成「收听中」波纹 → 直接说话。
///   **再点一下 = 立刻结束收音**，不用等静音检测（周围吵、或者话说完了
///   想马上看结果时，把决定权交给用户）。
///   说完停顿一下仍会自动收尾 → 本机离线识别 → 弹出确认窗口
///   → 用户在窗口里核对/修改 → 点「记一笔」才真正写库。
///   长按 → 进入拖动，把按钮挪到顺手的位置（松手落位，位置记在偏好里）。
///
/// 全程不跳全屏页、不联网、不上传音频。识别引擎只在第一次点击时加载，
/// 加载失败也只是这颗按钮报错，不影响 App 其余部分。
class VoiceFab extends StatefulWidget {
  const VoiceFab({
    super.key,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
  });

  /// 长按开始：外层据此冻结定位动画，改成跟手。
  final VoidCallback? onDragStart;

  /// 长按移动：给的是**相对按下点的总位移**（不是增量），
  /// 外层用 `起点 + 位移` 算位置，不会因为丢帧累积误差。
  final ValueChanged<Offset>? onDragUpdate;

  /// 松手：外层把最终坐标落盘。
  final VoidCallback? onDragEnd;


  /// 按钮直径。列表尾部留白按同一数值计算（见 ledger_page.dart）。
  static const double size = 56;

  @override
  State<VoiceFab> createState() => _VoiceFabState();
}

class _VoiceFabState extends State<VoiceFab>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  SpeechStage _stage = SpeechStage.idle;
  double _level = 0;
  DateTime _lastLevelPaint = DateTime.fromMillisecondsSinceEpoch(0);

  /// 正在被拖动（长按后）。
  bool _dragging = false;

  /// 模型还在准备时用户就点了「结束」：等真正进收音立刻收尾。
  bool _stopAsap = false;

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _setStage(SpeechStage stage) {
    if (!mounted) return;
    setState(() {
      _stage = stage;
      if (stage == SpeechStage.listening) {
        _level = 0;
        _pulse.repeat();
      } else {
        _level = 0;
        _pulse.stop();
        _pulse.value = 0;
      }
    });
    // 用户在「准备中」就要求结束：这时候麦克风才刚开，直接收尾。
    if (stage == SpeechStage.listening && _stopAsap) {
      _stopAsap = false;
      OfflineSpeechService.instance.stopListening();
    }
  }

  /// 点一下：待机 → 开始；收音中 → 立刻结束。
  void _toggle() {
    switch (_stage) {
      case SpeechStage.idle:
        unawaited(_start());
      case SpeechStage.listening:
        OfflineSpeechService.instance.stopListening();
      case SpeechStage.preparing:
        // 模型首次加载要几秒，这期间点一下也算「我不说了」，
        // 等它真的开始收音立刻停。
        _stopAsap = true;
      case SpeechStage.recognizing:
        break; // 已经在推理，等结果
    }
  }

  void _onLevel(double level) {
    // 音频回调每秒几十次，压到 ~16fps 再 setState，别把整页拖着重绘。
    final now = DateTime.now();
    if (now.difference(_lastLevelPaint) < const Duration(milliseconds: 60)) {
      return;
    }
    _lastLevelPaint = now;
    if (mounted) setState(() => _level = level);
  }

  Future<void> _start() async {
    if (_stage != SpeechStage.idle) return;
    try {
      final text = await OfflineSpeechService.instance.listen(
        onStage: _setStage,
        onLevel: _onLevel,
      );
      if (!mounted) return;
      if (text.isEmpty) {
        _toast('没听清，靠近一点再说一次');
        return;
      }
      // 识别完只是给草稿，**确认权在用户手上**。
      await VoiceEntryPage.showAsDraftSheet(context, text);
    } on SpeechException catch (e) {
      if (mounted) _toast(e.message);
    } catch (e) {
      if (mounted) _toast('语音记账没成功：$e');
    } finally {
      _stopAsap = false;
      _setStage(SpeechStage.idle);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final on = Palette.onGradient(context);
    final brand = Palette.brand(context);
    final listening = _stage == SpeechStage.listening;
    final busy = _stage == SpeechStage.preparing ||
        _stage == SpeechStage.recognizing;

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final wave = listening ? math.sin(_pulse.value * math.pi * 2) : 0.0;
        // 收听时随音量轻微呼吸；空闲/忙碌时保持圆形不抖。
        // 拖动时整体放大一点 + 阴影加深，手感上「拿起来了」。
        var scale = listening ? 1 + 0.04 * wave + 0.08 * _level : 1.0;
        if (_dragging) scale = 1.08;
        return Transform.scale(
          scale: scale,
          child: _Ripple(
            active: listening,
            value: _pulse.value,
            level: _level,
            color: brand,
            child: Semantics(
              button: true,
              label: switch (_stage) {
                SpeechStage.listening => '正在听，点一下结束',
                SpeechStage.preparing => '正在准备语音识别',
                SpeechStage.recognizing => '正在识别',
                SpeechStage.idle => '语音记账，点一下开始，长按可拖动',
              },
              // ⚠️ 不能套 Tooltip：它在移动端就是长按触发，
              // 会和「长按拖动」抢手势（谁先到 500ms 谁赢，拖动会时灵时不灵）。
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggle,
                onLongPressStart: (_) {
                  HapticFeedback.mediumImpact();
                  setState(() => _dragging = true);
                  widget.onDragStart?.call();
                },
                onLongPressMoveUpdate: (d) =>
                    widget.onDragUpdate?.call(d.offsetFromOrigin),
                onLongPressEnd: (_) {
                  setState(() => _dragging = false);
                  widget.onDragEnd?.call();
                },
                onLongPressCancel: () {
                  if (!_dragging) return;
                  setState(() => _dragging = false);
                  widget.onDragEnd?.call();
                },
                child: Container(
                  key: const ValueKey('voice-entry-fab'),
                  width: VoiceFab.size,
                  height: VoiceFab.size,
                  decoration: BoxDecoration(
                    gradient: Palette.gradient(context),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: brand.withValues(alpha: listening ? 0.42 : 0.28),
                        blurRadius:
                            _dragging ? 24 : (listening ? 18 + 14 * _level : 12),
                        offset: Offset(0, _dragging ? 10 : 4),
                      ),
                    ],
                  ),
                  child: busy
                      ? Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: on,
                            ),
                          ),
                        )
                      : Icon(
                          listening ? Icons.stop_rounded : Icons.mic_none_outlined,
                          size: listening ? 26 : 24,
                          color: on,
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 收听态的两圈扩散波纹。用两层错开半拍的圆环，比单层更像「在听」。
class _Ripple extends StatelessWidget {
  const _Ripple({
    required this.active,
    required this.value,
    required this.level,
    required this.color,
    required this.child,
  });

  final bool active;
  final double value;
  final double level;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        for (var i = 0; i < 2; i++)
          _ring(((value + i * 0.5) % 1.0)),
        child,
      ],
    );
  }

  Widget _ring(double t) {
    return Transform.scale(
      scale: 1.0 + t * (0.75 + level * 0.25),
      child: Container(
        width: VoiceFab.size,
        height: VoiceFab.size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: color.withValues(alpha: (1 - t) * 0.38),
            width: 2,
          ),
        ),
      ),
    );
  }
}

/// 语音按钮的**定位层**：铺满首页，负责「拖到哪、记在哪」。
///
/// 为什么要单独一层：按钮位置是用户拖出来的，不能再用 `Positioned(right/bottom)`
/// 写死在右下角。用 `Positioned.fill` + 内部 `Stack`，命中测试只会落在按钮本体上
/// （Stack 只对真正画了东西的 child 命中），所以这层盖在流水列表上也不抢点击。
///
/// 坐标按**可用行程归一化**存（0~1）：换分辨率、转屏、改字号后按钮不会跑出屏幕。
class VoiceFabLayer extends ConsumerStatefulWidget {
  const VoiceFabLayer({super.key});

  @override
  ConsumerState<VoiceFabLayer> createState() => _VoiceFabLayerState();
}

class _VoiceFabLayerState extends ConsumerState<VoiceFabLayer> {
  /// 离屏幕边缘最近留多少。默认位置就是「右边 14、底栏上方 14」。
  static const double _edge = 14;

  /// 拖动中的坐标（本层坐标系）。null = 没在拖。
  Offset? _drag;

  /// 这次拖动按下时的坐标，配合手势给的「相对按下点总位移」算位置。
  Offset _dragFrom = Offset.zero;

  void _persist(double maxX, double maxY) {
    final p = _drag;
    if (p == null) return;
    final nx = maxX <= 0 ? 0.0 : ((p.dx - _edge) / maxX).clamp(0.0, 1.0).toDouble();
    final ny = maxY <= 0 ? 0.0 : ((p.dy - _edge) / maxY).clamp(0.0, 1.0).toDouble();
    // state 是同步更新的，rebuild 时 rest 已经等于松手位置，不会弹一下。
    unawaited(ref.read(settingsProvider.notifier).setVoiceFabPos(nx, ny));
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    // 底部给悬浮底栏让位：按钮下边缘永远在底栏上方。
    final bottomReserve = voiceFabBottom(context);

    return LayoutBuilder(builder: (context, constraints) {
      final area = constraints.biggest;
      // 可用行程（按钮左上角的取值范围）。
      final maxX = math.max(0.0, area.width - VoiceFab.size - _edge * 2);
      final maxY = math.max(0.0, area.height - bottomReserve - VoiceFab.size - _edge);

      // 没挪过 → 右下角（和改版前的位置一致）。
      final nx = settings.voiceFabMoved ? settings.voiceFabDx : 1.0;
      final ny = settings.voiceFabMoved ? settings.voiceFabDy : 1.0;
      final rest = Offset(_edge + nx * maxX, _edge + ny * maxY);
      final pos = _drag ?? rest;

      double clampX(double x) => math.min(math.max(x, _edge), _edge + maxX);
      double clampY(double y) => math.min(math.max(y, _edge), _edge + maxY);

      return Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedPositioned(
            // 拖动时不能有动画，否则按钮会追着手指后面飘。
            duration:
                _drag == null ? const Duration(milliseconds: 220) : Duration.zero,
            curve: Curves.easeOutCubic,
            left: pos.dx,
            top: pos.dy,
            // 和底栏同为第 0 块：冷启动时一起从下方浮上来。
            child: BootRevealItem(
              index: 0,
              y: 22,
              child: VoiceFab(
                onDragStart: () => setState(() {
                  _dragFrom = pos;
                  _drag = pos;
                }),
                onDragUpdate: (delta) => setState(() => _drag = Offset(
                      clampX(_dragFrom.dx + delta.dx),
                      clampY(_dragFrom.dy + delta.dy),
                    )),
                onDragEnd: () {
                  _persist(maxX, maxY);
                  setState(() => _drag = null);
                },
              ),
            ),
          ),
        ],
      );
    });
  }
}
