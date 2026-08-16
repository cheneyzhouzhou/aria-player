#!/usr/bin/env python3
"""Generate a small synthetic FLAC library for testing and screenshots.

Produces four "albums" of tonal audio, each with generated cover art in a
different hue, complete with Vorbis comments and an embedded PICTURE block —
so every feature that reads metadata (tags, artwork, palette extraction) has
something real to chew on without shipping anyone's actual music.

    python3 Tools/make-demo-library.py [output-dir]

Requires only macOS's built-in `afconvert` for FLAC encoding.
"""
import math
import os
import struct
import subprocess
import sys
import tempfile
import zlib

SAMPLE_RATE = 44100
BITS = 16

ALBUMS = [
    {
        "album": "Neon Cartography", "artist": "The Wandering Signal", "year": "2021",
        "hue": (0.62, 0.42, 0.95),
        "tracks": [("First Light", [261.63, 329.63, 392.00], 14),
                   ("Harbour Lines", [246.94, 311.13, 369.99], 11),
                   ("Slow Transit", [220.00, 277.18, 329.63], 17)],
    },
    {
        "album": "Paper Radio", "artist": "Marta Vell", "year": "2019",
        "hue": (0.95, 0.35, 0.45),
        "tracks": [("Shortwave", [293.66, 349.23, 440.00], 12),
                   ("Static Bloom", [261.63, 311.13, 392.00], 15),
                   ("Dial Tone Waltz", [196.00, 246.94, 293.66], 9)],
    },
    {
        "album": "Glasshouse", "artist": "Okonkwo Trio", "year": "2023",
        "hue": (0.25, 0.78, 0.62),
        "tracks": [("Meridian", [329.63, 415.30, 493.88], 13),
                   ("Fern Room", [277.18, 349.23, 415.30], 16),
                   ("Late Rain", [233.08, 293.66, 349.23], 10)],
    },
    {
        "album": "Iron Season", "artist": "Halden Vox", "year": "2020",
        "hue": (0.98, 0.72, 0.25),
        "tracks": [("Foundry", [174.61, 220.00, 261.63], 18),
                   ("Coldwater", [196.00, 233.08, 293.66], 12),
                   ("Ember Field", [146.83, 185.00, 220.00], 14)],
    },
]


# ---------------------------------------------------------------- PNG writer

def png(width, height, pixels):
    """Minimal RGB PNG encoder — avoids a Pillow dependency."""
    raw = b"".join(b"\x00" + bytes(row) for row in pixels)

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b""))


def cover_art(rgb, side=600):
    """A diagonal gradient with a few bands — enough for palette extraction to
    find a dominant hue, and visually distinct per album."""
    r, g, b = rgb
    rows = []
    for y in range(side):
        row = bytearray()
        for x in range(side):
            t = (x + y) / (2 * side - 2)
            shade = 0.35 + 0.65 * t
            band = 1.0 - 0.12 * ((y // (side // 7)) % 2)
            row += bytes((
                max(0, min(255, int(255 * r * shade * band))),
                max(0, min(255, int(255 * g * shade * band))),
                max(0, min(255, int(255 * b * shade * band))),
            ))
        rows.append(row)
    return png(side, side, rows)


# --------------------------------------------------------------- audio

def wav(path, freqs, seconds):
    """A soft chord with a gentle envelope, written as 16-bit stereo PCM."""
    n = int(SAMPLE_RATE * seconds)
    frames = bytearray()
    for i in range(n):
        t = i / SAMPLE_RATE
        # Fade in and out so the ends aren't clicky.
        env = min(1.0, t / 0.8, (seconds - t) / 1.2)
        sample = sum(math.sin(2 * math.pi * f * t) for f in freqs) / len(freqs)
        # A slow tremolo keeps the waveform from looking synthetic in a scrubber.
        sample *= 0.55 * env * (0.9 + 0.1 * math.sin(2 * math.pi * 0.25 * t))
        v = int(max(-1.0, min(1.0, sample)) * 32000)
        frames += struct.pack("<hh", v, v)

    data = bytes(frames)
    with open(path, "wb") as f:
        f.write(b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE")
        f.write(b"fmt " + struct.pack("<IHHIIHH", 16, 1, 2, SAMPLE_RATE,
                                      SAMPLE_RATE * 4, 4, BITS))
        f.write(b"data" + struct.pack("<I", len(data)) + data)


# --------------------------------------------------------------- FLAC metadata

def block(kind, payload, last=False):
    header = bytes([(0x80 if last else 0) | kind]) + struct.pack(">I", len(payload))[1:]
    return header + payload


def vorbis_comment(tags):
    vendor = b"aria-demo"
    out = struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(tags))
    for key, value in tags:
        entry = f"{key}={value}".encode("utf-8")
        out += struct.pack("<I", len(entry)) + entry
    return out


def picture(png_bytes, side=600):
    mime = b"image/png"
    desc = b""
    return (struct.pack(">I", 3)                     # front cover
            + struct.pack(">I", len(mime)) + mime
            + struct.pack(">I", len(desc)) + desc
            + struct.pack(">IIII", side, side, 24, 0)
            + struct.pack(">I", len(png_bytes)) + png_bytes)


def retag(flac_path, tags, art):
    """Rewrite a FLAC keeping STREAMINFO, replacing the rest of the metadata."""
    with open(flac_path, "rb") as f:
        data = f.read()
    assert data[:4] == b"fLaC", "not a FLAC file"

    pos = 4
    streaminfo = None
    while True:
        header = data[pos:pos + 4]
        is_last = bool(header[0] & 0x80)
        kind = header[0] & 0x7F
        length = int.from_bytes(header[1:4], "big")
        if kind == 0:
            streaminfo = data[pos + 4:pos + 4 + length]
        pos += 4 + length
        if is_last:
            break

    rebuilt = (b"fLaC"
               + block(0, streaminfo)
               + block(4, vorbis_comment(tags))
               + block(6, picture(art), last=True)
               + data[pos:])
    with open(flac_path, "wb") as f:
        f.write(rebuilt)


# --------------------------------------------------------------- main

def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "demo-library"
    os.makedirs(root, exist_ok=True)
    made = 0

    for album in ALBUMS:
        art = cover_art(album["hue"])
        folder = os.path.join(root, album["artist"], album["album"])
        os.makedirs(folder, exist_ok=True)

        for number, (title, freqs, seconds) in enumerate(album["tracks"], start=1):
            out = os.path.join(folder, f"{number:02d} {title}.flac")
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
                wav_path = tmp.name
            try:
                wav(wav_path, freqs, seconds)
                subprocess.run(
                    # afconvert picks the FLAC data format itself; passing an
                    # explicit -d here fails with 'fmt?'.
                    ["afconvert", "-f", "flac", wav_path, out],
                    check=True, capture_output=True,
                )
                retag(out, [
                    ("TITLE", title),
                    ("ARTIST", album["artist"]),
                    ("ALBUMARTIST", album["artist"]),
                    ("ALBUM", album["album"]),
                    ("DATE", album["year"]),
                    ("TRACKNUMBER", str(number)),
                    ("GENRE", "Demo"),
                ], art)
                made += 1
                print(f"  {out}")
            finally:
                os.unlink(wav_path)

    print(f"\n{made} demo tracks in {root}/")


if __name__ == "__main__":
    main()
