import 'app_glyph.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/store.dart';
import '../state/ledger_state.dart';
import '../state/settings.dart';
import 'common.dart';
import 'font_settings_page.dart';
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
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
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
                          style: TextStyle(fontSize: 13.5)),
                      subtitle: Text(
                        settings.lockGraceSeconds <= 0
                            ? '每次切回后台都要解锁'
                            : '切后台超过 ${_graceLabel(settings.lockGraceSeconds)}回来要输 PIN',
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 20),
                    ),
                  ),
                  if (biometricSupported) const Divider(height: 1, indent: 16),
                  // 指纹行**始终显示**：设备不支持时置灰并说明原因。
                  // 完全隐藏的话，用户只会以为"这个版本没这功能"。
                  _switchTile(
                    context,
                    value: biometricSupported && settings.biometricEnabled,
                    onChanged: biometricSupported
                        ? (v) => ref
                            .read(settingsProvider.notifier)
                            .setBiometricEnabled(v)
                        : (_) {},
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
                trailing: const Icon(Icons.chevron_right, size: 20),
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
                  onChanged: (v) =>
                      ref.read(settingsProvider.notifier).setCompactAmounts(v),
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
                                style: const TextStyle(fontSize: 11)),
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
                    trailing: const Icon(Icons.chevron_right, size: 20),
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
                    trailing: const Icon(Icons.chevron_right, size: 20),
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
                trailing: const Icon(Icons.chevron_right, size: 20),
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
  }

  void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _paletteRow(
      BuildContext context,
      WidgetRef ref,
      String id,
      ({String name, Color seed, Color expense, Color income}) palette,
      String current) {
    final selected = id == current;
    return PressScale(
      scale: 0.98,
      onTap: () => ref.read(settingsProvider.notifier).setPalette(id),
      child: ListTile(
        leading: Container(
          width: 22,
          height: 22,
          decoration:
              BoxDecoration(color: palette.seed, shape: BoxShape.circle),
        ),
        title: Text(palette.name),
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

  Widget _switchTile(
    BuildContext context, {
    required bool value,
    required ValueChanged<bool> onChanged,
    required String title,
    required String subtitle,
  }) {
    return ListTile(
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
                style: TextStyle(fontSize: 11)),
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
                  : Text(p.currency, style: const TextStyle(fontSize: 11)),
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
              title: Text(s, style: const TextStyle(fontSize: 18)),
              trailing: s == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(ctx, s),
            ),
        ],
      ),
    );
    if (picked != null) {
      await ref.read(settingsProvider.notifier).setSymbol(picked);
    }
  }

  Future<void> _setPin(BuildContext context, WidgetRef ref) async {
    final ctrl = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设置 PIN'),
        content: AppTextField(
          label: 'PIN 码',
          controller: ctrl,
          hint: '4-8 位数字',
          autofocus: true,
          obscureText: true,
          maxLength: 8,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final v = ctrl.text.trim();
              Navigator.pop(ctx, v.length >= 4 ? v : null);
            },
            child: const Text('启用'),
          ),
        ],
      ),
    );
    if (pin == null) return;
    await ref.read(settingsProvider.notifier).setPin(pin);
  }
}
