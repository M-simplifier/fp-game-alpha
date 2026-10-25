"""Authored procedural colony icon, using only Python's standard library."""
import math
from pathlib import Path
import struct
import sys
import zlib


def polygon(x, y, points):
    inside = False
    for first, second in zip(points, points[1:] + points[:1]):
        ax, ay = first
        bx, by = second
        if (ay > y) != (by > y) and x < (bx - ax) * (y - ay) / (by - ay) + ax:
            inside = not inside
    return inside


def pixel(x, y):
    edge_x, edge_y = max(0.14 - x, x - 0.86, 0), max(0.14 - y, y - 0.86, 0)
    if edge_x * edge_x + edge_y * edge_y > 0.14 * 0.14:
        return (0, 0, 0, 0)
    color = (211, 154, 111)
    if (x - 0.75) ** 2 + (y - 0.25) ** 2 < 0.10 ** 2:
        color = (253, 222, 153)
    if y > 0.57 + 0.09 * math.sin(x * 6):
        color = (181, 98, 65)
    if y > 0.78 - 0.16 * x:
        color = (157, 65, 43)
    if polygon(x, y, [(0.12, 0.64), (0.29, 0.55), (0.85, 0.74), (0.69, 0.85)]):
        color = (236, 184, 127)
    for origin_x, origin_y, roof in [(0.20, 0.52, (100, 160, 160)), (0.39, 0.58, (246, 222, 179)), (0.59, 0.64, (246, 222, 179))]:
        if polygon(x, y, [(origin_x, origin_y), (origin_x + 0.15, origin_y), (origin_x + 0.15, origin_y + 0.11), (origin_x, origin_y + 0.11)]):
            color = (187, 134, 94)
        if polygon(x, y, [(origin_x - 0.01, origin_y), (origin_x + 0.07, origin_y - 0.055), (origin_x + 0.16, origin_y), (origin_x + 0.07, origin_y + 0.055)]):
            color = roof
    return (*color, 255)


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def main():
    directory = Path(sys.argv[1])
    directory.mkdir(parents=True, exist_ok=True)
    size = 128
    rows = [b'\0' + bytes(component for x in range(size)
                         for component in pixel((x + 0.5) / size, (y + 0.5) / size))
            for y in range(size)]
    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', size, size, 8, 6, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))
    (directory / 'icon.png').write_bytes(png)
    header = struct.pack('<HHH', 0, 1, 1)
    entry = struct.pack('<BBBBHHII', size, size, 0, 0, 1, 32, len(png), 22)
    (directory / 'icon.ico').write_bytes(header + entry + png)


if __name__ == '__main__':
    main()
