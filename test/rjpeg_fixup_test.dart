import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dji_thermal_tools/rjpeg_fixup.dart';

// Builds a JPEG marker segment: FF <marker> <len hi> <len lo> <payload>
List<int> segment(int marker, List<int> payload) {
  final len = payload.length + 2;
  return [0xFF, marker, len >> 8, len & 0xFF, ...payload];
}

const iirpMagic = [0xFF, 0xD2, 0xD1, 0xFF, 0x69, 0x69, 0x72, 0x70];

// DJI APP4 header: magic followed by zeros, with the mode byte at offset 128.
List<int> app4Payload({List<int> magic = iirpMagic, int mode = 1}) {
  final p = List<int>.filled(1280, 0);
  p.setRange(0, magic.length, magic);
  p[128] = mode;
  return p;
}

// Exif APP1 payload with IFD0 entries for the given tags (SHORT, count 1).
List<int> exifPayload(List<int> tags, {bool bigEndian = false}) {
  final b = BytesBuilder();
  void u16(int v) => b.add(bigEndian ? [v >> 8, v & 0xFF] : [v & 0xFF, v >> 8]);
  void u32(int v) => b.add(bigEndian
      ? [v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]
      : [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, v >> 24]);
  b.add('Exif'.codeUnits);
  b.add([0, 0]);
  b.add(bigEndian ? 'MM'.codeUnits : 'II'.codeUnits);
  u16(42);
  u32(8);
  u16(tags.length);
  for (final tag in tags) {
    u16(tag);
    u16(3);
    u32(1);
    u32(1);
  }
  u32(0);
  return b.toBytes();
}

Uint8List jpeg(List<List<int>> segments) => Uint8List.fromList([
      0xFF, 0xD8,
      for (final s in segments) ...s,
      ...segment(0xDA, [0, 0, 0]),
      0x12, 0x34, 0xFF, 0xD9,
    ]);

const make = 0x010F;
const orientation = 0x0112;

void main() {
  group('isSuperResolution / clearSuperResolution', () {
    test('detects and clears the super-resolution mode byte', () {
      final input = jpeg([segment(0xE4, app4Payload(mode: 3))]);
      final original = Uint8List.fromList(input);

      expect(isSuperResolution(input), isTrue);
      final patched = clearSuperResolution(input);

      expect(isSuperResolution(patched), isFalse);
      final diffs = [
        for (var i = 0; i < input.length; i++)
          if (input[i] != patched[i]) i
      ];
      expect(diffs.length, 1);
      expect(patched[diffs.single], 1);
      expect(input, original, reason: 'input must not be mutated');
    });

    test('leaves normal images unchanged', () {
      final input = jpeg([segment(0xE4, app4Payload(mode: 1))]);
      expect(isSuperResolution(input), isFalse);
      expect(clearSuperResolution(input), input);
    });

    test('ignores other APP4 header families', () {
      final h20t = [0xAA, 0x55, 0x12, 0x06, 0x3A, 0x43, 0xA1, 0xB5];
      final input = jpeg([segment(0xE4, app4Payload(magic: h20t, mode: 3))]);
      expect(isSuperResolution(input), isFalse);
      expect(clearSuperResolution(input), input);
    });

    test('ignores FF E4 bytes inside an earlier segment payload', () {
      final decoy = List<int>.filled(300, 0);
      decoy.setRange(10, 14, [0xFF, 0xE4, 0x05, 0x02]);
      decoy[10 + 4 + 128] = 3;
      final input = jpeg([
        segment(0xE3, decoy),
        segment(0xE4, app4Payload(mode: 1)),
      ]);
      expect(isSuperResolution(input), isFalse);
      expect(clearSuperResolution(input), input);
    });

    test('finds the iirp header after another APP4 segment', () {
      final other = app4Payload(magic: [1, 2, 3, 4, 5, 6, 7, 8], mode: 1);
      final input = jpeg([
        segment(0xE4, other),
        segment(0xE4, app4Payload(mode: 3)),
      ]);
      expect(isSuperResolution(input), isTrue);
      expect(isSuperResolution(clearSuperResolution(input)), isFalse);
    });

    test('APP4 too short to hold the mode byte is ignored', () {
      final short = app4Payload(mode: 3).sublist(0, 128);
      expect(isSuperResolution(jpeg([segment(0xE4, short)])), isFalse);
      final justLongEnough = app4Payload(mode: 3).sublist(0, 129);
      expect(isSuperResolution(jpeg([segment(0xE4, justLongEnough)])), isTrue);
    });

    test('no APP4 segment means not super-resolution', () {
      expect(isSuperResolution(jpeg([segment(0xE1, exifPayload([make]))])),
          isFalse);
    });
  });

  group('hasExifMake', () {
    test('finds Make in little-endian IFD0', () {
      expect(hasExifMake(jpeg([segment(0xE1, exifPayload([make, orientation]))])),
          isTrue);
    });

    test('finds Make in big-endian IFD0', () {
      expect(
          hasExifMake(jpeg([
            segment(0xE1, exifPayload([orientation, make], bigEndian: true))
          ])),
          isTrue);
    });

    test('IFD0 with only Orientation has no Make', () {
      expect(
          hasExifMake(jpeg([
            segment(0xE1, exifPayload([orientation], bigEndian: true))
          ])),
          isFalse);
    });

    test('XMP-only APP1 has no Make', () {
      final xmp = 'http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta tiff:Make="DJI"/>'
          .codeUnits;
      expect(hasExifMake(jpeg([segment(0xE1, xmp)])), isFalse);
    });

    test('finds Make in an Exif APP1 that follows an XMP APP1', () {
      final xmp = 'http://ns.adobe.com/xap/1.0/\x00<x:xmpmeta/>'.codeUnits;
      expect(
          hasExifMake(
              jpeg([segment(0xE1, xmp), segment(0xE1, exifPayload([make]))])),
          isTrue);
    });

    test('IFD0 offset or entry count past the segment end has no Make', () {
      final badOffset = exifPayload([make]);
      badOffset[10] = 0xFF; // IFD0 offset (little-endian) -> far past the end
      expect(hasExifMake(jpeg([segment(0xE1, badOffset)])), isFalse);

      final badCount = exifPayload([orientation]);
      badCount[14] = 50; // claims 50 entries, only 1 present
      expect(hasExifMake(jpeg([segment(0xE1, badCount)])), isFalse);
    });
  });

  group('malformed input', () {
    final inputs = {
      'empty': Uint8List(0),
      'not a jpeg': Uint8List.fromList('hello world'.codeUnits),
      'truncated segment': Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE4, 0x10]),
      'truncated exif': Uint8List.fromList(
          [0xFF, 0xD8, ...segment(0xE1, 'Exif\x00\x00II'.codeUnits)]),
    };
    inputs.forEach((name, bytes) {
      test('$name reports no defects without throwing', () {
        expect(isSuperResolution(bytes), isFalse);
        expect(hasExifMake(bytes), isFalse);
        expect(clearSuperResolution(bytes), bytes);
      });
    });
  });
}
