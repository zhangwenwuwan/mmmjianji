import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/settings.dart';
import 'common.dart';
import 'motion.dart';
import 'theme.dart';

/// 字号档位：对齐参考版的 8 档（-3 ~ +4），系数用的是实测好用的那组。
const kFontLevels = <({int level, String label, double scale})>[
  (level: -3, label: '超小', scale: 0.80),
  (level: -2, label: '很小', scale: 0.86),
  (level: -1, label: '较小', scale: 0.92),
  (level: 0, label: '标准', scale: 1.00),
  (level: 1, label: '较大', scale: 1.08),
  (level: 2, label: '大', scale: 1.16),
  (level: 3, label: '很大', scale: 1.24),
  (level: 4, label: '极大', scale: 1.32),
];

/// 字体大小设置。
///
/// 结构照参考版的做法：**先给预览、再给档位、最后给微调**。
/// 顺序很关键——先看到效果，才知道自己在调什么；只给一排数字，
/// 用户得反复进出页面才能比对。
class FontSettingsPage extends ConsumerWidget {
  const FontSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final scale = settings.fontScale;
    final matched =
        kFontLevels.where((l) => (l.scale - scale).abs() < 0.005).firstOrNull;

    return Scaffold(
      appBar: AppBar(title: const Text('字体大小')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
        children: [
          SectionLabel('预览'),
          const _PreviewCard(),
          const SizedBox(height: 18),
          SectionLabel('字号档位'),
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < kFontLevels.length; i++) ...[
                  if (i > 0) const Divider(height: 1, indent: 16),
                  _levelRow(context, ref, kFontLevels[i], scale),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),
          SectionLabel('微调'),
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('自定义缩放',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: Palette.ink(context))),
                    const Spacer(),
                    Text('x${scale.toStringAsFixed(2)}',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: Palette.brand(context),
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ],
                ),
                Slider(
                  value: scale.clamp(0.8, 1.4),
                  min: 0.8,
                  max: 1.4,
                  divisions: 30,
                  label: 'x${scale.toStringAsFixed(2)}',
                  onChanged: (v) => ref
                      .read(settingsProvider.notifier)
                      .setFontScale(double.parse(v.toStringAsFixed(2))),
                ),
                Text(
                  matched == null
                      ? '当前是自定义值，点上面任意一档可以回到标准档位。'
                      : '当前为「${matched.label}」（x${matched.scale.toStringAsFixed(2)}），拖动滑块会变成自定义值。',
                  style: TextStyle(
                      fontSize: 10.5,
                      height: 1.5,
                      color: Palette.inkFaint(context)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '字体大小会影响全 App 的文字。如果系统本身已经把字体调得很大，'
            '这里再调大可能会让个别页面显得拥挤，建议先用「标准」看一遍。',
            style: TextStyle(
                fontSize: 11, height: 1.6, color: Palette.inkFaint(context)),
          ),
        ],
      ),
    );
  }

  Widget _levelRow(BuildContext context, WidgetRef ref,
      ({int level, String label, double scale}) item, double current) {
    final selected = (item.scale - current).abs() < 0.005;
    return PressScale(
      scale: 0.98,
      onTap: () => ref.read(settingsProvider.notifier).setFontScale(item.scale),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Text(
              item.label,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected ? Palette.brand(context) : Palette.ink(context),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'x${item.scale.toStringAsFixed(2)}',
              style: TextStyle(
                  fontSize: 11,
                  color: Palette.inkFaint(context),
                  fontFeatures: const [FontFeature.tabularFigures()]),
            ),
            const Spacer(),
            if (selected)
              Icon(Icons.check_circle, size: 18, color: Palette.brand(context)),
          ],
        ),
      ),
    );
  }
}

/// 预览卡：标题 + 正文 + 一行列表 + 金额，四种排版一次看全。
class _PreviewCard extends ConsumerWidget {
  const _PreviewCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final symbol = ref.watch(settingsProvider).symbol;
    return Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('早餐',
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: Palette.ink(context))),
          const SizedBox(height: 6),
          Text(
            '今天在楼下买了包子和豆浆，8 块 5。记下来才发现，早餐一个月也要两百多。',
            style: TextStyle(
                fontSize: 14, height: 1.5, color: Palette.inkSoft(context)),
          ),
          const SizedBox(height: 14),
          Divider(color: Palette.hairline(context), height: 1),
          const SizedBox(height: 12),
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Palette.hairline(context).withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('🍜', style: TextStyle(fontSize: 15)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('午餐 · 公司楼下',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w500,
                            color: Palette.ink(context))),
                    const SizedBox(height: 2),
                    Text('餐饮',
                        style: TextStyle(
                            fontSize: 11, color: Palette.inkFaint(context))),
                  ],
                ),
              ),
              Text('${symbol}32.00',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Palette.expense,
                      fontFeatures: const [FontFeature.tabularFigures()])),
            ],
          ),
        ],
      ),
    );
  }
}
