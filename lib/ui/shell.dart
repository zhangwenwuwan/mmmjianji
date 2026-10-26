import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auto_backup.dart';
import '../services/widget_bridge.dart';
import '../state/ledger_state.dart';
import 'assets_page.dart';
import 'book_manage_page.dart';
import 'calendar_page.dart';
import 'insight_hub_page.dart';
import 'insights_page.dart';
import 'ledger_page.dart';
import 'lock_gate.dart';
import 'motion.dart';
import 'pocket_manage_page.dart';
import 'profile_page.dart';
import 'theme.dart';

/// 主框架：首页 / 统计 / 记账(+) / 资产 / 我的
///
/// 2026-10-25 改版：
/// - **日历从底栏撤掉**，改由首页右上角的小日历图标进入（push 独立页）。
///   底栏空出的位置给中间的「+ 记账」键 —— 记账是这个 App 最频繁的动作，
///   值得占一个显眼位置；之前藏在首页的通栏按钮和下拉手势里。
/// - 底栏变成 5 格，但只有 4 个是页面：中间那格是**动作**（直接开记账页），
///   不参与选中态。
class Shell extends ConsumerStatefulWidget {
  const Shell({super.key});

  @override
  ConsumerState<Shell> createState() => _ShellState();
}

class _ShellState extends ConsumerState<Shell> {
  /// 页面下标：0 首页 / 1 统计 / 2 资产 / 3 我的
  int _index = 0;
  int _prevIndex = 0;

  static const _titles = ['首页', '统计', '资产', '我的'];

  /// 底栏槽位 → 页面下标。槽 2 是「+ 记账」，不占页面。
  static const _slotToPage = {0: 0, 1: 1, 3: 2, 4: 3};

  /// 页面下标 → 底栏槽位（用来画选中态）。
  static const _pageToSlot = {0: 0, 1: 1, 2: 3, 3: 4};

  /// 四个主页面实例只创建一次，切页时由 IndexedStack 保留状态（滚动位置不丢失）。
  ///
  /// 首页要传回调（右上角的日历），所以不能整列 const。
  late final List<Widget> _pages = [
    LedgerPage(
      onCalendar: () => _openPage(const CalendarPage()),
    ),
    const InsightsPage(),
    const AssetsPage(),
    const ProfilePage(),
  ];

  void _openPage(Widget page) {
    Navigator.of(context).push(AppPageRoute(page: page));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _autoBackup();
      await _applyRecurring();
    });
  }

  /// 启动时备份一份（同一天只写一次，见 AutoBackup.run）
  Future<void> _autoBackup() async {
    try {
      final store = await ref.read(storeProvider.future);
      await AutoBackup.run(store);
    } catch (_) {
      // 备份失败不影响使用
    }
  }

  Future<void> _applyRecurring() async {
    try {
      final store = await ref.read(storeProvider.future);
      final book = await ref.read(activeBookProvider.future);
      final n = await store.applyDueRecurring(book.id, DateTime.now());
      if (n > 0) {
        bumpRevision(ref);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已按周期自动记了 $n 笔')),
        );
      }
    } catch (_) {
      // 自动补记失败不该挡住用户用 App
    }
  }

  /// 资产页右上角：添加账户（对齐参考版资产 tab 的 AppBar actions）
  Future<void> _addPocket() async {
    if (!mounted) return;
    await showPocketEditor(context, ref, null);
    // 新建完刷新一下余额（balancesProvider 由 revision 驱动，这里兜底）
    if (!mounted) return;
    bumpRevision(ref);
  }

  void _openBooks() {
    Navigator.of(context).push(AppPageRoute(page: const BookManagePage()));
  }

  bool _widgetSynced = false;

  @override
  Widget build(BuildContext context) {
    // 数据一变就把本月概览推给桌面小组件（内部有节流）
    ref.listen<int>(revisionProvider, (_, __) => WidgetBridge.sync(ref));
    if (!_widgetSynced) {
      _widgetSynced = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => WidgetBridge.sync(ref, force: true));
    }
    return LockGate(
      child: Scaffold(
        // 明细 tab 自带折叠头部（对齐原版 PrimaryHeader），所以不要外层 AppBar；
        // 其余 tab 用普通 AppBar。
        appBar: _index == 0
            ? null
            : AppBar(
                title: Text(_titles[_index]),
                actions: switch (_index) {
                  // 统计页：财务洞察（它是统计的延伸，和统计放一起才找得到）
                  1 => [
                      IconButton(
                        tooltip: '财务洞察',
                        onPressed: () =>
                            _openPage(const InsightHubPage()),
                        icon: const Icon(Icons.insights_outlined),
                      ),
                    ],
                  // 资产页：加账户 / 账本与汇率
                  2 => [
                      IconButton(
                        tooltip: '添加账户',
                        onPressed: _addPocket,
                        icon: const Icon(Icons.add),
                      ),
                      IconButton(
                        tooltip: '账本与汇率',
                        onPressed: _openBooks,
                        icon: const Icon(Icons.settings_outlined),
                      ),
                    ],
                  _ => null,
                },
              ),
        // 动效只作用在「单个页面」上，被选中的那一个播一次轻移。
        //
        // ⚠️ 不要用 AnimatedSwitcher 去包这个栈：那样新旧两个栈都带着
        // 全部 4 个页面做交叉淡入，会叠在一起出残影（0.6.0 踩过）。
        //
        // 【性能】原来是 `IndexedStack`：它**会把 4 个页面全部 layout**
        // （RenderIndexedStack 继承 RenderStack，只跳过 paint，不跳过 layout）。
        // 首页那一坨折叠头部 + 长列表、统计页的图表、资产页的净值走势全都跟着
        // 每次切 tab 重排一遍，弱 GPU 上就是那一顿。
        // 现在换成 `Stack + Offstage`：非当前页**连 layout 都不做**，
        // 再叠一层 `TickerMode(enabled: false)` 把它们身上的动画 ticker 也停掉。
        // 各页 State 仍然保留（滚动位置、输入内容都不丢）。
        body: Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < _pages.length; i++)
              Offstage(
                offstage: i != _index,
                child: TickerMode(
                  enabled: i == _index,
                  child: _TabPage(
                    key: ValueKey('tab-$i'),
                    active: i == _index,
                    fromRight: i > _prevIndex,
                    child: _pages[i],
                  ),
                ),
              ),
          ],
        ),
        bottomNavigationBar: _BottomBar(
          selectedSlot: _pageToSlot[_index]!,
          onSelect: (slot) {
            // 中间那格是动作不是页面：直接开记账页，选中态不变
            if (slot == 2) {
              openEntryEditor(context, ref);
              return;
            }
            final page = _slotToPage[slot];
            if (page == null) return;
            // 回首页 = 回本月。首页 2026-10-26 起不再有月份切换（顶栏只剩
            // 账本 + 三个图标），一旦在预算页/日历页把月份改成历史月，
            // 回来就会看到一个"没有出口的 9 月"。这里和 LedgerPage.initState
            // 一起兜住：进首页一律归位到当月。
            if (page == 0) {
              resetMonthToNow(ref);
            }
            if (page == _index) return;
            setState(() {
              _prevIndex = _index;
              _index = page;
            });
          },
        ),
      ),
    );
  }
}

/// 单个 tab 页的进场动效。
///
/// 只在「非激活 → 激活」那一刻播放一次淡入 + 轻移；退场不做动画
/// （IndexedStack 会直接停止绘制它），所以不会有两帧叠加的残影。
/// 尊重系统「减少动态效果」。
class _TabPage extends StatefulWidget {
  const _TabPage({
    super.key,
    required this.active,
    required this.fromRight,
    required this.child,
  });

  final bool active;

  /// 新页从右边（true）还是左边（false）进来，和操作方向一致
  final bool fromRight;
  final Widget child;

  @override
  State<_TabPage> createState() => _TabPageState();
}

class _TabPageState extends State<_TabPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: Motion.page,
  );

  /// 进出曲线**只建一次**。
  ///
  /// 以前这两个 CurvedAnimation 是在 build 里 new 的：每次切 tab（Shell 重建）
  /// 都会给 controller 挂一个新的监听器、而且旧的没人摘 —— 切十几次之后
  /// 一个 tick 要走十几个死回调。现在固定成字段，方向用两条 Tween 区分。
  late final Animation<double> _enter =
      CurvedAnimation(parent: _ctrl, curve: XCurve.enter);

  late final Animation<Offset> _slideFromRight = Tween<Offset>(
    begin: const Offset(0.05, 0),
    end: Offset.zero,
  ).animate(_enter);

  late final Animation<Offset> _slideFromLeft = Tween<Offset>(
    begin: const Offset(-0.05, 0),
    end: Offset.zero,
  ).animate(_enter);

  bool get _reduce => MediaQuery.of(context).disableAnimations;

  @override
  void initState() {
    super.initState();
    // 首帧直接到位：不能一进 App 四个页面一起闪
    _ctrl.value = widget.active ? 1.0 : 0.0;
  }

  @override
  void didUpdateWidget(covariant _TabPage old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      if (_reduce) {
        _ctrl.value = 1.0;
      } else {
        _ctrl.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 不再套 FadeTransition：原来那层 `Threshold(0.12)` 是"前 12% 全透明、
    // 之后直接 1.0"，视觉上就是硬切，却让整页白走一次 full-screen saveLayer。
    // 弱 GPU 上这一次 saveLayer 就是切 tab 时那一顿。
    //
    // RepaintBoundary 放在 SlideTransition **里面**：页面先栅格化成图层，
    // 位移只是换合成偏移，不再每帧重画整页（和 AppPageRoute 同一个道理）。
    return SlideTransition(
      position: widget.fromRight ? _slideFromRight : _slideFromLeft,
      child: RepaintBoundary(child: widget.child),
    );
  }
}

/// 自定义底栏：首页 / 统计 / **+** / 资产 / 我的。
///
/// 中间那格是动作键（直接开会话）而不是页面，所以不参与选中态；
/// 选中态只在前四个页面槽位上流动。
///
/// ui-motion：选中项背后有胶囊色块像水滴一样"流"过去（弹簧，前沿快后沿慢半拍）；
/// 选中图标弹性放大、其余缩一点；所有格子都有按下缩放手感。
class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.selectedSlot, required this.onSelect});

  /// 当前页面所在的槽位（0/1/3/4）；2 是记账键，永远不会是选中态
  final int selectedSlot;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final brand = Palette.brand(context);
    return Container(
      decoration: BoxDecoration(
        color: Palette.card(context),
        border: Border(top: BorderSide(color: Palette.hairline(context))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          // ⚠️ LayoutBuilder 必须包在 Stack **外面**，不能塞在 Positioned 里面：
          // 塞里面的话，Positioned 会把 StackParentData 挂到 LayoutBuilder 的
          // RenderObject 上（它只认 BoxParentData），运行时直接断言
          // "Incorrect use of ParentDataWidget"。
          child: LayoutBuilder(
            builder: (c, constraints) {
              final slotW = constraints.maxWidth / 5;
              return Stack(
                children: [
                  // 水滴指示：在选中槽位后面"流"过去。
                  // 用 AnimatedPositioned 而不是 AnimatedContainer + margin：
                  // 弹簧曲线会超调（曲线值冲到 1.1 以上），margin 算出来会变成负数，
                  // AnimatedContainer 直接断言 "margin.isNonNegative"。
                  AnimatedPositioned(
                    duration: Motion.d(c, const Duration(milliseconds: 340)),
                    curve: XCurve.spring,
                    left: slotW * selectedSlot + slotW * 0.14,
                    right: constraints.maxWidth - slotW * (selectedSlot + 0.86),
                    top: 10,
                    height: 30,
                    child: Container(
                      decoration: BoxDecoration(
                        color: brand.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(15),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      _tab(context, 0, Icons.home_outlined, Icons.home, '首页'),
                      _tab(context, 1, Icons.pie_chart_outline, Icons.pie_chart,
                          '统计'),
                      _addButton(context),
                      _tab(context, 3, Icons.account_balance_wallet_outlined,
                          Icons.account_balance_wallet, '资产'),
                      _tab(context, 4, Icons.person_outline, Icons.person, '我的'),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, int slot, IconData icon, IconData activeIcon,
      String label) {
    final selected = selectedSlot == slot;
    final color = selected ? Palette.brand(context) : Palette.inkFaint(context);
    return Expanded(
      child: PressScale(
        scale: 0.9,
        onTap: () => onSelect(slot),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: selected ? 1.0 : 0.86,
              duration: Motion.d(context, const Duration(milliseconds: 200)),
              curve: XCurve.spring,
              child: Icon(selected ? activeIcon : icon, size: 20, color: color),
            ),
            const SizedBox(height: 1),
            Text(label,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: color)),
          ],
        ),
      ),
    );
  }

  /// 中间的记账键：品牌色实心 + 号。
  ///
  /// 不给文字标签 —— 实心色块本身就是最强提示，加个字反而和旁边四个 tab
  /// 混成一排，失去"这是动作不是页面"的区别。
  Widget _addButton(BuildContext context) {
    final brand = Palette.brand(context);
    return Expanded(
      child: PressScale(
        scale: 0.9,
        onTap: () => onSelect(2),
        child: Center(
          child: Container(
            width: 46,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: brand,
              borderRadius: BorderRadius.circular(10),
              boxShadow: [
                BoxShadow(
                  color: brand.withValues(alpha: 0.28),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: const Icon(Icons.add, size: 20, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
