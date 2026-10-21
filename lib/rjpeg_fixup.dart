import 'dart:typed_data';

// Helpers for DJI R-JPEGs that the DJI Thermal SDK refuses to open as-is.
//
// M4T images captured in infrared super-resolution (high-res) mode have a
// 1280x1024 visible JPEG, but their radiometric payload is still the native
// 640x512 frame. The SDK rejects them for two reasons:
//  - IFD0 has no Make/Model (they only exist in XMP) -> -7 DIRP_ERROR_RJPEG_PARSE
//  - the APP4 header marks the image as super mode -> -64 DIRP_ERROR_SUPER_MODE

const _iirpMagic = [0xFF, 0xD2, 0xD1, 0xFF, 0x69, 0x69, 0x72, 0x70];
const _modeOffset = 128;
const _modeNormal = 1;
const _modeSuperResolution = 3;
const _tagMake = 0x010F;

class _Segment {
  final int marker;
  final int start; // offset of the payload (after the length field)
  final int length; // payload length

  _Segment(this.marker, this.start, this.length);
}

// Walks the JPEG header segments up to the start of scan. Stops quietly on
// malformed input, returning whatever was parsed so far.
List<_Segment> _segments(Uint8List bytes) {
  final segments = <_Segment>[];
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return segments;

  var i = 2;
  while (i + 4 <= bytes.length && bytes[i] == 0xFF) {
    final marker = bytes[i + 1];
    if (marker == 0xDA || marker == 0xD9) break;
    final length = (bytes[i + 2] << 8 | bytes[i + 3]) - 2;
    if (length < 0 || i + 4 + length > bytes.length) break;
    segments.add(_Segment(marker, i + 4, length));
    i += 4 + length;
  }
  return segments;
}

// Offset of the super-resolution mode byte, or -1 if this is not a DJI
// "iirp" header with the super-resolution flag set.
int _superResolutionModeIndex(Uint8List bytes) {
  for (final s in _segments(bytes)) {
    if (s.marker != 0xE4) continue;
    if (s.length <= _modeOffset) return -1;
    for (var k = 0; k < _iirpMagic.length; k++) {
      if (bytes[s.start + k] != _iirpMagic[k]) return -1;
    }
    final index = s.start + _modeOffset;
    return bytes[index] == _modeSuperResolution ? index : -1;
  }
  return -1;
}

bool isSuperResolution(Uint8List bytes) => _superResolutionModeIndex(bytes) >= 0;

// Returns a copy of [bytes] with the super-resolution flag cleared, so the
// SDK measures the native-resolution payload like a normal image.
Uint8List clearSuperResolution(Uint8List bytes) {
  final out = Uint8List.fromList(bytes);
  final index = _superResolutionModeIndex(bytes);
  if (index >= 0) out[index] = _modeNormal;
  return out;
}

// Whether the EXIF IFD0 contains a Make tag.
bool hasExifMake(Uint8List bytes) {
  for (final s in _segments(bytes)) {
    if (s.marker != 0xE1 || s.length < 14) continue;
    if (String.fromCharCodes(bytes, s.start, s.start + 6) != 'Exif\x00\x00') {
      continue;
    }

    final tiff = ByteData.sublistView(bytes, s.start + 6, s.start + s.length);
    final endian = tiff.getUint8(0) == 0x4D ? Endian.big : Endian.little;
    final ifd0 = tiff.getUint32(4, endian);
    if (ifd0 + 2 > tiff.lengthInBytes) return false;

    final count = tiff.getUint16(ifd0, endian);
    for (var e = 0; e < count; e++) {
      final entry = ifd0 + 2 + e * 12;
      if (entry + 2 > tiff.lengthInBytes) return false;
      if (tiff.getUint16(entry, endian) == _tagMake) return true;
    }
    return false;
  }
  return false;
}
