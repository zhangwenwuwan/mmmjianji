/// 选图（相册 / 拍照）的四种结果。
///
/// 为什么不能继续用 `String?`：以前「用户主动取消」「权限被拒」「IO 异常」
/// 全是 null，UI 只能统一弹「没有选中图片」。第一次被问权限时点了拒绝的人，
/// 之后每次点都只看到这句话 —— 既不知道是权限问题，也找不到去设置的路。
enum PickResult {
  /// 选好了，路径在 [PickOutcome.path]
  ok,

  /// 用户在系统相册里自己取消了：不该弹任何提示
  cancelled,

  /// 权限被拒：要明确告诉用户去系统设置里打开
  denied,

  /// 其它失败（读图/落盘异常）
  error,
}

class PickOutcome {
  const PickOutcome(this.result, {this.path});

  final PickResult result;
  final String? path;
}
