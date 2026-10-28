import 'package:flutter/material.dart';

import 'common.dart';
import 'insight_pages.dart';
import 'motion.dart';

/// 财务洞察工具台：把高级分析工具集中在一页。
///
/// 参考版「我的 → 财务洞察」的同类入口；洞察 tab 只看当月概览，
/// 想看更细的工具从这里进。
class InsightHubPage extends StatelessWidget {
  const InsightHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('财务洞察')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
        children: [
          Panel(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _nav(context, Icons.timeline, '现金流预测', '照这个节奏，30 天后剩多少',
                    const ForecastPage()),
                const Divider(height: 1, indent: 16),
                _nav(context, Icons.subscriptions_outlined, '订阅猎人', '找出每月自动扣的钱',
                    const SubscriptionsPage()),
                const Divider(height: 1, indent: 16),
                _nav(context, Icons.grid_on, '消费热力', '哪天花得多，一眼看出来',
                    const HeatmapPage()),
                const Divider(height: 1, indent: 16),
                _nav(context, Icons.eco_outlined, '碳足迹', '这个月花了多少碳（估算）',
                    const CarbonPage()),
                const Divider(height: 1, indent: 16),
                _nav(context, Icons.mood_outlined, '情绪账本', '花完是值还是后悔',
                    const MoodPage()),
                const Divider(height: 1, indent: 16),
                _nav(context, Icons.calculate_outlined, '如果…', '每天少花 X 元，一年省多少',
                    const SimulatorPage()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _nav(BuildContext context, IconData icon, String title,
      String subtitle, Widget page) {
    return PressScale(
      scale: 0.98,
      onTap: () => Navigator.of(context).push(AppPageRoute(page: page)),
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
        trailing: const Icon(Icons.chevron_right, size: 18),
      ),
    );
  }
}
