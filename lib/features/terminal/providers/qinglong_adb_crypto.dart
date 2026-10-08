import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_adb/adb_crypto.dart';

/// ADB RSA 签名兼容实现。
///
/// flutter_adb 1.0.0 的 `signAdbTokenPayload` 把 ADB 的 DigestInfo 前缀拼进
/// 待签名数据后，又交给 `RSASigner(SHA1)` 签名，等于对
/// `SHA1(DigestInfoPrefix + token)` 再做了一次带 DigestInfo 的签名。
/// 而 adbd 校验的是 `SHA1(token)` 的标准 PKCS#1 v1.5 签名，所以签名永远
/// 过不了——表现就是每次重连都弹“允许调试吗”，即使密钥已经保存。
///
/// 这里按 ADB 协议重新实现：`EM = 00 01 FF..00 || SHA1_DigestInfo || SHA1(token)`
/// 再做 RSA 私钥运算。
class QinglongAdbCrypto extends AdbCrypto {
  QinglongAdbCrypto({super.keyPair, super.adbKeyName});

  static const _sha1DigestInfoPrefix = <int>[
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e,
    0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14,
  ];

  @override
  Uint8List signAdbTokenPayload(Uint8List payload) {
    final privateKey = keyPair.privateKey;
    final n = privateKey.modulus;
    final d = privateKey.privateExponent;
    if (n == null || d == null) {
      throw StateError('ADB RSA 私钥不完整，无法签名');
    }

    final digest = sha1.convert(payload).bytes;
    final digestInfo = <int>[..._sha1DigestInfoPrefix, ...digest];

    final keyBytes = (n.bitLength + 7) ~/ 8;
    final paddingLength = keyBytes - digestInfo.length - 3;
    if (paddingLength < 8) {
      throw StateError('ADB RSA 密钥长度不足');
    }

    final em = Uint8List(keyBytes);
    em[0] = 0x00;
    em[1] = 0x01;
    for (var i = 0; i < paddingLength; i++) {
      em[2 + i] = 0xff;
    }
    em[2 + paddingLength] = 0x00;
    em.setRange(3 + paddingLength, keyBytes, digestInfo);

    final message = _bytesToBigInt(em);
    final signature = message.modPow(d, n);
    return _bigIntToBytes(signature, keyBytes);
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var value = BigInt.zero;
    for (final byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var v = value;
    final mask = BigInt.from(0xff);
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (v & mask).toInt();
      v = v >> 8;
    }
    return out;
  }
}
