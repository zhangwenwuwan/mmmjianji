# 字体授权说明

## DouyinSans-Bold.otf

- 字体名：抖音美好体（Douyin Sans），字重仅 Bold（700）
- 来源：抖音官方公开字体，由用户提供原始文件 `抖音美好体.otf`，此处重命名以便在
  `pubspec.yaml` 里按 `family: DouyinSans` 注册
- 用途：仅用于简记的标题层（`fontStyle = 'display'` 档），正文与金额不用它

## 为什么只用在标题层

用 `fontTools` 解析过这个文件，有两个硬限制：

1. **只有一个字重**（`OS/2.usWeightClass = 700`）。正文全用它，整页都是粗的，
   层次消失；10~12px 的小字会糊成一团。
2. **数字不等宽**：`1` 是 415 units、`0` 是 585 units，差 40%；字体里也没有
   `tnum`（等宽数字）特性可以修正。金额列会左右漂、小数点对不齐。

所以默认档 `display` 只把 `displaySmall / headlineSmall / titleLarge /
titleMedium` 和 AppBar 标题换成它，金额、列表、正文保持系统字体。
用户可以在「字体大小」页切到 `system`（全系统）或 `all`（全局美好体，不建议）。
