# Turns a normal DJI R-JPEG into a stand-in for an M4T super-resolution image:
# sets the APP4 'iirp' mode byte to 3 (the caller strips EXIF Make/Model).
import struct, sys
src, dst = sys.argv[1], sys.argv[2]
d = bytearray(open(src, 'rb').read())
i = 2
while d[i + 1] != 0xDA:
    marker = d[i + 1]
    length = struct.unpack('>H', d[i + 2:i + 4])[0]
    payload = i + 4
    if marker == 0xE4 and d[payload:payload + 8] == bytes.fromhex('ffd2d1ff69697270'):
        d[payload + 128] = 3
        open(dst, 'wb').write(d)
        sys.exit(0)
    i += 2 + length
sys.exit('no iirp APP4 header found')
