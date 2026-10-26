import 'package:flutter/material.dart';

import 'theme.dart';

/// 启动页：Logo + 名字，短暂停留后淡出。
///
/// 关键是**不阻塞**：它自己是个静态画面，不 await 任何插件，
/// 所以首帧立刻出来，不会出现"白屏等半天"。
class SplashPage extends StatefulWidget {
  const SplashPage({super.key});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // ⚠️ 读 MediaQuery 必须放在这里，不能放 initState：
    // 在 initState 里读 InheritedWidget，debug 下会直接抛
    // "dependOnInheritedWidgetOfExactType<MediaQuery>() ... before initState() completed"。
    if (_started) return;
    _started = true;
    // 开了「减少动态效果」就直接显示，不做放大淡入
    if (MediaQuery.of(context).disableAnimations) {
      _ctrl.value = 1.0;
    } else {
      _ctrl.forward();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    final scale = Tween<double>(begin: 0.86, end: 1.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic),
    );
    final fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);

    return Scaffold(
      backgroundColor: Palette.paper(context),
      body: Center(
        child: FadeTransition(
          opacity: fade,
          child: ScaleTransition(
            scale: scale,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [brand, brand.withValues(alpha: 0.72)],
                    ),
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: brand.withValues(alpha: 0.28),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: const Text('📒', style: TextStyle(fontSize: 42)),
                ),
                const SizedBox(height: 18),
                Text('简记',
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 2,
                      color: Palette.ink(context),
                    )),
                const SizedBox(height: 6),
                Text('把每一笔，记得简单一点',
                    style: TextStyle(
                        fontSize: 12, color: Palette.inkFaint(context))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
