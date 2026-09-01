# tools/gen_icon.py - Regenerate a valid Windows icon.ico from PNG sources.
# Pure-stdlib (no PIL/ImageMagick needed). Assembles a multi-size .ico using
# PNG-as-payload (the modern format Windows accepts since Vista).
import struct, zlib, sys, os

RESOURCES = os.path.join(os.path.dirname(__file__), "..", "resources")

# (size, source png file). 16/32 are downscaled from the 256 master.
SOURCES = {
    48:  "icon_48.png",
    64:  "icon_64.png",
    128: "icon_128.png",
    256: "icon_256.png",
}


def decode_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG: " + path
    pos = 8
    width = height = colortype = 0
    idat = b""
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        chunk = d[pos + 8:pos + 8 + ln]
        if typ == b"IHDR":
            width, height, _bd, colortype = struct.unpack(">IIBB", chunk[:10])
        elif typ == b"IDAT":
            idat += chunk
        elif typ == b"IEND":
            break
        pos += 12 + ln
    raw = zlib.decompress(idat)
    ch = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[colortype]
    stride = width * ch
    out = bytearray()
    prev = bytearray(stride)
    p = 0
    for _ in range(height):
        f = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        for x in range(stride):
            a = line[x - ch] if x >= ch else 0
            b = prev[x]
            c = prev[x - ch] if x >= ch else 0
            if f == 0:
                v = line[x]
            elif f == 1:
                v = line[x] + a
            elif f == 2:
                v = line[x] + b
            elif f == 3:
                v = line[x] + (a + b) // 2
            elif f == 4:
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                v = line[x] + (a if (pa <= pb and pa <= pc) else (b if pb <= pc else c))
            else:
                raise ValueError("bad filter %d" % f)
            line[x] = v & 0xFF
        out += line
        prev = line
    # to RGBA
    if colortype == 6:
        return width, height, bytes(out)
    rgba = bytearray(width * height * 4)
    for i in range(width * height):
        if colortype == 2:
            rgba[i * 4:i * 4 + 3] = out[i * 3:i * 3 + 3]
            rgba[i * 4 + 3] = 255
        else:
            raise ValueError("unsupported color type %d" % colortype)
    return width, height, bytes(rgba)


def box_resize(rgba, sw, sh, dw, dh):
    out = bytearray(dw * dh * 4)
    for y in range(dh):
        y0, y1 = int(y * sh / dh), int((y + 1) * sh / dh)
        if y1 == y0:
            y1 = y0 + 1
        for x in range(dw):
            x0, x1 = int(x * sw / dw), int((x + 1) * sw / dw)
            if x1 == x0:
                x1 = x0 + 1
            r = g = b = a = n = 0
            for sy in range(y0, min(y1, sh)):
                for sx in range(x0, min(x1, sw)):
                    i = (sy * sw + sx) * 4
                    r += rgba[i]; g += rgba[i + 1]; b += rgba[i + 2]; a += rgba[i + 3]; n += 1
            o = (y * dw + x) * 4
            out[o], out[o + 1], out[o + 2], out[o + 3] = r // n, g // n, b // n, a // n
    return bytes(out)


def encode_png_rgba(rgba, w, h):
    stride = w * 4
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgba[y * stride:(y + 1) * stride]
    comp = zlib.compress(bytes(raw), 9)

    def chunk(typ, data):
        c = typ + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", comp) + chunk(b"IEND", b"")


# Build RGBA for every target size
targets = {48, 64, 128, 256}
images = {}
for size, fname in SOURCES.items():
    w, h, px = decode_png(os.path.join(RESOURCES, fname))
    assert w == h == size, "size mismatch %s: %dx%d" % (fname, w, h)
    images[size] = px

master = images[256]
# Downscale 16/32 from the 256 master
for s in (16, 32):
    images[s] = box_resize(master, 256, 256, s, s)

# Assemble .ico
entries = []
for size in sorted(images):
    png = encode_png_rgba(images[size], size, size)
    entries.append((size, png))

icondir = struct.pack("<HHH", 0, 1, len(entries))
hdr_size = 6 + 16 * len(entries)
offset = hdr_size
data = b""
dirs = []
for size, png in entries:
    bw = 0 if size >= 256 else size
    bh = 0 if size >= 256 else size
    dirs.append(struct.pack("<BBBBHHII", bw, bh, 0, 0, 1, 32, len(png), offset))
    data += png
    offset += len(png)
ico = icondir + b"".join(dirs) + data

out_path = os.path.join(RESOURCES, "icon.ico")
# backup the old (corrupt) file
if os.path.exists(out_path):
    os.replace(out_path, out_path + ".bak.corrupt")
with open(out_path, "wb") as f:
    f.write(ico)
print("Wrote", out_path, "size=", len(ico), "entries=", [e[0] for e in entries])
