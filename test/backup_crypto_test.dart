import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:jianji/core/backup_crypto.dart';

void main() {
  group('备份文件加密', () {
    const samples = [
      '{}',
      '{"app":"jianji","entries":[]}',
      '{"app":"jianji","note":"餐饮 ¥128.00 · 昨天","books":[{"title":"日常账本"}]}',
    ];

    test('加密后不再是明文，密文往返一致', () {
      for (final plain in samples) {
        final enc = encryptBackup(plain);
        expect(enc.startsWith('JJBK1:'), isTrue);
        expect(enc.contains(plain), isFalse,
            reason: '密文里不能出现明文片段');
        expect(decryptBackup(enc), plain);
      }
    });

    test('同一份数据两次加密结果不同（随机 salt + nonce）', () {
      final a = encryptBackup(samples.last);
      final b = encryptBackup(samples.last);
      expect(a, isNot(b));
      expect(decryptBackup(a), decryptBackup(b));
    });

    test('中文与较大文本往返', () {
      final plain = jsonEncode({
        'app': 'jianji',
        'note': '早餐 🥟 · 地铁 🚇 · 房租 ¥2500.00',
        'rows': List.generate(300, (i) => {'id': i, 'memo': '第 $i 笔'}),
      });
      final enc = encryptBackup(plain);
      expect(decryptBackup(enc), plain);
    });

    test('篡改密文 tag 会导致校验失败', () {
      final enc = encryptBackup(samples.last);
      final raw = base64.decode(enc.substring('JJBK1:'.length));
      raw[raw.length - 1] ^= 0xff; // 翻掉 tag 最后一字节
      final tampered = 'JJBK1:${base64.encode(raw)}';
      expect(() => decryptBackup(tampered),
          throwsA(isA<BackupCryptoException>()));
    });

    test('截断的文件抛异常', () {
      const short = 'JJBK1:AAEC';
      expect(() => decryptBackup(short), throwsA(isA<BackupCryptoException>()));
    });

    test('非本格式 / 坏 base64 抛异常', () {
      expect(isEncryptedBackup('{"app":"jianji"}'), isFalse);
      expect(isEncryptedBackup('  JJBK1:abc'), isTrue);
      expect(() => decryptBackup('{"app":"jianji"}'),
          throwsA(isA<BackupCryptoException>()));
      expect(() => decryptBackup('JJBK1:@@@bad@@@'),
          throwsA(isA<BackupCryptoException>()));
    });

    test('CTR 密钥流按 32 字节分块正确（长文本跨多块）', () {
      final plain = 'a' * 100 + '中文' * 60; // 超过 3 个 32 字节块
      expect(decryptBackup(encryptBackup(plain)), plain);
    });

    test('密文体长度 = salt+nonce+密文+tag', () {
      final plain = 'hello';
      final raw = base64.decode(encryptBackup(plain).substring(6));
      // 16 salt + 16 nonce + 5 密文 + 32 tag = 69
      expect(raw.length, 16 + 16 + utf8.encode(plain).length + 32);
      expect(raw, isA<Uint8List>());
    });
  });
}
