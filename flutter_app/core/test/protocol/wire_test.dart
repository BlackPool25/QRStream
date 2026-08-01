import 'dart:typed_data';

import 'package:qr_transfer_core/protocol/wire.dart';
import 'package:test/test.dart';

/// Golden frame pinned from the PWA's encodeFrame (src/protocol/wire.ts,
/// run via vitest on 2026-08-01): type 0x01, sessionId 0123456789abcdef,
/// esi 7, k 42, totalLen 0x123456, flags 0, payload [0xde, 0xad, 0xbe, 0xef].
const _goldenHex =
    '5152444601010123456789abcdef070000002a0000000400000056341200deadbeef'
    'd28bd1f8';

Frame _frame({int type = 0x01, String sessionId = '0123456789abcdef'}) => Frame(
  type: type,
  sessionId: sessionId,
  esi: 7,
  k: 42,
  totalLen: 0x123456,
  flags: 0,
  payload: Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]),
);

Uint8List _hexToBytes(String hex) => Uint8List.fromList(
  List.generate(
    hex.length ~/ 2,
    (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
  ),
);

String _toHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Matcher _throwsCode(ProtocolErrorCode code) =>
    throwsA(isA<ProtocolError>().having((e) => e.code, 'code', code));

void main() {
  group('encodeFrame/decodeFrame round-trip', () {
    for (final size in [0, 1, 1004, 1024, 1465]) {
      test('payload size $size', () {
        final payload = Uint8List.fromList(
          List.generate(size, (i) => (i * 131 + size) & 0xff),
        );
        final frame = Frame(
          type: 0x01,
          sessionId: '0123456789abcdef',
          esi: 12345,
          k: 42,
          totalLen: size * 3 + 1,
          flags: 0,
          payload: payload,
        );
        final decoded = decodeFrame(encodeFrame(frame));
        expect(decoded.type, frame.type);
        expect(decoded.sessionId, frame.sessionId);
        expect(decoded.esi, frame.esi);
        expect(decoded.k, frame.k);
        expect(decoded.totalLen, frame.totalLen);
        expect(decoded.flags, frame.flags);
        expect(decoded.payload, frame.payload);
      });
    }
  });

  group('totalLen boundary', () {
    test('0xffffff round-trips', () {
      final frame = Frame(
        type: 0x02,
        sessionId: '0123456789abcdef',
        esi: 0,
        k: 0,
        totalLen: 0xffffff,
        flags: 0x01,
        payload: Uint8List.fromList([0xaa, 0xbb, 0xcc]),
      );
      final decoded = decodeFrame(encodeFrame(frame));
      expect(decoded.type, 0x02);
      expect(decoded.totalLen, 0xffffff);
      expect(decoded.flags, 0x01);
    });

    test('encode 0x1000000 throws badTotalLen', () {
      final frame = Frame(
        type: 0x01,
        sessionId: '0123456789abcdef',
        esi: 0,
        k: 0,
        totalLen: 0x1000000,
        flags: 0,
        payload: Uint8List(0),
      );
      expect(
        () => encodeFrame(frame),
        _throwsCode(ProtocolErrorCode.badTotalLen),
      );
    });
  });

  group('decode rejects corrupted frames', () {
    test('bad magic (flip byte 0) throws badMagic', () {
      final bytes = encodeFrame(_frame())..[0] = 0x00;
      expect(() => decodeFrame(bytes), _throwsCode(ProtocolErrorCode.badMagic));
    });

    test('wrong version throws badVersion', () {
      final bytes = encodeFrame(_frame())..[4] = 2;
      expect(
        () => decodeFrame(bytes),
        _throwsCode(ProtocolErrorCode.badVersion),
      );
    });

    test('bad type (byte 5 = 3) throws badType', () {
      final bytes = encodeFrame(_frame())..[5] = 3;
      expect(() => decodeFrame(bytes), _throwsCode(ProtocolErrorCode.badType));
    });

    test('CRC mismatch (flip a payload byte) throws badCrc', () {
      final bytes = encodeFrame(_frame())..[32] = 0x00;
      expect(() => decodeFrame(bytes), _throwsCode(ProtocolErrorCode.badCrc));
    });

    test('truncated (cut 4 bytes) throws truncated', () {
      final bytes = encodeFrame(_frame());
      expect(
        () => decodeFrame(bytes.sublist(0, bytes.length - 4)),
        _throwsCode(ProtocolErrorCode.truncated),
      );
    });

    test('shorter than header + CRC throws truncated', () {
      expect(
        () => decodeFrame(Uint8List(10)),
        _throwsCode(ProtocolErrorCode.truncated),
      );
    });

    test('trailing bytes after CRC throws badLength', () {
      final bytes = Uint8List.fromList([...encodeFrame(_frame()), 0x00]);
      expect(
        () => decodeFrame(bytes),
        _throwsCode(ProtocolErrorCode.badLength),
      );
    });

    test('reserved flag bits set throws badFlags', () {
      final bytes = encodeFrame(_frame())..[29] = 0x02;
      expect(() => decodeFrame(bytes), _throwsCode(ProtocolErrorCode.badFlags));
    });
  });

  group('encode rejects invalid frames', () {
    test('bad type throws badType', () {
      expect(
        () => encodeFrame(_frame(type: 3)),
        _throwsCode(ProtocolErrorCode.badType),
      );
    });

    test('bad sessionId throws badSessionId', () {
      expect(
        () => encodeFrame(_frame(sessionId: 'not-hex!')),
        _throwsCode(ProtocolErrorCode.badSessionId),
      );
      expect(
        () => encodeFrame(_frame(sessionId: '0123456789abcdef0')),
        _throwsCode(ProtocolErrorCode.badSessionId),
      );
    });

    test('uppercase hex sessionId encodes and decodes lowercase', () {
      final decoded = decodeFrame(
        encodeFrame(_frame(sessionId: '0123456789ABCDEF')),
      );
      expect(decoded.sessionId, '0123456789abcdef');
    });

    test('bad esi throws badEsi', () {
      final frame = Frame(
        type: 0x01,
        sessionId: '0123456789abcdef',
        esi: -1,
        k: 0,
        totalLen: 1,
        flags: 0,
        payload: Uint8List(0),
      );
      expect(() => encodeFrame(frame), _throwsCode(ProtocolErrorCode.badEsi));
    });

    test('bad k throws badK', () {
      final frame = Frame(
        type: 0x01,
        sessionId: '0123456789abcdef',
        esi: 0,
        k: 0x100000000,
        totalLen: 1,
        flags: 0,
        payload: Uint8List(0),
      );
      expect(() => encodeFrame(frame), _throwsCode(ProtocolErrorCode.badK));
    });

    test('reserved flag bits throw badFlags', () {
      final frame = Frame(
        type: 0x01,
        sessionId: '0123456789abcdef',
        esi: 0,
        k: 0,
        totalLen: 1,
        flags: 0x02,
        payload: Uint8List(0),
      );
      expect(() => encodeFrame(frame), _throwsCode(ProtocolErrorCode.badFlags));
    });
  });

  group('golden cross-check against PWA encodeFrame', () {
    test('Dart encodeFrame produces the PWA golden bytes', () {
      final hex = _toHex(encodeFrame(_frame()));
      expect(hex, _goldenHex);
    });

    test('decodeFrame accepts the PWA golden bytes', () {
      final decoded = decodeFrame(_hexToBytes(_goldenHex));
      expect(decoded.type, 0x01);
      expect(decoded.sessionId, '0123456789abcdef');
      expect(decoded.esi, 7);
      expect(decoded.k, 42);
      expect(decoded.totalLen, 0x123456);
      expect(decoded.flags, 0);
      expect(decoded.payload, Uint8List.fromList([0xde, 0xad, 0xbe, 0xef]));
    });
  });

  group('generateSessionId', () {
    test('returns 16 lowercase hex chars', () {
      for (var i = 0; i < 20; i++) {
        expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(generateSessionId()), isTrue);
      }
    });

    test('unique across calls', () {
      final ids = List.generate(1000, (_) => generateSessionId());
      expect(ids.toSet().length, 1000);
    });
  });
}
