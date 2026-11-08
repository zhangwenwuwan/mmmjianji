import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/auto_backup.dart';
import '../services/reminder_service.dart';
import '../services/widget_bridge.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'assets_page.dart';
import 'boot_reveal.dart';
import 'book_manage_page.dart';
import 'common.dart';
import 'calendar_page.dart';
import 'glass.dart';
import 'insight_hub_page.dart';
import 'insights_page.dart';
import 'ledger_page.dart';
import 'motion.dart';
import 'pocket_manage_page.dart';
import 'profile_page.dart';
import 'tab_header.dart';
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

  /// 已经创建过的 tab 下标（首帧只有首页）。
  ///
  /// 2026-10-28 加：原来 4 个页面**首帧全部 build**（Stack 里四个 Offstage 都建），
  /// 冷启动首帧因此从 443ms 涨到 899ms —— 450ms 全花在"建三个用户还没看的页面"上。
  /// 现在只建用户真正进去过的：首帧只有首页，切到哪个才建哪个。
  /// 建过的一直留在树上，State（滚动位置、输入内容）照样不丢。
  final Set<int> _visited = {0};

  /// 上一次按返回键的时刻：两次都在 [_exitWindow] 内才真的退出。
  ///
  /// 为什么不做「按一下就退」：这是根路由，误触一次就直接把 App 关掉，
  /// 尤其是手势返回（从边缘划）很容易带出来。国内记账 App 基本都是两段式。
  DateTime? _lastBackAt;
  static const _exitWindow = Duration(seconds: 2);

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
      await _syncDueReminders();
      await _checkBudget();
    });
  }

  /// 预算超支提醒：本月**预算口径**支出达到 80% 或超支时，发一次即时通知。
  ///
  /// 同一个「月份+档位（80/100）」只发一次（去重在 ReminderService 内部），
  /// 所以每记一笔都调用也不会重复轰炸。复用「到期提醒」的通知总开关。
  Future<void> _checkBudget() async {
    try {
      final settings = ref.read(settingsProvider);
      if (!settings.dueReminderEnabled) return;
      final store = await ref.read(storeProvider.future);
      final book = await ref.read(activeBookProvider.future);
      // 预算提醒永远看**当前自然月**，不受首页翻月影响。
      final now = DateTime.now();
      final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final budget = await store.budgetOf(book.id, now);
      if (budget > 0) {
        final spent = await budgetSpentOf(store, book, now);
        await ReminderService.notifyBudget(
          spentCents: spent,
          budgetCents: budget,
          symbol: settings.symbol,
          monthKey: monthKey,
        );
      }
      // 分类预算要单独判一次：有人只设了「食」的预算、没设总额，
      // 若沿用上面的 `budget <= 0 → return`，这类用户的分类预算永远不提醒。
      final status = await bucketBudgetStatusOf(store, book, now);
      await ReminderService.notifyBucketBudgets(
        items: [
          for (final s in status)
            (
              bucketId: s.bucketId,
              title: s.title,
              spentCents: s.spentCents,
              budgetCents: s.budgetCents,
            ),
        ],
        symbol: settings.symbol,
        monthKey: monthKey,
      );
    } catch (_) {
      // 提醒失败不影响使用
    }
  }

  /// 到期提醒排程：启动时排一次，设置或数据变化时由 ref.listen 重排。
  ///
  /// 关掉开关时只清不掉（syncDueReminders 内部处理），这里提前短路，
  /// 免得每次切主题都去读一遍账本数据。
  Future<void> _syncDueReminders() async {
    try {
      final settings = ref.read(settingsProvider);
      if (!settings.dueReminderEnabled) {
        await ReminderService.cancelAllDue();
        return;
      }
      final reminders = await ref.read(dueRemindersProvider.future);
      await ReminderService.syncDueReminders(
        reminders,
        enabled: true,
        leadDays: settings.dueReminderLeadDays,
      );
    } catch (_) {
      // 排期失败不该挡住用户用 App
    }
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
        ScaffoldMessenger.of(context).toast('已按周期自动记了 $n 笔');
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

  /// 顶栏右侧动作。和原来 AppBar 里的 actions 一一对应，只是搬了个位置。
  List<Widget> _headerActions() {
    return switch (_index) {
      // 统计页：财务洞察（它是统计的延伸，和统计放一起才找得到）
      1 => [
          IconButton(
            tooltip: '财务洞察',
            onPressed: () => _openPage(const InsightHubPage()),
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
      _ => const [],
    };
  }

  bool _widgetSynced = false;

  /// 系统返回键（Android 按键 / 边缘手势）。
  ///
  /// Shell 是根路由，默认按一下就直接退出 App。这里分两级：
  /// 1. 不在首页 → **先回首页**。在「统计/资产/我的」按返回直接退出是最反直觉的
  ///    一种行为（用户多数只是想去首页），顺带把月份归位到本月，和点底栏
  ///    「首页」完全一致；
  /// 2. 已经在首页 → 第一次只给提示，[_exitWindow] 内再按一次才真的退出。
  ///
  /// 只挂在**解锁后**的这棵树上（PopScope 是 LockGate 的 child）：
  /// 锁屏时按返回的行为不变，不会先弹一句"再返回一次退出"再让你看到锁屏。
  void _onBack(bool didPop, Object? result) {
    if (didPop) return;
    if (_index != 0) {
      resetMonthToNow(ref);
      setState(() {
        _prevIndex = _index;
        _index = 0;
      });
      // 和点底栏首页一样，同步「当前可见 tab」——
      // 否则返回后资产页仍被当成可见，revision 一变还会去重算净值扫描。
      ref.read(activeTabProvider.notifier).state = 0;
      return;
    }
    final now = DateTime.now();
    final last = _lastBackAt;
    if (last != null && now.difference(last) <= _exitWindow) {
      SystemNavigator.pop();
      return;
    }
    _lastBackAt = now;
    // 用 SnackBar（toast）而不是系统 Toast：它跟着 Scaffold 走，位置在悬浮
    // 底栏**上方**，不会被胶囊盖住半截；时长 2 秒正好等于判定窗口，
    // 提示消失即窗口关闭。
    ScaffoldMessenger.of(context).toast('再返回一次退出');
  }

  @override
  Widget build(BuildContext context) {
    // 数据一变就把本月概览推给桌面小组件（内部有节流）；顺带查一次预算是否越线。
    ref.listen<int>(revisionProvider, (_, __) {
      WidgetBridge.sync(ref);
      _checkBudget();
    });

    // 到期提醒排程：设置（开关 / 提前天数）或数据（新增信用卡、改目标日期）
    // 一变就重排。关开关时 syncDueReminders 内部会清掉旧通知。
    ref.listen<AppSettings>(settingsProvider, (_, __) {
      _syncDueReminders();
      _checkBudget();
    });
    ref.listen(dueRemindersProvider, (_, __) => _syncDueReminders());

    // 资产页的净值蜡烛图**不再**自己跟着 revision 刷新（那是 6 个月 × 每天的
    // 逐日扫描，全 App 最重的一次查询；以前在首页记一笔它也在后台重跑）。
    // 这里补两个刷新点，保证「看得见的时候永远是新的」：
    //   ① 停在资产页时数据变了（比如在资产页点 + 记了一笔）→ 立刻重算；
    //   ② 不在资产页时什么都不做，切过去的那一刻由 onSelect 补。
    ref.listen<int>(activeTabProvider, (prev, next) {
      if (next == 2 && prev != 2) {
        ref.invalidate(netWorthCandlesProvider(6));
      }
    });
    ref.listen<int>(revisionProvider, (_, __) {
      if (ref.read(activeTabProvider) == 2) {
        ref.invalidate(netWorthCandlesProvider(6));
      }
    });
    if (!_widgetSynced) {
      _widgetSynced = true;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => WidgetBridge.sync(ref, force: true));
    }
    // ⚠️ extendBody 是"真悬浮"的开关：不加它，Scaffold 会在底栏上方
    // 留出一整块空白，胶囊只是画在那块空白里的一个圆角矩形 —— 看着就是
    // "底板上贴了块板"。加了它，body 撑到屏幕底，流水会滚到胶囊**底下**，
    // 隔着半透明玻璃透出来，这才是悬浮。
    //
    // 代价：四个页面的滚动区必须留够底部内边距，否则最后一条账目会被
    // 胶囊压住且永远滚不出来。目前四个页面统一是 88（胶囊总高 62，
    // 滚到底时最后一项停在胶囊上方 26）。改胶囊高度就要同步改这个值。
    final Widget home = Scaffold(
      extendBody: true,
      // 不再用 Material AppBar（2026-10-28 统一顶栏）：
      // 四个 tab 现在共用自绘的 TabHeader（玻璃 + 48 高 + 17px 标题），
      // 它叠在 body 的 Stack 里、浮在内容上面，页面自己留顶部内边距。
      // 首页（index 0）不用它 —— 首页顶栏还要放账本 chip 和封面。
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
            // 只建「进去过」的页面：首帧只有首页，省掉 3 个页面的构建成本。
            if (_visited.contains(i))
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
          // 顶栏浮在页面之上（玻璃），内容从它下面滚过去。
          // ⚠️ 页面里的滚动区必须留出 TabHeader.heightOf(context) 的顶部
          // 内边距，否则第一张卡会被压在条底下。
          if (_index != 0)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: TabHeader(
                title: _titles[_index],
                actions: _headerActions(),
              ),
            ),
        ],
      ),
      // 底栏和顶栏同为第 0 块：冷启动时和首页一起从下浮上来，
      // 否则幕张开的一瞬间底栏是"焊死"的、内容是浮的，两截。
      // 悬浮胶囊从下方浮上来：幅度给到 22，比页面内容的 22 稍大一点，
      // 才看得出它是"浮"起来的（和顶栏的下沉方向相反，一进一出一收一放）。
      bottomNavigationBar: BootRevealItem(
        index: 0,
        y: 22,
        child: LiquidBottomBar(
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
            if (page == _index) {
              // 再点当前 tab = 回到顶部。以前这里直接 return，
              // 按了完全没反应（唯一的反馈是 PressScale 的缩放）。
              // 首页把 ScrollController 挂在 homeScrollProvider 上（别的页还没挂）。
              final ctl = homeScrollController;
              if (ctl != null && ctl.hasClients && ctl.offset > 0) {
                ctl.animateTo(0,
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic);
              }
              return;
            }
            setState(() {
              _visited.add(page); // 第一次进这个 tab，这时候才建它的页面
              _prevIndex = _index;
              _index = page;
            });
            // 记录可见 tab：看不见的页面据此不再跑重查询。
            // 切到资产页时由上面的 ref.listen 补一次净值扫描（离开期间
            // 可能记过账，光靠 revision 监听补不到）。
            ref.read(activeTabProvider.notifier).state = page;
          },
        ),
      ),
    );

    // 返回键两段式（见 _onBack）。
    //
    // 应用锁已移到 MaterialApp.builder（Navigator 之上），不在这里了：
    // 挂在这棵子树里会被 push 出来的页面盖住，锁屏根本不出现。
    // 锁屏期间系统返回由 LockGate.didPopRoute 吞掉。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onBack,
      child: home,
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

/// 悬浮胶囊底栏：首页 / 统计 / **+** / 资产 / 我的。
///
/// 2026-10-27 照一木记账的样式重做（原来是一条顶到两边、上方带分割线的实心条）：
/// - **悬浮胶囊**：左右各留 14、底部留 8、整条圆角 24、带柔和投影，
///   压在薄荷纸面上像一片浮起来的板，而不是"钉"在屏幕底边。
/// - **选中态是浅绿圆角块**，把图标和文字**一起**包住（原来只包图标那一小条）。
/// - **图标恒为描边**：选中只换颜色、不换成实心，和薄荷底一起看才轻。
///
/// 中间那格是动作键（直接开记账页）而不是页面，所以不参与选中态；
/// 选中态只在前四个页面槽位上流动。
///
  /// 关于毛玻璃：**必须**是半透明的，否则"悬浮"只是个圆角矩形。
  /// 开了 extendBody 之后流水会滚到它底下，隔着 16 的模糊透出来，
  /// 才看得出内容是从它下面走过去的（而不是被它挡住）。
  /// tint 给到 0.74：比顶栏的 0.66 实一点，因为底下压的是金额数字，
  /// 透得太清楚会和图标叠在一起读不清。
  ///
  /// ui-motion：选中项背后有圆角块像水滴一样"流"过去（弹簧，前沿快后沿慢半拍）；
  /// 选中图标放大一点点；所有格子都有按下缩放手感。
  ///
  /// 2026-11-08 液态玻璃交互升级（参考 Kyant0/Backdrop 的 LiquidBottomTabs，
  /// 但**零新依赖、不动渲染后端**）：
  /// - 背景录制在 Compose 里是 layerBackdrop，这里等价物是 Scaffold 的
  ///   `extendBody: true` + Glass 的 BackdropFilter —— 已经做了，不重写。
  /// - 真折射（lens）需要 Impeller 的 ImageFilter.shader；本项目为老 GPU
  ///   关了 Impeller，所以用「按压缩放 + 跟手高光 + 边缘色散近似」做观感，
  ///   全机型可跑。缩放只作用于 Glass 的 child，**玻璃层本身不缩放**，
  ///   等价于官方的 layerBlock（教程里专门演示了连背景一起缩会错位）。
  /// - 选中水滴改成可拖拽：拖动跟手、松手弹簧吸附，拖动速度会让水滴
  ///   横向拉长/纵向压扁，模拟液体形变。
class LiquidBottomBar extends StatefulWidget {
  const LiquidBottomBar(
      {super.key, required this.selectedSlot, required this.onSelect});

  /// 当前页面所在的槽位（0/1/3/4）；2 是记账键，永远不会是选中态
  final int selectedSlot;
  final ValueChanged<int> onSelect;

  @override
  State<LiquidBottomBar> createState() => LiquidBottomBarState();
}

class LiquidBottomBarState extends State<LiquidBottomBar>
    with TickerProviderStateMixin {
  static const double _slotCount = 4; // 连续坐标 0..4
  static const List<int> _validSlots = [0, 1, 3, 4];

  /// 选中块的连续槽位坐标（0..4）。拖动时直接改 value，松手用弹簧吸附。
  late final AnimationController _pill = AnimationController.unbounded(
    vsync: this,
    value: widget.selectedSlot.toDouble(),
  );

  /// 按压进度 0..1：驱动内容缩放、跟手高光、边缘色散与内阴影。
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 170),
  );

  static final SpringDescription _spring =
      SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 420,
    ratio: 0.78, // <1 才有微微的超调，像液体撞一下再收住
  );

  double _slotWidth = 1;
  double _velocity = 0; // 归一化 -1..1，拖拽速度
  Offset? _touch;
  bool _dragging = false;

  bool get _reduce =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// 拖动过程中图标高亮跟着水滴走；扫过中间的 + 槽时保持当前页高亮，
  /// 免得图标在一瞬间乱闪。
  int get _activeSlot {
    final p = _pill.value.round().clamp(0, _slotCount.toInt()).toInt();
    return _validSlots.contains(p) ? p : widget.selectedSlot;
  }

  @override
  void initState() {
    super.initState();
    _pill.addListener(_tick);
    _press.addListener(_tick);
    _pill.addStatusListener((status) {
      if (status == AnimationStatus.completed && _velocity != 0) {
        _velocity = 0;
        _tick();
      }
    });
  }

  void _tick() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant LiquidBottomBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父级（返回键 / 再点当前 tab）改了页面下标时水滴才需要补一次动画；
    // 自己拖拽触发的 onSelect 会连带这次回调，但此时弹簧正在跑，别打断它。
    if (oldWidget.selectedSlot != widget.selectedSlot &&
        !_dragging &&
        !_pill.isAnimating) {
      _snap(widget.selectedSlot.toDouble());
    }
  }

  @override
  void dispose() {
    _pill.dispose();
    _press.dispose();
    super.dispose();
  }

  void _snap(double target, {double velocity = 0}) {
    if (_reduce) {
      _pill.value = target;
      return;
    }
    _pill.animateWith(SpringSimulation(
      _spring,
      _pill.value,
      target,
      velocity,
      tolerance: Tolerance(distance: 0.004, velocity: 0.02),
    ));
  }

  void _onTap(int slot) {
    if (slot != 2) _snap(slot.toDouble());
    widget.onSelect(slot);
  }

  void _pointerDown(Offset at) {
    _touch = at;
    if (!_reduce) _press.forward();
    _tick();
  }

  void _pointerUp() {
    _touch = null;
    _press.reverse();
  }

  void _dragStart(DragStartDetails d) {
    _dragging = true;
    _pill.stop();
    _touch = d.localPosition;
    if (!_reduce) _press.forward();
    _tick();
  }

  void _dragUpdate(DragUpdateDetails d) {
    final next = (_pill.value + d.delta.dx / _slotWidth)
        .clamp(0.0, _slotCount)
        .toDouble();
    _pill.value = next;
    // 16ms 一帧的近似：把每帧位移换算成「槽/帧」再夹到 ±1。
    _velocity = ((d.primaryDelta ?? 0) / _slotWidth * 6)
        .clamp(-1.0, 1.0)
        .toDouble();
    _touch = d.localPosition;
    _tick();
  }

  void _dragEnd(DragEndDetails _) {
    _dragging = false;
    final raw = _pill.value.round().clamp(0, _slotCount.toInt()).toInt();
    // 中间的 + 是动作键，绝不让它成为选中态 —— 按拖动方向就近落到 1 或 3。
    final target =
        _validSlots.contains(raw) ? raw : (_velocity >= 0 ? 3 : 1);
    _snap(target.toDouble(), velocity: _velocity * 4);
    _press.reverse();
    if (target != widget.selectedSlot) widget.onSelect(target);
  }

  void _dragCancel() {
    _dragging = false;
    _snap(widget.selectedSlot.toDouble());
    _press.reverse();
  }

  /// 胶囊高度 / 圆角 / 外边距。圆角取 24（略小于半高 27），
  /// 半高会在端头显得"尖"，24 更接近一木那种圆角方块。
  static const double _height = 54;
  static const double _radius = 24;
  static const double _insetH = 14;
  static const double _insetB = 8;

  @override
  Widget build(BuildContext context) {
    final dark = Palette.isDark(context);
    // minimum 是关键：手势导航的机器 SafeArea 底部内边距是 0，
    // 少了这个 minimum，胶囊会直接贴到屏幕底边，"悬浮"感立刻没了。
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(_insetH, 0, _insetH, _insetB),
      child: Container(
        height: _height,
        // 阴影画在外层容器上：阴影画在玻璃那一层会被它的 ClipRRect 裁掉，
        // 而且会通过半透明底透出一道脏边。外层容器只负责阴影，不填色。
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_radius),
          boxShadow: [
            // 主投影：往下 4，浅色下压得很淡（0.07），太重就成"厚塑料板"了
            BoxShadow(
              color: dark
                  ? Colors.black.withValues(alpha: 0.34)
                  : Colors.black.withValues(alpha: 0.07),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
            // 上缘一点品牌色微光：让它在薄荷纸面上像"浮着"而不是"扣着"
            if (!dark)
              BoxShadow(
                color: Palette.brand(context).withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
          ],
        ),
        child: Glass(
          // 2026-10-28 按「玻璃拟态五步配方」重做（原来 12 / 0.42 那档偏"白板"）：
          //
          // ① 加大模糊：CSS `backdrop-filter: blur(28px)` → 这里 24。
          //    不能直接抄 28：Flutter 的 sigma 是逻辑像素，28 在 5.5 寸屏上
          //    会把流水行糊成一整片灰雾（配方里也说了"太细碎的背景糊后会成一团"）。
          //    24 是"看得出有东西在动、但读不出内容"的临界点。
          // ② 提饱和度 saturate(170%)：**Flutter 做不到**。BackdropFilter 只接受
          //    ImageFilter，而 ImageFilter 没有颜色矩阵（ColorFilter 转不过去）。
          //    变通：tint 里掺 7~10% 品牌绿，让玻璃"有颜色" —— 视觉上等价于
          //    "模糊后不发灰"，而且更贴简记的薄荷调。
          // ③ 叠白纱：CSS 是 `rgb(255 255 255 / 10%)`，这里 0.20。
          //    配方背景是水面/云朵那种大块柔和场景；我们的背景是白卡片 + 深色数字，
          //    照抄 10% 会让图标和文字被后面的流水干扰。0.20 是折中。
          // ④ 高光出厚度：CSS `inset 1px 1px #fff8` → Glass 的 highlight
          //    （Flutter 的 BoxShadow 没有 inset，改用渐变，见 glass.dart）。
          // ⑤ 边缘折射（SVG 位移滤镜）：不做。手机尺寸上收益极低，成本很高。
          blur: 24,
          borderRadius: BorderRadius.circular(_radius),
          tint: Color.lerp(
            dark ? const Color(0xFF151C18) : Colors.white,
            Palette.brand(context),
            dark ? 0.10 : 0.07,
          )!
              .withValues(alpha: dark ? 0.30 : 0.20),
          highlight: true,
          // ⚠️ 必须是**四边同色**的 Border。
          //
          // 试过"上缘亮 0.72 / 左右 0.32 / 下缘 0.18"的分边描边（真实玻璃就是这样），
          // Flutter 直接断言：
          //   `A borderRadius can only be given on borders with uniform colors.`
          // 带圆角的 Border.paint 处理不了各边不同色（圆角处无法过渡）。
          // → 明暗层次改由上面的 gradient 承担（左上 0.34 → 右下 0.12，
          //   本身就是"上厚下薄"），Border 只负责一圈干净的边界。
          border: Border.all(
            color: Colors.white.withValues(alpha: dark ? 0.20 : 0.48),
            width: 0.9,
          ),
          // ⚠️ LayoutBuilder 必须包在 Stack **外面**，不能塞在 Positioned 里面：
          // 塞里面的话，Positioned 会把 StackParentData 挂到 LayoutBuilder 的
          // RenderObject 上（它只认 BoxParentData），运行时直接断言
          // "Incorrect use of ParentDataWidget"。
          child: LayoutBuilder(
            builder: (_, constraints) {
              final slotW = constraints.maxWidth / 5;
              _slotWidth = slotW;
              final pill = _pill.value.clamp(0.0, _slotCount).toDouble();
              final press = _press.value;
              final v = _velocity.abs();
              // ⚠️ 缩放只包在 Glass 的 child 上。玻璃层（BackdropFilter +
              // ClipRRect）留在原位，缩放它等于把背景采样一起放大，
              // 官方教程里专门演示了这个错位（要用 layerBlock 修）。
              return Listener(
                // translucent：玻璃边缘/圆角空白处也能收到按压，高光不漏。
                // Listener 不进手势竞技场，不会抢 tab 的点击。
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) => _pointerDown(e.localPosition),
                onPointerUp: (_) => _pointerUp(),
                onPointerCancel: (_) => _pointerUp(),
                child: GestureDetector(
                  onHorizontalDragStart: _dragStart,
                  onHorizontalDragUpdate: _dragUpdate,
                  onHorizontalDragEnd: _dragEnd,
                  onHorizontalDragCancel: _dragCancel,
                  child: Transform.scale(
                    scale: 1.0 + 0.035 * press,
                    child: Stack(
                      children: [
                        // 水滴指示：连续槽位坐标，拖动跟手、松手弹簧吸附。
                        // 不再用 AnimatedPositioned —— 弹簧超调会让 right 变负
                        // （margin.isNonNegative 断言），改成 left + width。
                        Positioned(
                          left: slotW * pill + slotW * 0.12,
                          width: slotW * 0.76,
                          top: 7,
                          height: 40,
                          child: Transform.scale(
                            // 拖得越快越"拉丝"：横向拉长、纵向压扁。
                            scaleX: 1.0 + v * 0.10,
                            scaleY: 1.0 - v * 0.05,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Palette.mint(context),
                                // 同心圆角（2026-10-28）：外层胶囊 24，选中块距上边缘 7，
                                // 所以内层要 24-7 = 17 才"同圆心"。
                                borderRadius: BorderRadius.circular(
                                    AppRadius.inside(_radius, 7)),
                              ),
                            ),
                          ),
                        ),
                        // 跟手高光 + 按压期边缘色散/内阴影（折射的廉价近似）。
                        // IgnorePointer：纯装饰层绝不抢 tab 的点击。
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _LiquidOverlayPainter(
                                progress: press,
                                touch: _touch,
                                radius: _radius,
                                accent: Palette.brand(context),
                                dark: dark,
                              ),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            _tab(context, 0, Icons.home_outlined, '首页'),
                            _tab(context, 1, Icons.pie_chart_outline, '统计'),
                            _addButton(context),
                            _tab(context, 3,
                                Icons.account_balance_wallet_outlined, '资产'),
                            _tab(context, 4, Icons.person_outline, '我的'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _tab(
      BuildContext context, int slot, IconData icon, String label) {
    // 高亮跟着水滴走（拖拽过程中也是），而不是等父级 setState 才变。
    final selected = _activeSlot == slot;
    final color = selected ? Palette.brand(context) : Palette.inkFaint(context);
    return Expanded(
      child: PressScale(
        scale: 0.9,
        onTap: () => _onTap(slot),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedScale(
              scale: selected ? 1.0 : 0.94,
              duration: Motion.d(context, const Duration(milliseconds: 200)),
              curve: XCurve.spring,
              child: Icon(icon, size: 21, color: color),
            ),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(
                    fontSize: 10.5,
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
  /// 高度收在 30（比胶囊内高 54 矮一半），不凸出到栏外：一木的五个格子是
  /// 一样大的，凸出的 FAB 会把悬浮胶囊的干净感破坏掉。
  Widget _addButton(BuildContext context) {
    final brand = Palette.brand(context);
    return Expanded(
      child: PressScale(
        scale: 0.9,
        onTap: () => _onTap(2),
        child: Center(
          child: Container(
            width: 44,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // 全 App 最显眼的一个"按钮"，跟着主题渐变走；
              // 图标颜色必须取 onGradient —— 浅渐变上白加号会看不见。
              gradient: Palette.gradient(context),
              borderRadius: BorderRadius.circular(11),
              boxShadow: [
                BoxShadow(
                  color: brand.withValues(alpha: 0.30),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(Icons.add,
                size: 18, color: Palette.onGradient(context)),
          ),
        ),
      ),
    );
  }
}

/// 液态玻璃的表面层：跟手高光 + 按压期边缘色散 + 内阴影。
///
/// 真折射（lens / chromaticAberration）要 Impeller 的 ImageFilter.shader，
/// 本项目走 Skia，这里用「一团会跟着手指走的光 + 一圈彩边 + 一道内暗边」
/// 近似玻璃被按下去时的光学变化。全部随 progress 淡入淡出，
/// 静止时 progress=0 直接 return，不产生任何额外绘制开销。
class _LiquidOverlayPainter extends CustomPainter {
  const _LiquidOverlayPainter({
    required this.progress,
    required this.touch,
    required this.radius,
    required this.accent,
    required this.dark,
  });

  final double progress;
  final Offset? touch;
  final double radius;
  final Color accent;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.001) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas.save();
    canvas.clipRRect(rrect);

    // ① 跟手高光：从触点散开的软光。浅色偏白、深色偏冷蓝。
    final at = touch;
    if (at != null) {
      final light = dark ? const Color(0xFF9FD8FF) : Colors.white;
      final cx = ((at.dx / size.width) * 2 - 1).clamp(-1.0, 1.0).toDouble();
      final cy = ((at.dy / size.height) * 2 - 1).clamp(-1.0, 1.0).toDouble();
      final shader = RadialGradient(
        center: Alignment(cx, cy),
        radius: 1.3,
        colors: [
          light.withValues(alpha: 0.22 * progress),
          light.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 1.0],
      ).createShader(rect);
      canvas.drawRect(rect, Paint()..shader = shader);
    }

    // ② 边缘色散：青 → 品牌 → 品红的一圈细描边。
    //    官方是 RGB 分通道按入射角错位采样，这里只借「彩边」观感。
    final rim = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        const Color(0xFF64D8FF).withValues(alpha: 0.34 * progress),
        accent.withValues(alpha: 0.16 * progress),
        const Color(0xFFFF8AD8).withValues(alpha: 0.30 * progress),
      ],
    ).createShader(rect);
    canvas.drawRRect(
      rrect.deflate(0.8),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = rim,
    );

    // ③ 内阴影：给玻璃一点厚度，只在按着或拖着时出现。
    final inner = dark ? Colors.white : Colors.black;
    canvas.drawRRect(
      rrect.deflate(2.4),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = inner.withValues(alpha: 0.10 * progress),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LiquidOverlayPainter old) =>
      old.progress != progress ||
      old.touch != touch ||
      old.radius != radius ||
      old.accent != accent ||
      old.dark != dark;
}
