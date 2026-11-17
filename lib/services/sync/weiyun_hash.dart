import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

// Weiyun's upload protocol uses the unpadded SHA-1 chaining state in little
// endian at 512 KiB boundaries. Standard finalized digests alone are insufficient.
Map<String, dynamic> weiyunUploadHashes(Uint8List bytes) {
  final state = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0];
  int rotate(int x, int n) => ((x << n) | (x >>> (32 - n))) & 0xffffffff;
  String snapshot() {
    final data = ByteData(20);
    for (var i = 0; i < 5; i++) {
      data.setUint32(i * 4, state[i], Endian.little);
    }
    return data.buffer
        .asUint8List()
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  final last = bytes.length % 524288 == 0 ? 524288 : bytes.length % 524288;
  final check = last % 128 == 0 ? 128 : last % 128;
  final before = bytes.length - check;
  final blocks = <String>[];
  String checkState = snapshot();
  for (var offset = 0; offset < before; offset += 64) {
    final words = List<int>.filled(80, 0);
    final data = ByteData.sublistView(bytes, offset, offset + 64);
    for (var i = 0; i < 16; i++) {
      words[i] = data.getUint32(i * 4);
    }
    for (var i = 16; i < 80; i++) {
      words[i] = rotate(
        words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16],
        1,
      );
    }
    var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4];
    for (var i = 0; i < 80; i++) {
      final f = i < 20
          ? (b & c) | ((~b) & d)
          : i < 40
          ? b ^ c ^ d
          : i < 60
          ? (b & c) | (b & d) | (c & d)
          : b ^ c ^ d;
      final k = i < 20
          ? 0x5a827999
          : i < 40
          ? 0x6ed9eba1
          : i < 60
          ? 0x8f1bbcdc
          : 0xca62c1d6;
      final next = (rotate(a, 5) + f + e + k + words[i]) & 0xffffffff;
      e = d;
      d = c;
      c = rotate(b, 30);
      b = a;
      a = next;
    }
    final values = [a, b, c, d, e];
    for (var i = 0; i < 5; i++) {
      state[i] = (state[i] + values[i]) & 0xffffffff;
    }
    if ((offset + 64) % 524288 == 0) blocks.add(snapshot());
  }
  checkState = snapshot();
  final digest = sha1.convert(bytes).toString();
  blocks.add(digest);
  return {
    'file_sha': digest,
    'file_md5': md5.convert(bytes).toString(),
    'block_sha_list': blocks,
    'check_sha': checkState,
    'check_data': base64Encode(bytes.sublist(before)),
  };
}
