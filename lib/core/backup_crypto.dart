/// 简记备份文件的加密/解密。
///
/// 目标：导出的备份不再是明文 JSON —— 别人拿到文件直接打开看不到流水明细。
/// 格式（纯文本，便于存文件 / 系统分享）：
///
/// ```
/// JJBK1:<base64( salt[16] | nonce[16] | ciphertext[N] | tag[32] )>
/// ```
///
/// 密钥派生：PBKDF2-HMAC-SHA256(appSecret, salt, 4096 轮) → 64 字节，
/// 前 32 作加密密钥、后 32 作认证密钥。
/// 加密：HMAC-SHA256(encKey, nonce || counter) 生成密钥流，与明文 XOR（CTR 模式）。
/// 认证：HMAC-SHA256(macKey, nonce || ciphertext)，encrypt-then-MAC，解密先验 tag。
///
/// 安全边界：密钥内置在 App 里，属于「防偷看」级别 —— 能挡住随手打开文件和
/// 自动爬虫，挡不住拿到 APK 后逆向提取密钥的人。真要抗逆向得让用户自设密码
/// 并走系统 Keystore，那会显著增加导出/导入的交互步骤，与「界面越简单越好」
/// 的诉求冲突。随机 salt + nonce 保证同一份数据每次导出的密文都不同。
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const String _magic = 'JJBK1';
const int _kdfRounds = 4096;
const int _saltLen = 16;
const int _nonceLen = 16;
const int _tagLen = 32;
const int _keyLen = 64;

// 内置密钥。改这个值会让所有旧备份解不开 —— 除非同时提供明文兼容入口。
const String _appSecret = 'jianji.backup.v1.9f3a7c21e4b8d056';

/// 备份文件解密失败（密码不符 / 文件损坏 / magic 不对）。
class BackupCryptoException implements Exception {
  final String message;
  const BackupCryptoException(this.message);

  @override
  String toString() => 'BackupCryptoException: $message';
}

/// 判断一段文本是不是简记加密备份。
bool isEncryptedBackup(String text) =>
    text.trimLeft().startsWith('$_magic:');

/// 把明文（备份 JSON）加密成可存文件的字符串。
String encryptBackup(String plainText) {
  final random = Random.secure();
  final salt = Uint8List.fromList(
      List<int>.generate(_saltLen, (_) => random.nextInt(256)));
  final nonce = Uint8List.fromList(
      List<int>.generate(_nonceLen, (_) => random.nextInt(256)));

  final keys = _pbkdf2(_appSecret, salt, _keyLen, _kdfRounds);
  final encKey = keys.sublist(0, 32);
  final macKey = keys.sublist(32);

  final plain = utf8.encode(plainText);
  final cipher = _ctrXor(encKey, nonce, plain);
  final tag = _hmac(macKey, <int>[...nonce, ...cipher]);

  final body = <int>[...salt, ...nonce, ...cipher, ...tag];
  return '$_magic:${base64.encode(body)}';
}

/// 解密备份文件。不是本格式 / tag 校验失败 / UTF-8 非法都会抛
/// [BackupCryptoException]。
String decryptBackup(String payload) {
  final text = payload.trim();
  if (!text.startsWith('$_magic:')) {
    throw const BackupCryptoException('不是简记加密备份文件');
  }
  final encoded = text.substring(_magic.length + 1).trim();
  Uint8List body;
  try {
    body = base64.decode(encoded);
  } catch (_) {
    throw const BackupCryptoException('备份文件内容损坏');
  }
  final minLen = _saltLen + _nonceLen + _tagLen;
  if (body.length < minLen) {
    throw const BackupCryptoException('备份文件内容不完整');
  }

  final salt = body.sublist(0, _saltLen);
  final nonce = body.sublist(_saltLen, _saltLen + _nonceLen);
  final tag = body.sublist(body.length - _tagLen);
  final cipher = body.sublist(_saltLen + _nonceLen, body.length - _tagLen);

  final keys = _pbkdf2(_appSecret, salt, _keyLen, _kdfRounds);
  final macKey = keys.sublist(32);
  final expected = _hmac(macKey, <int>[...nonce, ...cipher]);
  if (!_constantTimeEquals(tag, expected)) {
    throw const BackupCryptoException('备份校验失败，文件可能被改动过');
  }

  final encKey = keys.sublist(0, 32);
  final plain = _ctrXor(encKey, nonce, cipher);
  try {
    return utf8.decode(plain);
  } catch (_) {
    throw const BackupCryptoException('解密结果不是有效文本');
  }
}

Uint8List _ctrXor(List<int> key, List<int> nonce, List<int> data) {
  final out = Uint8List(data.length);
  final hmac = Hmac(sha256, key);
  final counter = Uint8List(4);
  var blockIndex = 0;
  var offset = 0;
  while (offset < data.length) {
    counter[0] = (blockIndex >> 24) & 0xff;
    counter[1] = (blockIndex >> 16) & 0xff;
    counter[2] = (blockIndex >> 8) & 0xff;
    counter[3] = blockIndex & 0xff;
    final stream = hmac.convert(<int>[...nonce, ...counter]).bytes;
    final take = min(32, data.length - offset);
    for (var i = 0; i < take; i++) {
      out[offset + i] = data[offset + i] ^ stream[i];
    }
    offset += take;
    blockIndex++;
  }
  return out;
}

Uint8List _hmac(List<int> key, List<int> data) =>
    Uint8List.fromList(Hmac(sha256, key).convert(data).bytes);

/// 标准 PBKDF2-HMAC-SHA256。
Uint8List _pbkdf2(String secret, List<int> salt, int dkLen, int rounds) {
  final hmac = Hmac(sha256, utf8.encode(secret));
  final out = BytesBuilder(copy: false);
  const hLen = 32;
  final blocks = (dkLen / hLen).ceil();
  for (var block = 1; block <= blocks; block++) {
    final counter = <int>[
      (block >> 24) & 0xff,
      (block >> 16) & 0xff,
      (block >> 8) & 0xff,
      block & 0xff,
    ];
    var u = hmac.convert(<int>[...salt, ...counter]).bytes;
    final t = Uint8List.fromList(u);
    for (var i = 1; i < rounds; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < hLen; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
  }
  final all = out.takeBytes();
  return Uint8List.fromList(all.sublist(0, dkLen));
}

bool _constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
