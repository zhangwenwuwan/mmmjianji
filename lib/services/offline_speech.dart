import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:voice_recognizer/voice_recognizer.dart';

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

  final AudioRecorderService _recorder = AudioRecorderService();
  bool _busy = false;

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

      // ② 模型初始化（首次点击才做，之后常驻内存）
      onStage(SpeechStage.preparing);
      final registry = VoiceRecognizerRegistry.instance;
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
      onStage(SpeechStage.listening);
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
      if (!heardVoice) {
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
