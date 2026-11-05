import 'app_glyph.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../core/home_modules.dart';
import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'font_settings_page.dart';
import 'home_modules_page.dart';
import 'motion.dart';
import 'theme.dart';

/// 外观与显示：配色、字体、金额显示、深浅色、货币符号、应用锁。
///
/// 参考版把这些收在「外观设置」子页里，「我的」页只留一个一级入口，
/// 避免一级页面被一堆开关撑爆。
class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    // 生物识别是否可用：桌面测试环境恒 false，那一行就不显示
    // 能不能点开关，只看设备能力；有没有录指纹只影响提示文案
    final biometricSupported =
        ref.watch(biometricSupportedProvider).valueOrNull ?? false;
    final biometricEnrolled =
        ref.watch(biometricEnrolledProvider).valueOrNull ?? false;
    final pockets = ref.watch(pocketsProvider).valueOrNull ?? const <Pocket>[];
    Pocket? defaultPocket;
    for (final p in pockets) {
      if (p.id == settings.defaultPocketId) {
        defaultPocket = p;
        break;
      }
    }

    return Scaffold(
      appBar: AppBar(title: const Text('外观与显示')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: [
          SectionLabel('配色'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final e in kPalettes.entries)
                  _paletteRow(context, ref, e.key, e.value, settings.paletteId),
              ],
            ),
          ),
          // ⚠️ 「安全」放在配色之后、其它设置之前：
          // ① 应用锁是少数「出问题就锁住数据」的设置，不该沉在页面最底下；
          // ② 页面最底部的控件在部分机型上被系统手势区吃掉点击（真机踩到：
          //    同一页面的「紧凑金额」能点，底部这个开关点不动）。
          const SizedBox(height: 18),
          SectionLabel('安全'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _switchTile(
                  context,
                  value: settings.lockEnabled,
                  onChanged: (v) async {
                    if (v) {
                      await _setPin(context, ref);
                    } else {
                      await ref.read(settingsProvider.notifier).disableLock();
                    }
                  },
                  title: '应用锁',
                  subtitle: '切后台回来要输 PIN',
                ),
                if (settings.lockEnabled) ...[
                  const Divider(height: 1, indent: 16),
                  PressScale(
                    scale: 0.99,
                    onTap: () => _pickLockGrace(context, ref),
                    child: ListTile(
                      leading: const Icon(Icons.timer_outlined),
                      title: const Text('多久后重新锁定',
                          style: TextStyle(fontSize: 14)),
                      subtitle: Text(
                        settings.lockGraceSeconds <= 0
                            ? '每次切回后台都要解锁'
                            : '切后台超过 ${_graceLabel(settings.lockGraceSeconds)}回来要输 PIN',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                    ),
                  ),
                  if (biometricSupported) const Divider(height: 1, indent: 16),
                  // 指纹行**始终显示**：设备不支持时置灰并说明原因。
                  // 完全隐藏的话，用户只会以为"这个版本没这功能"。
                  _switchTile(
                    context,
                    value: biometricSupported && settings.biometricEnabled,
                    // ⚠️ 不支持时必须传 null（不是空回调）：空回调照样会被
                    // 开关当成"可切换"，播完动画下一帧弹回去，看着像坏了。
                    onChanged: biometricSupported
                        ? (v) => ref
                            .read(settingsProvider.notifier)
                            .setBiometricEnabled(v)
                        : null,
                    title: '指纹 / 面容解锁',
                    subtitle: !biometricSupported
                        ? '此设备不支持生物识别'
                        : (biometricEnrolled
                            ? '用系统生物识别代替输入 PIN'
                            : '系统还没录指纹，录完就能用（锁屏页会弹指纹）'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('字体'),
          Panel(
            padding: EdgeInsets.zero,
            child: PressScale(
              scale: 0.98,
              onTap: () => Navigator.of(context)
                  .push(AppPageRoute(page: const FontSettingsPage())),
              child: ListTile(
                leading: const Icon(Icons.format_size_outlined),
                title: const Text('字体大小'),
                subtitle: Text(_fontScaleLabel(settings.fontScale)),
                trailing: const Icon(Icons.chevron_right, size: 18),
              ),
            ),
          ),
          const SizedBox(height: 18),
          // 2026-10-28：把「首页模块」入口接回来。1.4.9 删掉旧入口时页面留着没删，
          // 于是 HomeModulesPage 成了一个没有入口、也没有测试的孤儿文件，
          // 而 settings.modulesOrder / homeHidden 仍在被首页消费 ——
          // 等于用户能改到的东西没有一个能改它的地方。
          // 放在「外观与显示」里：它管的就是首页长什么样、几个模块、什么顺序。
          SectionLabel('首页'),
          Panel(
            padding: EdgeInsets.zero,
            child: PressScale(
              scale: 0.98,
              onTap: () => Navigator.of(context)
                  .push(AppPageRoute(page: const HomeModulesPage())),
              child: ListTile(
                leading: const Icon(Icons.view_agenda_outlined),
                title: const Text('首页模块'),
                subtitle: Text(_homeModulesLabel(settings)),
                trailing: const Icon(Icons.chevron_right, size: 18),
              ),
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('金额显示'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _switchTile(
                  context,
                  value: settings.compactAmounts,
                  onChanged: (v) async {
                    await ref
                        .read(settingsProvider.notifier)
                        .setCompactAmounts(v);
                    if (context.mounted) {
                      _toast(context, v ? '已开启紧凑金额' : '已关闭紧凑金额');
                    }
                  },
                  title: '紧凑金额',
                  subtitle: '一万元以上显示成 1.2万，列表更清爽',
                ),
                const Divider(height: 1, indent: 16),
                // 列表行主标题显示备注还是分类名（另一个挪到副标题，信息不丢）
                PressScale(
                  scale: 0.98,
                  onTap: () => showAppSheet<String>(
                    context: context,
                    title: '列表行主标题',
                    builder: (ctx) => Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final entry in const [
                          ('note', '备注优先', '有备注显示备注，否则显示分类名'),
                          ('category', '分类名优先', '显示分类名，备注挪到第二行'),
                        ])
                          ListTile(
                            title: Text(entry.$2),
                            subtitle: Text(entry.$3,
                                style: const TextStyle(fontSize: 12)),
                            trailing: settings.noteDisplay == entry.$1
                                ? const Icon(Icons.check)
                                : null,
                            onTap: () => Navigator.pop(ctx, entry.$1),
                          ),
                      ],
                    ),
                  ).then((v) {
                    if (v != null) {
                      ref.read(settingsProvider.notifier).setNoteDisplay(v);
                    }
                  }),
                  child: ListTile(
                    leading: const Icon(Icons.short_text_outlined),
                    title: const Text('列表行主标题'),
                    subtitle: Text(
                        settings.noteDisplay == 'category' ? '分类名优先' : '备注优先'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                  ),
                ),
                const Divider(height: 1, indent: 16),
                _switchTile(
                  context,
                  value: settings.hideAmounts,
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setHideAmounts(v),
                  title: '隐藏金额',
                  subtitle: '把界面上的数字换成 ****，适合给别人看',
                ),
                const Divider(height: 1, indent: 16),
                PressScale(
                  scale: 0.98,
                  onTap: () => _pickSymbol(context, ref, settings.symbol),
                  child: ListTile(
                    leading: const Icon(Icons.payments_outlined),
                    title: const Text('货币符号'),
                    subtitle: Text('当前：${settings.symbol}'),
                    trailing: const Icon(Icons.chevron_right, size: 18),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('记账'),
          Panel(
            padding: EdgeInsets.zero,
            child: PressScale(
              scale: 0.98,
              onTap: () => _pickDefaultPocket(context, ref),
              child: ListTile(
                leading: const Icon(Icons.account_balance_wallet_outlined),
                title: const Text('默认账户'),
                subtitle: Text(settings.defaultPocketId == 0
                    ? '未设置 · 记账时自动取第一个账户'
                    : defaultPocket == null
                        ? '原账户已删除 · 记账时自动取第一个'
                        : '${glyphLabel(defaultPocket.glyph)} '
                            '${defaultPocket.displayName}'),
                trailing: const Icon(Icons.chevron_right, size: 18),
              ),
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('流水显示'),
          Panel(
            padding: EdgeInsets.zero,
            child: _switchTile(
              context,
              value: settings.hideTransfers,
              title: '隐藏转账流水',
              subtitle: '首页列表不显示转账记录（合计与统计不受影响）',
              onChanged: (v) =>
                  ref.read(settingsProvider.notifier).setHideTransfers(v),
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('深浅色'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final entry in const {
                  ThemeMode.system: '跟随系统',
                  ThemeMode.light: '浅色',
                  ThemeMode.dark: '深色',
                }.entries)
                  _themeRow(
                      context, ref, entry.key, entry.value, settings.themeMode),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _graceLabel(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    if (seconds < 3600) return '${seconds ~/ 60} 分钟';
    return '${seconds ~/ 3600} 小时';
  }

  /// 锁定宽限期单选。0 = 每次切回后台都要解锁。
  Future<void> _pickLockGrace(BuildContext context, WidgetRef ref) async {
    const options = <(int, String)>[
      (0, '每次切回都锁'),
      (15, '15 秒'),
      (30, '30 秒'),
      (60, '1 分钟'),
      (300, '5 分钟'),
    ];
    final current = ref.read(settingsProvider).lockGraceSeconds;
    final picked = await showAppSheet<int>(
      context: context,
      title: '多久后重新锁定',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (sec, label) in options)
            ListTile(
              title: Text(
                label,
                style: TextStyle(
                  fontWeight: current == sec ? FontWeight.w700 : FontWeight.w500,
                  color: current == sec ? Palette.brand(ctx) : null,
                ),
              ),
              trailing: current == sec
                  ? Icon(Icons.check, size: 18, color: Palette.brand(ctx))
                  : null,
              onTap: () => Navigator.pop(ctx, sec),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await ref.read(settingsProvider.notifier).setLockGrace(picked);
    if (context.mounted) {
      // 效果要切后台才看得见，不提示的话用户不知道自己选上没有
      _toast(context, picked == 0 ? '切回就锁' : '切后台 ${_graceLabel(picked)}后需要解锁');
    }
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).toast(msg);
  }

  Widget _paletteRow(
      BuildContext context,
      WidgetRef ref,
      String id,
      ({String name, String hint, Color seed, List<Color> gradient}) palette,
      String current) {
    final selected = id == current;
    return PressScale(
      scale: 0.98,
      onTap: () async {
        await ref.read(settingsProvider.notifier).setPalette(id);
        if (context.mounted) _toast(context, '已切换到「${palette.name}」');
      },
      child: ListTile(
        // 缩略图直接给渐变本身：四个圆点看不出"草木薄荷"和"薰衣草湖"的差别，
        // 而这一页唯一要传达到的就是渐变观感。
        leading: Container(
          width: 34,
          height: 22,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: palette.gradient,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        title: Text(palette.name),
        subtitle: Text(palette.hint, style: const TextStyle(fontSize: 11.5)),
        trailing: selected ? const Icon(Icons.check) : null,
      ),
    );
  }

  /// 当前字号的一句话描述（档位名 + 倍率）
  String _fontScaleLabel(double scale) {
    for (final l in kFontLevels) {
      if ((l.scale - scale).abs() < 0.005) {
        return '${l.label} · x${l.scale.toStringAsFixed(2)}';
      }
    }
    return '自定义 · x${scale.toStringAsFixed(2)}';
  }

  Widget _themeRow(BuildContext context, WidgetRef ref, ThemeMode mode,
      String label, ThemeMode current) {
    final selected = mode == current;
    return PressScale(
      scale: 0.98,
      onTap: () => ref.read(settingsProvider.notifier).setThemeMode(mode),
      child: ListTile(
        leading: Icon(switch (mode) {
          ThemeMode.light => Icons.light_mode_outlined,
          ThemeMode.dark => Icons.dark_mode_outlined,
          ThemeMode.system => Icons.brightness_auto_outlined,
        }),
        title: Text(label),
        trailing: selected ? const Icon(Icons.check) : null,
      ),
    );
  }

  /// 首页显示了几项：用户进这个页之前应该能一眼看出「关掉了几个」。
  String _homeModulesLabel(AppSettings s) {
    final hidden = parseHidden(s.homeHidden);
    final shown = s.modulesOrder.where((id) => !hidden.contains(id)).length;
    return '排序与显隐 · 显示 $shown / ${s.modulesOrder.length} 项';
  }

  Widget _switchTile(
    BuildContext context, {
    required bool value,
    // 可为 null：设备不支持之类的情况要**整行置灰**（JellySwitch 收到 null
    // 就不再响应点击），而不是给个空回调让它播完动画再弹回去。
    required ValueChanged<bool>? onChanged,
    required String title,
    required String subtitle,
  }) {
    final enabled = onChanged != null;
    return ListTile(
      enabled: enabled,
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: JellySwitch(value: value, onChanged: onChanged),
    );
  }

  /// 选默认账户。0 = 不指定（回到取第一个）。
  Future<void> _pickDefaultPocket(
      BuildContext context, WidgetRef ref) async {
    final pockets = ref.read(pocketsProvider).valueOrNull ?? const <Pocket>[];
    final current = ref.read(settingsProvider).defaultPocketId;
    final picked = await showAppSheet<int>(
      context: context,
      title: '默认账户',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.autorenew, size: 18),
            title: const Text('不指定（用第一个账户）'),
            subtitle: const Text('换账本或不常改账户时选这个',
                style: TextStyle(fontSize: 12)),
            trailing: current == 0 ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, 0),
          ),
          const Divider(height: 1),
          for (final p in pockets)
            ListTile(
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppGlyph(p.glyph, size: 16),
                  const SizedBox(width: 6),
                  Flexible(
                      child: Text(p.displayName,
                          overflow: TextOverflow.ellipsis)),
                ],
              ),
              subtitle: p.currency == 'CNY'
                  ? null
                  : Text(p.currency, style: const TextStyle(fontSize: 12)),
              trailing: p.id == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, p.id),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await ref.read(settingsProvider.notifier).setDefaultPocket(picked);
    if (!context.mounted) return;
    _toast(context, picked == 0 ? '已取消默认账户' : '默认账户已更新');
  }

  Future<void> _pickSymbol(
      BuildContext context, WidgetRef ref, String current) async {
    const options = ['¥', r'$', '€', '£', r'NT$', r'HK$'];
    final picked = await showAppSheet<String>(
      context: context,
      title: '选择货币符号',
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final s in options)
            ListTile(
              title: Text(s, style: const TextStyle(fontSize: 17)),
              trailing: s == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, s),
            ),
        ],
      ),
    );
    if (picked != null) {
      await ref.read(settingsProvider.notifier).setSymbol(picked);
      if (context.mounted) _toast(context, '货币符号已改为 $picked');
    }
  }

  /// 设 PIN：**输入 + 再输一次确认**，并在位数不足时原地报错。
  ///
  /// 以前只有一个输入框、点「启用」就落盘：手滑按错一位，这个 App 从此打不开
  /// （全项目没有任何找回入口），唯一出路是卸载清数据。
  /// 位数不足时弹窗还会一声不响关掉、开关弹回，用户只当是开关坏了。
  Future<void> _setPin(BuildContext context, WidgetRef ref) async {
    final first = await _askPin(context, title: '设置 PIN', action: '下一步');
    if (first == null || !context.mounted) return;
    final again =
        await _askPin(context, title: '再输一次', action: '启用', expect: first);
    if (again == null || !context.mounted) return;
    await ref.read(settingsProvider.notifier).setPin(again);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).toast('应用锁已开启，请记住这个 PIN');
  }

  /// PIN 输入弹窗。[expect] 非空时不一致会原地报错，不允许提交。
  Future<String?> _askPin(
    BuildContext context, {
    required String title,
    required String action,
    String? expect,
  }) async {
    final ctrl = TextEditingController();
    String? error;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppTextField(
                label: 'PIN 码',
                controller: ctrl,
                hint: '4-8 位数字',
                autofocus: true,
                obscureText: true,
                maxLength: 8,
                keyboardType: TextInputType.number,
                // 键盘类型只是"优先弹数字键盘"，中文输入法照样能输汉字。
                // 不过滤的话 PIN 里会出现汉字，第二次输不回去。
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                errorText: error,
                onChanged: (_) => setLocal(() => error = null),
              ),
              const SizedBox(height: 8),
              Text(
                'PIN 只存在本机，忘了只能清空数据重来 —— 记牢它。',
                style: TextStyle(fontSize: 12, color: Palette.inkFaint(ctx)),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final v = ctrl.text.trim();
                if (v.length < 4) {
                  setLocal(() => error = '至少 4 位');
                  return;
                }
                if (expect != null && v != expect) {
                  setLocal(() => error = '两次不一致，重输一次');
                  return;
                }
                Navigator.pop(ctx, v);
              },
              child: Text(action),
            ),
          ],
        ),
      ),
    );
  }
}
