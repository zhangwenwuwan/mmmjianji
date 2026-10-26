import 'package:flutter/material.dart';

import 'motion.dart';
import 'theme.dart';

/// 首次打开的欢迎引导（对齐原版 welcome_page）。
///
/// 三页讲清楚「本地优先 / 记账只要两步 / 数据在你自己手里」，
/// 只在第一次启动出现，之后不再打扰。
class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  final _ctrl = PageController();
  int _page = 0;

  static const _pages = [
    (
      icon: '🔒',
      title: '数据只在你手机里',
      body: '没有账号、没有服务器，也不联网。\n断网照样能记账。',
    ),
    (
      icon: '⚡',
      title: '记一笔只要两步',
      body: '选分类 → 输金额，两步就完事。\n常用备注可以一键复用。',
    ),
    (
      icon: '📤',
      title: '想走随时能带走',
      body: '备份导出成 JSON，换手机原样恢复。\n数据始终归你。',
    ),
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    final isLast = _page == _pages.length - 1;

    return Scaffold(
      backgroundColor: Palette.paper(context),
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: widget.onDone,
                child: Text('跳过',
                    style: TextStyle(
                        fontSize: 13, color: Palette.inkFaint(context))),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _ctrl,
                itemCount: _pages.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (_, i) {
                  final p = _pages[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 132,
                          height: 132,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: brand.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(36),
                          ),
                          child: Text(p.icon,
                              style: const TextStyle(fontSize: 60)),
                        ),
                        const SizedBox(height: 28),
                        Text(p.title,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                              color: Palette.ink(context),
                            )),
                        const SizedBox(height: 12),
                        Text(
                          p.body,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.75,
                            color: Palette.inkSoft(context),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // 圆点：跟着手指伸缩
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pages.length; i++)
                  AnimatedContainer(
                    duration: Motion.d(context, Motion.small),
                    curve: XCurve.smooth,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 20 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == _page ? brand : Palette.hairline(context),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 26),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: FilledButton(
                  onPressed: () {
                    if (isLast) {
                      widget.onDone();
                    } else {
                      _ctrl.nextPage(
                        duration: Motion.d(context, Motion.panel),
                        curve: XCurve.easeOut,
                      );
                    }
                  },
                  child: Text(isLast ? '开始记账' : '下一步',
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
