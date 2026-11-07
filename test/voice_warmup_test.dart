import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/services/offline_speech.dart';

/// 离线语音「冷启动不再重拷 82MB 模型」的契约守护。
///
/// 真正的引擎加载与模型缓存复用依赖原生 sherpa_onnx 与随包内置资源，
/// 只能在真机验证（见 OfflineSpeechService.warmUp）。这里只钉两条
/// 不依赖原生通道、却能在 --check 里守住的不变量：
///   1. 服务是进程内唯一单例（缓存/状态不会被重复初始化）；
///   2. warmUp 入口对异常是安全的（内部全程 try/catch）。
void main() {
  test('OfflineSpeechService 是进程内唯一单例', () {
    expect(
        identical(OfflineSpeechService.instance, OfflineSpeechService.instance),
        isTrue);
  });

  test('warmUp 入口异常安全（后台预热不抛同步异常）', () {
    // 测试环境没有原生通道，warmUp 内部已 try/catch 兜底，
    // 这里只验证调用入口本身不会同步抛异常。
    expect(() => OfflineSpeechService.warmUp(), returnsNormally);
  });
}
