import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:voice_recognizer/voice_recognizer.dart';

import '../core/version.dart';

/// 语音按钮当前处在哪一步。UI 只认这个枚举，不碰识别引擎内部状态。
enum SpeechStage {
  /// 待机：一颗圆形麦克风
  idle,

  /// 已授权，正在把内置模型准备好（首次会复制 82MB，约几秒）
  preparing,

  /// 正在收音：按钮变波纹，说完停顿一下自动结束
  listening,

  /// 整段音频在本机做推理
  recognizing,
}

class SpeechException implements Exception {
  const SpeechException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 离线语音识别服务。
///
/// 链路：**首次点击 → 申请麦克风权限 → 加载随包内置的中文 Paraformer 模型
/// → 录 16k 单声道 PCM → 静音自动断句 → 本机推理 → 返回文字**。
///
/// 刻意不在 App 启动时初始化：82MB 模型只有在用户真的想用语音时才加载，
/// 而且即使原生库在这台机型上加载失败，也只是语音按钮报错，App 其余部分
/// 完全不受影响。音频不写网络、不落业务库，只有临时目录里的一份模型副本。
class OfflineSpeechService {
  OfflineSpeechService._();
  static final OfflineSpeechService instance = OfflineSpeechService._();

  // 延迟到首次使用时才创建：AudioRecorderService 的构造会走平台通道
  // （AudioRecorder().create），必须在 WidgetsFlutterBinding 起来之后。
  // 否则进程内单例一被访问（哪怕只是测试）就会在绑定初始化前碰平台通道而炸。
  // 录音只发生在 listen() 里，那时绑定必然已就绪；warmUp() 不碰它。
  late final AudioRecorderService _recorder = AudioRecorderService();
  bool _busy = false;

  /// 冷启动预热：后台把离线识别引擎先加载好，用户点麦克风时不再转几秒的圈。
  ///
  /// 模型文件（约 82MB）首次运行后缓存在应用私有目录。本方法只在 App 版本号
  /// 变化时清一次旧缓存，其余冷启动直接复用，避免每次都重拷 82MB。
  ///
  /// ⚠️ 依赖 voice_recognizer 包已打补丁：`SimpleParaformerRecognizer
  /// ._prepareModelFiles` 在模型文件已存在时跳过复制（否则每次冷启动仍会重拷）。
  /// 补丁路径见 `.workbuddy/memory`。
  static Future<void> warmUp() async {
    try {
      final dir = Directory(
          '${(await getTemporaryDirectory()).path}/paraformer_offline_model');
      final marker = File('${dir.path}/.warmbuild');

      // ⚠️ 关键：不能直接在这里创建空目录 + 写标记。
      // 否则引擎 `_prepareModelFiles` 检查「模型文件是否存在」时会发现目录是空的，
      // 于是走「删目录 + 重拷 82MB」分支 —— 顺手把刚写的标记也删了，
      // 结果每次冷启动标记都不在，warmUp 又清目录，陷入「永远重拷」的死循环。
      //
      // 正确做法：warmUp 只负责「版本升级时清旧缓存」，模型的复制由引擎完成。
      // 标记必须在引擎把模型文件真正就位之后才写（见下方 preInitialize 回调）。
      if (await dir.exists()) {
        final old =
            await marker.exists() ? await marker.readAsString() : '';
        // 仅当「旧标记存在且与当前版本不同」才清缓存（换了模型）。
        // 标记缺失但模型文件还在（如标记被异常清除）不要删，避免白白重拷 82MB。
        final willDelete = old.isNotEmpty && old != '$appBuild';
        if (willDelete) {
          await dir.delete(recursive: true);
        }
      }

      // 后台加载引擎，不阻塞首帧。初始化成功（模型已就位）后再写版本标记，
      // 供下次冷启动判断。
      unawaited(
        VoiceRecognizerRegistry.instance.preInitialize().then((ok) async {
          if (!ok) return;
          try {
            await marker.writeAsString('$appBuild');
          } catch (_) {
            // 写标记失败无所谓：下次冷启动会重新评估，顶多重拷一次。
          }
        }),
      );
    } catch (e) {
      debugPrint('语音模型缓存校验失败（忽略，下次重试）: $e');
    }
  }

  /// 当前这次收音的「立刻收尾」钩子。收音真正开始后才非空。
  void Function()? _finishHook;

  /// 用户手动结束（再点一次按钮）。
  bool _forced = false;

  /// 让正在进行的收音**立刻结束**，进入识别。
  ///
  /// 只在 [listen] 已经进入收音阶段后有效（权限弹窗 / 82MB 模型加载期间
  /// 还没有钩子，返回 false —— 调用方据此决定要不要提示"还在准备"）。
  /// 说完话自己停顿也会结束，这里只是把"什么时候算说完"的决定权交给用户。
  bool stopListening() {
    final hook = _finishHook;
    if (hook == null) return false;
    _forced = true;
    hook();
    return true;
  }

  /// 录一句并返回识别出的文字。识别不到内容时返回空串。
  ///
  /// [onStage] 驱动按钮动效；[onLevel] 是归一化后的实时音量，用于波纹幅度。
  /// 说完停顿 [silenceToStop] 自动收尾，[maxDuration] 是兜底上限
  /// （环境嘈杂时静音检测可能一直不触发，不能让用户卡在收听态）。
  Future<String> listen({
    required void Function(SpeechStage stage) onStage,
    required void Function(double level) onLevel,
    Duration maxDuration = const Duration(seconds: 9),
    Duration silenceToStop = const Duration(milliseconds: 1100),
  }) async {
    if (_busy) throw const SpeechException('正在收音');
    _busy = true;
    Timer? watchdog;
    try {
      // ① 权限放在最前面：用户第一次点按钮就弹系统授权框；拒绝了就不必
      //    白加载 82MB 模型。用户同意之后才往下走。
      if (!await _recorder.checkPermission()) {
        final why = _recorder.errorMessage;
        throw SpeechException(why.isEmpty ? '需要麦克风权限才能语音记账' : why);
      }

      // ② 模型初始化（已预热则瞬间完成；否则首次会复制 82MB，约几秒）
      final registry = VoiceRecognizerRegistry.instance;
      if (!registry.isInitialized) onStage(SpeechStage.preparing);
      final ready = await registry.ensureInitialized();
      if (!ready) {
        throw SpeechException(registry.errorMessage ?? '离线识别引擎加载失败');
      }
      final asr = registry.recognizer;
      if (asr == null) throw const SpeechException('离线识别引擎不可用');

      // ③ 边录边把 PCM 喂给识别器；同时做端点检测。
      //
      // 固定阈值在真机上翻过车：安静房间底噪 RMS 一直 > 0.012，
      // 被当成「一直在说话」，静音收尾永远不触发，每次都录满 9 秒上限，
      // 而且没人对着说话时会把噪声幻听成一句乱码再弹确认窗。
      // 所以改成：开头 350ms 先量环境底噪，之后按「底噪 × 2.0」自适应判定人声；
      // 全程没检测到人声就直接返回空串，不进识别、不弹窗。
      asr.startListening();
      final done = Completer<void>();
      final started = DateTime.now();
      var lastLoud = started;
      var heardVoice = false;
      var calibrated = false;
      var noiseFloor = 0.0;
      final noiseSamples = <double>[];

      void finish() {
        if (!done.isCompleted) done.complete();
      }

      // 交给人手：再点一次按钮就立刻进识别（见 stopListening）。
      // ⚠️ 必须在 `onStage(listening)` **之前**挂上：UI 收到 listening 时
      // 可能立刻要求收尾（用户在模型加载期间就点过一下），钩子晚一步就吞掉这次请求。
      _finishHook = finish;
      onStage(SpeechStage.listening);

      final began = await _recorder.startRecording(
        onAudioData: (data) {
          // ⚠️ **必须拷贝**，别直接把 data 交给识别器。
          // 平台通道 StandardMessageCodec 解码 byte[] 时返回的是
          //   data.buffer.asUint8List(data.offsetInBytes + _position, length)
          // —— 共享整条消息 buffer、offsetInBytes 非 0 的 view
          // （flutter/foundation/serialization.dart:228）。
          // voice_recognizer 的 _pcm16ToFloat32 却写成
          //   Int16List.view(pcm16.buffer, 0, length)
          // 从 buffer 第 0 字节读，拿到的是消息头（类型标记 + 长度）而不是人声。
          // 症状极具迷惑性：录音时长/音量全正常，识别结果却是乱码，
          // 安静时还会把底噪「听」成一句莫名其妙的中文。
          // record 包自带的 convertBytesToInt16 用 ByteData.sublistView（尊重 offset），
          // 我们自己的 _rms 也是 sublistView，所以只有 ASR 这一路是错的。
          // 拷成 offset=0 的新数组即可，不改动第三方包。
          asr.processAudioData(Uint8List.fromList(data));
          final rms = _rms(data);
          onLevel((rms * 6).clamp(0.0, 1.0));
          final now = DateTime.now();
          final elapsed = now.difference(started);

          // 前 350ms 只采底噪不做判定：录音链路刚起来时硬件增益会爬升，
          // 固定阈值容易把这段爬升当成「一直在说话」。
          if (!calibrated) {
            if (elapsed < const Duration(milliseconds: 350)) {
              noiseSamples.add(rms);
              return;
            }
            noiseSamples.sort();
            if (noiseSamples.isNotEmpty) {
              // 取 80 分位而不是均值：偶发的一声爆音不该把整段的底噪抬高。
              final idx = (noiseSamples.length * 0.8).floor().clamp(
                  0, noiseSamples.length - 1);
              noiseFloor = noiseSamples[idx];
            }
            calibrated = true;
          }

          // 阈值夹在 [0.016, 0.05]：
          //  · 下限防安静房间的空调/风扇底噪被判成人声；
          //  · 上限防「用户一按完就开口」——那 350ms 里全是说话声，
          //    底噪被顶得比整句话还高，结果全程 heardVoice=false、白听一场。
          final threshold = math.min(
              math.max(noiseFloor * 2.0, 0.016), 0.05);
          if (rms > threshold) {
            lastLoud = now;
            heardVoice = true;
          }
          // 至少录够 800ms，别在第一个字后的气口就把整句截断。
          if (heardVoice &&
              elapsed >= const Duration(milliseconds: 800) &&
              now.difference(lastLoud) >= silenceToStop) {
            finish();
          }
          if (elapsed >= maxDuration) finish();
        },
      );
      if (!began) {
        throw SpeechException(
            _recorder.errorMessage.isEmpty ? '无法开始录音' : _recorder.errorMessage);
      }

      watchdog = Timer(maxDuration, finish);
      await done.future;
      watchdog.cancel();
      watchdog = null;
      await _recorder.stopRecording();

      // 全程没检测到人声：别把空调/底噪幻听成一句乱码再弹确认窗。
      // 例外：用户自己按停的 —— 他明确说了话，只是声音低于阈值（离得远、
      // 手机挡在口袋里），这时候拦下来只会让他觉得"按了没反应"。
      if (!heardVoice && !_forced) {
        asr.cancelListening();
        return '';
      }

      // ④ 整段音频一次推理，全程在本机
      onStage(SpeechStage.recognizing);
      final result = await asr.stopListening();
      return result.text.trim();
    } on SpeechException {
      rethrow;
    } catch (e) {
      throw SpeechException('语音识别失败：$e');
    } finally {
      watchdog?.cancel();
      _finishHook = null;
      _forced = false;
      _busy = false;
    }
  }

  /// PCM16 小端 → 归一化 RMS。
  /// 阈值不在这里写死：安静室内实测底噪能超过 0.012，固定值会一直误判人声，
  /// 所以判定阈值由 listen() 按开头 350ms 的环境底噪自适应算出。
  static double _rms(Uint8List bytes) {
    if (bytes.length < 2) return 0;
    final view = ByteData.sublistView(bytes);
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      final v = view.getInt16(i, Endian.little) / 32768.0;
      sum += v * v;
      count++;
    }
    return count == 0 ? 0 : math.sqrt(sum / count);
  }
}
