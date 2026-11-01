import 'dart:typed_data';

/// 纯 Dart 的 SHA-256。
///
/// 为什么不用 `package:crypto`：本项目约定**零第三方依赖**（见 README 的
/// 「设计取舍」）。而下载模块包时要用清单里的 sha256 校验完整性 ——
/// 与其为了一个哈希函数引入依赖，不如自己写一份，算法是公开且固定的。
///
/// 已验证向量：
///   "abc" → ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
///   空串  → e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
abstract final class Sha256 {
  Sha256._();

  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  /// 返回 64 位小写十六进制摘要。
  static String hex(List<int> data) {
    final sb = StringBuffer();
    for (final v in _digest(data)) {
      sb.write(v.toRadixString(16).padLeft(8, '0'));
    }
    return sb.toString();
  }

  static int _rotr(int x, int n) =>
      ((x >> n) | (x << (32 - n))) & 0xffffffff;

  static List<int> _digest(List<int> data) {
    final h = <int>[
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];

    // 补位：追加 0x80，补 0 到 56 (mod 64)，最后 8 字节写原始比特长度
    final bitLen = data.length * 8;
    final padded = BytesBuilder(copy: false)..add(data);
    padded.addByte(0x80);
    while (padded.length % 64 != 56) {
      padded.addByte(0);
    }
    final lenBytes = ByteData(8)..setUint64(0, bitLen, Endian.big);
    padded.add(lenBytes.buffer.asUint8List());
    final msg = padded.takeBytes();

    final w = Uint32List(64);
    for (var i = 0; i < msg.length; i += 64) {
      for (var t = 0; t < 16; t++) {
        final o = i + t * 4;
        w[t] = (msg[o] << 24) |
            (msg[o + 1] << 16) |
            (msg[o + 2] << 8) |
            msg[o + 3];
      }
      for (var t = 16; t < 64; t++) {
        final x = w[t - 15];
        final y = w[t - 2];
        final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
        final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
      }

      var a = h[0], b = h[1], c = h[2], d = h[3];
      var e = h[4], f = h[5], g = h[6], hh = h[7];

      for (var t = 0; t < 64; t++) {
        final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
        final ch = (e & f) ^ ((~e & 0xffffffff) & g);
        final temp1 = (hh + s1 + ch + _k[t] + w[t]) & 0xffffffff;
        final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
        final maj = (a & b) ^ (a & c) ^ (b & c);
        final temp2 = (s0 + maj) & 0xffffffff;

        hh = g;
        g = f;
        f = e;
        e = (d + temp1) & 0xffffffff;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) & 0xffffffff;
      }

      h[0] = (h[0] + a) & 0xffffffff;
      h[1] = (h[1] + b) & 0xffffffff;
      h[2] = (h[2] + c) & 0xffffffff;
      h[3] = (h[3] + d) & 0xffffffff;
      h[4] = (h[4] + e) & 0xffffffff;
      h[5] = (h[5] + f) & 0xffffffff;
      h[6] = (h[6] + g) & 0xffffffff;
      h[7] = (h[7] + hh) & 0xffffffff;
    }
    return h;
  }
}
