import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/home_modules.dart';

/// 新装 App 时「常用」默认隐藏的入口 id（逗号分隔）。
///
/// 其中财务洞察 → 统计页右上角、储蓄目标 / 借贷 → 资产页下方两栏，
/// 在「常用」里是重复入口；首页模块入口已撤下（待重做），本就不在此列。
/// 用户只要动过一次开关，就按他存的来（可能是空串 = 全显示）。
/// 默认收起的入口（新装 / 恢复默认）。
///
/// 2026-10-25 用户要求：常用只默认显示 数据管理 / 外观与显示 / 自动化 / 导入账单，
/// 其余五个都收进齿轮页。顺序按目录顺序写，方便和 catalog 对照。
const String defaultProfileHiddenCsv =
    'insights,wishlist,budget,loans,goals';

/// 应用级的少量偏好。都放在这里，避免散落。
class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.hideAmounts = false,
    this.symbol = '¥',
    this.lockEnabled = false,
    this.lockGraceSeconds = 30,
    this.biometricEnabled = false,
    this.pinHash = '',
    this.pinSalt = '',
    this.pinLength = 0,
    this.paletteId = 'teal',
    this.fontScale = 1.0,
    this.compactAmounts = false,
    this.noteDisplay = 'note',
    this.coverPath = '',
    this.coverSeed = 0,
    this.coverLuminance = 0.5,
    this.coverFollow = true,
    this.budgetCarryUnused = false,
    this.budgetDeductOver = false,
    this.homeOrder = '',
    this.homeHidden = '',
    this.profileHidden,
    this.hideTransfers = false,
    this.lastBackupAt = 0,
    this.defaultPocketId = 0,
    this.avatarPath = '',
    this.nickname = '',
  });

  final ThemeMode themeMode;
  final bool hideAmounts;
  final String symbol;

  /// 应用锁
  final bool lockEnabled;

  /// 切后台多久之后回来要重新解锁（秒）。0 = 每次切回都要锁。
  ///
  /// 2026-10-25 用户要求可自定义（原来硬编码 30 秒）。
  final int lockGraceSeconds;

  /// 是否允许用系统生物识别（指纹/面容）解锁。
  ///
  /// 它只是 PIN 的快捷方式：硬件不支持、没录入、验证失败，一律回退 PIN，
  /// 锁的安全等级不下降。
  final bool biometricEnabled;

  /// FNV-1a(salt + pin)。本地便利锁，不是密码学边界。
  final String pinHash;
  final String pinSalt;

  /// PIN 位数（0 = 不知道，老数据）。
  ///
  /// 用来实现「输满就自动解锁」：锁屏页 onChanged 里比长度，
  /// 不用再让用户去够下面的「解锁」按钮。
  final int pinLength;

  /// 配色方案 id（见 ui/theme.dart 的 kPalettes）
  final String paletteId;

  /// 字体缩放倍数（0.9 / 1.0 / 1.15 / 1.3）
  final double fontScale;

  /// 金额紧凑显示（10000 以上写成 1.2万）
  final bool compactAmounts;

  /// 列表行主标题显示什么：'note' 备注优先 / 'category' 分类名优先。
  /// 两种都不丢信息：另一个会挪到副标题。
  final String noteDisplay;

  /// 首页主封面：ImagePicker 拿到的图会被复制到应用私有目录，
  /// 这里存的是那份副本的绝对路径（缓存目录会被系统清掉，不能存原路径）。
  /// 空串 = 没设置封面。
  final String coverPath;

  /// 从封面图里提取出来的主色（ARGB）。0 = 还没取过色。
  /// 存成 int 而不是路径派生，是为了**不每次启动都重新解码整张图**。
  final int coverSeed;

  /// 封面有效像素的平均亮度，用来判断压在图上的文字该用白色还是深色。
  final double coverLuminance;

  /// 是否让封面主色接管全 App 配色。关掉就继续用手动选的配色方案。
  final bool coverFollow;

  /// 预算结转：上月没用完的预算累加到本月
  final bool budgetCarryUnused;

  /// 预算结转：上月超支的部分从本月扣掉
  final bool budgetDeductOver;

  /// 是否启用了任何一种结转
  bool get budgetCarryEnabled => budgetCarryUnused || budgetDeductOver;

  /// 首页流水是否隐藏转账记录。**只影响展示**，不影响合计/预算/统计。
  final bool hideTransfers;

  /// 首页模块顺序（逗号分隔的 HomeModule.id）。空串 = 用默认顺序。
  final String homeOrder;

  /// 被隐藏的首页模块（逗号分隔）。「记一笔」不参与。
  final String homeHidden;

  /// 被隐藏的「我的 → 常用」模块（逗号分隔的 id，见 ui/profile_modules.dart）。
  /// null = 从没设置过 → 用 [defaultProfileHidden]。
  final String? profileHidden;

  /// 上次**成功导出备份**的时间（epoch ms）。0 = 从来没备份过。
  ///
  /// 首页的「备份提醒」靠它判断要不要出提示条。只认「导出」这一步：
  /// 用户点了导出、文件已进入分享/剪贴板，就算备份过；
  /// 至于他有没有真的存到网盘，本地无从知晓，也不该假装知道。
  final int lastBackupAt;

  /// 默认账户 id（记账页优先选中它）。0 = 未设置，回退到第一个账户。
  ///
  /// 为什么要有：多账户用户的账大多落在同一个账户上（比如信用卡日常刷），
  /// 之前每次记一笔都默认取「第一个账户」，记错了还看不出来。
  /// 这个 id 可能是**已删除账户**的残留，用之前必须校验存在性。
  final int defaultPocketId;

  /// 「我的」页头像：相册选的图落盘后的**绝对路径**。空 = 用默认钱包图标。
  ///
  /// 为什么这次存绝对路径（而自定义图标存的是相对文件名）：头像只有一张，
  /// 出问题最多是回退成默认图标，不会像分类图标那样批量变成「🧾」。
  /// 换机会失效，换头像时旧文件会一起删掉，不会越攒越多。
  final String avatarPath;

  /// 昵称。空 = 显示默认的「记账人」。
  final String nickname;

  /// 昵称或默认值。UI 一律读这个，不要自己判空两遍。
  String get displayName => nickname.trim().isEmpty ? '记账人' : nickname.trim();

  /// 距上次备份过了多少天。没备份过返回 null。
  int? get daysSinceBackup {
    if (lastBackupAt <= 0) return null;
    final last = DateTime.fromMillisecondsSinceEpoch(lastBackupAt);
    final d = DateTime.now().difference(last).inDays;
    return d < 0 ? 0 : d;
  }

  /// 归一化后的模块顺序（含新版本新增的模块）
  List<HomeModule> get modulesOrder => normalizeOrder(homeOrder);

  /// 真正要渲染的模块（顺序 + 过滤隐藏）
  List<HomeModule> get modulesVisible =>
      visibleModules(modulesOrder, parseHidden(homeHidden));

  /// 「常用」里被隐藏的入口 id 集合。从没设置过 → 用默认隐藏项。
  Set<String> get profileHiddenSet {
    final raw = profileHidden ?? defaultProfileHiddenCsv;
    return raw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet();
  }

  /// 有封面 = 路径非空「且」文件仍在磁盘。
  ///
  /// 早期版本只判路径非空，结果封面图被删后 coverPath 仍残留，
  /// 「跟随封面换肤」会拿一张不存在的图继续接管全 App 配色（隐形改色）。
  /// 这里补上文件存在性判断，图没了就当没封面处理。
  bool get hasCover =>
      coverPath.isNotEmpty && File(coverPath).existsSync();

  /// 封面主色是否真的在生效（有封面 + 有取到色 + 用户没关掉跟随）。
  bool get coverThemeActive => hasCover && coverSeed != 0 && coverFollow;

  /// 换肤用的主色，未生效时返回 null。
  Color? get coverSeedColor => coverThemeActive ? Color(coverSeed) : null;

  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? hideAmounts,
    String? symbol,
    bool? lockEnabled,
    int? lockGraceSeconds,
    bool? biometricEnabled,
    String? pinHash,
    String? pinSalt,
    int? pinLength,
    String? paletteId,
    double? fontScale,
    bool? compactAmounts,
    String? noteDisplay,
    String? coverPath,
    int? coverSeed,
    double? coverLuminance,
    bool? coverFollow,
    bool? budgetCarryUnused,
    bool? budgetDeductOver,
    String? homeOrder,
    String? homeHidden,
    String? profileHidden,
    bool? hideTransfers,
    int? lastBackupAt,
    int? defaultPocketId,
    String? avatarPath,
    String? nickname,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        hideAmounts: hideAmounts ?? this.hideAmounts,
        symbol: symbol ?? this.symbol,
        lockEnabled: lockEnabled ?? this.lockEnabled,
        lockGraceSeconds: lockGraceSeconds ?? this.lockGraceSeconds,
        biometricEnabled: biometricEnabled ?? this.biometricEnabled,
        pinHash: pinHash ?? this.pinHash,
        pinSalt: pinSalt ?? this.pinSalt,
        pinLength: pinLength ?? this.pinLength,
        paletteId: paletteId ?? this.paletteId,
        fontScale: fontScale ?? this.fontScale,
        compactAmounts: compactAmounts ?? this.compactAmounts,
        noteDisplay: noteDisplay ?? this.noteDisplay,
        coverPath: coverPath ?? this.coverPath,
        coverSeed: coverSeed ?? this.coverSeed,
        coverLuminance: coverLuminance ?? this.coverLuminance,
        coverFollow: coverFollow ?? this.coverFollow,
        budgetCarryUnused: budgetCarryUnused ?? this.budgetCarryUnused,
        budgetDeductOver: budgetDeductOver ?? this.budgetDeductOver,
        homeOrder: homeOrder ?? this.homeOrder,
        homeHidden: homeHidden ?? this.homeHidden,
        profileHidden: profileHidden ?? this.profileHidden,
        hideTransfers: hideTransfers ?? this.hideTransfers,
        lastBackupAt: lastBackupAt ?? this.lastBackupAt,
        defaultPocketId: defaultPocketId ?? this.defaultPocketId,
        avatarPath: avatarPath ?? this.avatarPath,
        nickname: nickname ?? this.nickname,
      );
}

/// 偏好的读取与写入。
///
/// 设计要点：**启动路径上不做任何插件调用**。
/// 原先的写法是 main() 里 `await SharedPreferences.getInstance()` 之后才 runApp，
/// 只要这一步在某个机型上失败或卡住，Flutter 就永远不出首帧 —— 用户看到的就是
/// 「启动页卡死」，而且屏幕上没有任何提示。现在第一帧立刻用默认值渲染，
/// 偏好随后异步补上（读到就刷新，读不到就用默认值继续跑）。
/// 偏好是否已经从磁盘读完。
///
/// 首帧 state 必然是 `const AppSettings()`（`lockEnabled` = false）。
/// 谁在这个瞬间读它都会得到错的答案 —— 应用锁就是被这个坑住的：
/// 冷启动时 postFrame 读到的永远是 false，于是开了锁也直接放行。
final settingsHydratedProvider = StateProvider<bool>((ref) => false);

class SettingsNotifier extends Notifier<AppSettings> {
  static const _kTheme = 'theme_mode';
  static const _kHide = 'hide_amounts';
  static const _kSymbol = 'currency_symbol';
  static const _kLock = 'lock_enabled';
  static const _kPinLen = 'pin_length';
  static const _kLockGrace = 'lock_grace_seconds';
  static const _kBiometric = 'biometric_enabled';
  static const _kPinHash = 'pin_hash';
  static const _kPinSalt = 'pin_salt';
  static const _kPalette = 'palette_id';
  static const _kFontScale = 'font_scale';
  static const _kCompact = 'compact_amounts';
  static const _kNoteDisplay = 'note_display';
  static const _kCoverPath = 'cover_path';
  static const _kCoverSeed = 'cover_seed';
  static const _kCoverLuminance = 'cover_luminance';
  static const _kCoverFollow = 'cover_follow';
  static const _kBudgetCarryUnused = 'budget_carry_unused';
  static const _kBudgetDeductOver = 'budget_deduct_over';
  static const _kHomeOrder = 'home_order';
  static const _kHomeHidden = 'home_hidden';
  static const _kProfileHidden = 'profile_hidden';
  static const _kHideTransfers = 'hide_transfers';
  static const _kLastBackupAt = 'last_backup_at';
  static const _kDefaultPocket = 'default_pocket_id';
  static const _kAvatar = 'avatar_path';
  static const _kNickname = 'nickname';

  SharedPreferences? _prefs;
  bool _started = false;
  bool _touched = false;

  @override
  AppSettings build() {
    if (!_started) {
      _started = true;
      // build 期间不能改 state，补水放微任务。
      Future.microtask(_hydrate);
    }
    return const AppSettings();
  }

  Future<void> _hydrate() async {
    if (_prefs != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      if (!_touched) state = _read(prefs);
      // 自愈：封面图被删后，hasCover 已改为判文件存在性，不会再去接管配色；
      // 但残留的 coverPath 仍会误导其它读取方。启动时若图已不存在就清掉，
      // 避免「封面设置入口已撤、却永远关不掉」的卡死态。
      if (state.coverPath.isNotEmpty &&
          !File(state.coverPath).existsSync()) {
        await clearCover();
      }
    } catch (e) {
      // 读不到偏好不影响使用，全部走默认值。
      debugPrint('偏好读取失败，使用默认值: $e');
    }
    // 成功失败都要标记：否则 LockGate 会一直停在「加载中」，
    // 那就成了「锁坏了打不开」比「锁没锁」更糟。
    ref.read(settingsHydratedProvider.notifier).state = true;
  }

  static AppSettings _read(SharedPreferences prefs) {
    final mode = switch (prefs.getString(_kTheme)) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
    return AppSettings(
      themeMode: mode,
      hideAmounts: prefs.getBool(_kHide) ?? false,
      symbol: prefs.getString(_kSymbol) ?? '¥',
      lockEnabled: prefs.getBool(_kLock) ?? false,
      lockGraceSeconds: prefs.getInt(_kLockGrace) ?? 30,
      biometricEnabled: prefs.getBool(_kBiometric) ?? false,
      pinHash: prefs.getString(_kPinHash) ?? '',
      pinSalt: prefs.getString(_kPinSalt) ?? '',
      pinLength: prefs.getInt(_kPinLen) ?? 0,
      paletteId: prefs.getString(_kPalette) ?? 'teal',
      fontScale: prefs.getDouble(_kFontScale) ?? 1.0,
      compactAmounts: prefs.getBool(_kCompact) ?? false,
      noteDisplay: prefs.getString(_kNoteDisplay) ?? 'note',
      coverPath: prefs.getString(_kCoverPath) ?? '',
      coverSeed: prefs.getInt(_kCoverSeed) ?? 0,
      coverLuminance: prefs.getDouble(_kCoverLuminance) ?? 0.5,
      coverFollow: prefs.getBool(_kCoverFollow) ?? true,
      budgetCarryUnused: prefs.getBool(_kBudgetCarryUnused) ?? false,
      budgetDeductOver: prefs.getBool(_kBudgetDeductOver) ?? false,
      homeOrder: prefs.getString(_kHomeOrder) ?? '',
      homeHidden: prefs.getString(_kHomeHidden) ?? '',
      // 从没设置过 → null（走默认隐藏项）；用户动过一次就按存的来，
      // 包括空串（= 全部显示）。这两者的区别必须留住，否则"恢复默认"永远不生效。
      profileHidden: prefs.getString(_kProfileHidden),
      hideTransfers: prefs.getBool(_kHideTransfers) ?? false,
      lastBackupAt: prefs.getInt(_kLastBackupAt) ?? 0,
      defaultPocketId: prefs.getInt(_kDefaultPocket) ?? 0,
      avatarPath: prefs.getString(_kAvatar) ?? '',
      nickname: prefs.getString(_kNickname) ?? '',
    );
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    _touched = true;
    state = state.copyWith(themeMode: mode);
    await _prefs?.setString(
        _kTheme,
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        });
  }

  Future<void> setHideAmounts(bool value) async {
    _touched = true;
    state = state.copyWith(hideAmounts: value);
    await _prefs?.setBool(_kHide, value);
  }

  Future<void> setSymbol(String symbol) async {
    _touched = true;
    state = state.copyWith(symbol: symbol);
    await _prefs?.setString(_kSymbol, symbol);
  }

  /// 设置 PIN（4-8 位数字）。开启应用锁。
  Future<void> setPin(String pin) async {
    _touched = true;
    final salt = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final hash = hashPin(salt, pin);
    state = state.copyWith(
      lockEnabled: true,
      pinHash: hash,
      pinSalt: salt,
      pinLength: pin.length,
    );
    await _prefs?.setBool(_kLock, true);
    await _prefs?.setString(_kPinHash, hash);
    await _prefs?.setString(_kPinSalt, salt);
    await _prefs?.setInt(_kPinLen, pin.length);
  }

  /// 老数据自愈：以前没记 PIN 位数，用户成功解锁一次后就把长度补上，
  /// 下一次开始就能「输满自动解锁」了。不动 hash / salt。
  Future<void> rememberPinLength(int len) async {
    if (len <= 0 || state.pinLength == len) return;
    state = state.copyWith(pinLength: len);
    await _prefs?.setInt(_kPinLen, len);
  }

  /// 设置切后台多久后回来要重新解锁（秒）。0 = 每次切回都要锁。
  Future<void> setLockGrace(int seconds) async {
    _touched = true;
    final v = seconds < 0 ? 0 : seconds;
    state = state.copyWith(lockGraceSeconds: v);
    await _prefs?.setInt(_kLockGrace, v);
  }

  /// 开关生物识别解锁（指纹/面容）。
  ///
  /// 只在**已经设了 PIN**（lockEnabled）的前提下有意义：指纹是 PIN 的快捷
  /// 方式，没有 PIN 兜底时一旦硬件抽风，用户就再也进不去了。
  /// 设置页据此把开关藏起来，这里也不去动 lockEnabled。
  Future<void> setBiometricEnabled(bool value) async {
    _touched = true;
    state = state.copyWith(biometricEnabled: value);
    await _prefs?.setBool(_kBiometric, value);
  }

  Future<void> disableLock() async {
    _touched = true;
    state = state.copyWith(
        lockEnabled: false, pinHash: '', pinSalt: '', pinLength: 0);
    await _prefs?.setBool(_kLock, false);
    await _prefs?.setString(_kPinHash, '');
    await _prefs?.setString(_kPinSalt, '');
  }

  Future<void> setPalette(String id) async {
    _touched = true;
    state = state.copyWith(paletteId: id);
    await _prefs?.setString(_kPalette, id);
  }

  Future<void> setFontScale(double scale) async {
    _touched = true;
    state = state.copyWith(fontScale: scale);
    await _prefs?.setDouble(_kFontScale, scale);
  }

  Future<void> setCompactAmounts(bool value) async {
    _touched = true;
    state = state.copyWith(compactAmounts: value);
    await _prefs?.setBool(_kCompact, value);
  }

  /// 列表行主标题：'note' 备注优先 / 'category' 分类名优先
  Future<void> setNoteDisplay(String value) async {
    _touched = true;
    state = state.copyWith(noteDisplay: value);
    await _prefs?.setString(_kNoteDisplay, value);
  }

  /// 设置封面：路径 + 从图里取到的主色 + 平均亮度，一次性写进去。
  ///
  /// 三者必须同步落盘：只写 path 不写 seed，启动后就会「有封面但没换肤」，
  /// 用户会以为取色坏了。
  Future<void> setCover({
    required String path,
    required int seed,
    required double luminance,
  }) async {
    _touched = true;
    state = state.copyWith(
      coverPath: path,
      coverSeed: seed,
      coverLuminance: luminance,
    );
    await _prefs?.setString(_kCoverPath, path);
    await _prefs?.setInt(_kCoverSeed, seed);
    await _prefs?.setDouble(_kCoverLuminance, luminance);
  }

  /// 只重取色、不动图片（用户觉得抽出来的颜色不好看时点「重新取色」）。
  Future<void> setCoverPalette(int seed, double luminance) async {
    _touched = true;
    state = state.copyWith(coverSeed: seed, coverLuminance: luminance);
    await _prefs?.setInt(_kCoverSeed, seed);
    await _prefs?.setDouble(_kCoverLuminance, luminance);
  }

  Future<void> clearCover() async {
    _touched = true;
    state = state.copyWith(
      coverPath: '',
      coverSeed: 0,
      coverLuminance: 0.5,
    );
    await _prefs?.remove(_kCoverPath);
    await _prefs?.remove(_kCoverSeed);
    await _prefs?.remove(_kCoverLuminance);
  }

  /// 换头像。传空串 = 恢复默认图标。
  ///
  /// 旧文件由调用方（AvatarService.pickFromGallery）负责删，这里只管存档：
  /// 偏好层不该碰文件系统，否则换头像失败时状态和磁盘会不一致。
  Future<void> setAvatar(String path) async {
    _touched = true;
    state = state.copyWith(avatarPath: path);
    if (path.isEmpty) {
      await _prefs?.remove(_kAvatar);
    } else {
      await _prefs?.setString(_kAvatar, path);
    }
  }

  Future<void> clearAvatar() => setAvatar('');

  Future<void> setNickname(String name) async {
    _touched = true;
    final v = name.trim();
    state = state.copyWith(nickname: v);
    if (v.isEmpty) {
      await _prefs?.remove(_kNickname);
    } else {
      await _prefs?.setString(_kNickname, v);
    }
  }

  Future<void> setHideTransfers(bool value) async {
    _touched = true;
    state = state.copyWith(hideTransfers: value);
    await _prefs?.setBool(_kHideTransfers, value);
  }

  /// 设默认账户。传 0 = 清除设置（回到"取第一个账户"）。
  Future<void> setDefaultPocket(int id) async {
    _touched = true;
    state = state.copyWith(defaultPocketId: id);
    await _prefs?.setInt(_kDefaultPocket, id);
  }

  /// 保存首页模块顺序（传完整顺序，内部落盘成 id 串）
  Future<void> setHomeOrder(List<HomeModule> order) async {
    _touched = true;
    final v = [for (final m in order) m.id].join(',');
    state = state.copyWith(homeOrder: v);
    await _prefs?.setString(_kHomeOrder, v);
  }

  /// 开关某个模块的显隐
  Future<void> setHomeModuleHidden(HomeModule m, bool hidden) async {
    if (!m.canHide) return;
    _touched = true;
    final cur = parseHidden(state.homeHidden);
    if (hidden) {
      cur.add(m);
    } else {
      cur.remove(m);
    }
    final v = [for (final x in cur) x.id].join(',');
    state = state.copyWith(homeHidden: v);
    await _prefs?.setString(_kHomeHidden, v);
  }

  /// 恢复默认顺序 + 全部显示
  Future<void> resetHomeModules() async {
    _touched = true;
    state = state.copyWith(homeOrder: '', homeHidden: '');
    await _prefs?.remove(_kHomeOrder);
    await _prefs?.remove(_kHomeHidden);
  }

  /// 开关「我的 → 常用」里的一个入口。
  Future<void> setProfileModuleHidden(String id, bool hidden) async {
    _touched = true;
    final cur = state.profileHiddenSet;
    if (hidden) {
      cur.add(id);
    } else {
      cur.remove(id);
    }
    final v = cur.join(',');
    state = state.copyWith(profileHidden: v);
    await _prefs?.setString(_kProfileHidden, v);
  }

  /// 「常用」恢复默认：显示默认那 6 个，其余收起。
  Future<void> resetProfileModules() async {
    _touched = true;
    state = state.copyWith(profileHidden: defaultProfileHiddenCsv);
    await _prefs?.setString(_kProfileHidden, defaultProfileHiddenCsv);
  }

  /// 记录一次成功备份。首页提示条据此消失。
  Future<void> markBackedUp([DateTime? at]) async {
    _touched = true;
    final ms = (at ?? DateTime.now()).millisecondsSinceEpoch;
    state = state.copyWith(lastBackupAt: ms);
    await _prefs?.setInt(_kLastBackupAt, ms);
  }

  Future<void> setBudgetCarryUnused(bool value) async {
    _touched = true;
    state = state.copyWith(budgetCarryUnused: value);
    await _prefs?.setBool(_kBudgetCarryUnused, value);
  }

  Future<void> setBudgetDeductOver(bool value) async {
    _touched = true;
    state = state.copyWith(budgetDeductOver: value);
    await _prefs?.setBool(_kBudgetDeductOver, value);
  }

  Future<void> setCoverFollow(bool value) async {
    _touched = true;
    state = state.copyWith(coverFollow: value);
    await _prefs?.setBool(_kCoverFollow, value);
  }

  bool verifyPin(String pin) {
    if (state.pinHash.isEmpty) return false;
    return hashPin(state.pinSalt, pin) == state.pinHash;
  }
}

/// FNV-1a 64 位哈希。用途只是"别人拿到手机随手打不开"，不是密码学保护；
/// 真要抗离线爆破得用 PBKDF2/argon2，那是另一个量级的依赖。
String hashPin(String salt, String pin) {
  const offset = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  var hash = offset;
  for (final code in '$salt|$pin'.codeUnits) {
    hash ^= code;
    // Dart 的 int 是 64 位有符号，这里用位运算模拟无符号溢出
    hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16);
}

final settingsProvider =
    NotifierProvider<SettingsNotifier, AppSettings>(SettingsNotifier.new);
