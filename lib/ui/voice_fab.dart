import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/offline_speech.dart';
import 'theme.dart';
import 'voice_entry_page.dart';

/// 首页右下角那颗**只有麦克风图标**的圆形悬浮按钮。
///
/// 交互（用户定稿）：
///   点一下 → 首次会弹麦克风权限 → 按钮原地变成「收听中」波纹 → 直接说话
///   → 说完停顿一下自动收尾 → 本机离线识别 → 弹出确认窗口
///   → 用户在窗口里核对/修改 → 点「记一笔」才真正写库。
///
/// 全程不跳全屏页、不联网、不上传音频。识别引擎只在第一次点击时加载，
/// 加载失败也只是这颗按钮报错，不影响 App 其余部分。
class VoiceFab extends StatefulWidget {
  const VoiceFab({super.key});

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
        final scale = listening ? 1 + 0.04 * wave + 0.08 * _level : 1.0;
        return Transform.scale(
          scale: scale,
          child: _Ripple(
            active: listening,
            value: _pulse.value,
            level: _level,
            color: brand,
            child: Tooltip(
              message: listening ? '正在听，说完停一下就好' : '语音记账',
              child: GestureDetector(
                onTap: _start,
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
                        blurRadius: listening ? 18 + 14 * _level : 12,
                        offset: const Offset(0, 4),
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
                          listening ? Icons.mic : Icons.mic_none_outlined,
                          size: 24,
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
