"""Decode the filter's compressed ^GFA output and compare it to its uncompressed output.

usage: python3 test/roundtrip.py build/rastertorp425 build/test.ras
"""
import re
import subprocess
import sys

filt, ras = sys.argv[1], sys.argv[2]


def run(options):
    out = subprocess.run([filt, "1", "u", "t", "1", options, ras], capture_output=True, check=True)
    return out.stdout.decode()


def fields(zpl):
    return [(int(m[1]), int(m[2]), m[3]) for m in re.finditer(r"\^GFA,\d+,(\d+),(\d+),(.*?)\^FS", zpl, re.S)]


def count(c):
    if "G" <= c <= "Y":
        return ord(c) - ord("G") + 1
    if "g" <= c <= "z":
        return (ord(c) - ord("g") + 1) * 20
    return 0


def decode(data, bytes_per_row):
    width = bytes_per_row * 2
    rows, cur, prev, n = [], "", None, 0
    for ch in data:
        if ch in "\r\n":
            continue
        if count(ch):
            n += count(ch)
            continue
        if ch == ":":
            rows.append(prev)
            continue
        if ch == ",":
            cur += "0" * (width - len(cur))
        elif ch == "!":
            cur += "F" * (width - len(cur))
        else:
            cur += ch * (n or 1)
            n = 0
        if len(cur) == width:
            rows.append(cur)
            prev, cur = cur, ""
    return "".join(rows)


for opts in ("", "Dither=FloydSteinberg", "Rotate180=True Threshold=64"):
    packed = fields(run(opts))
    plain = fields(run(opts + " Compression=None"))
    assert packed and len(packed) == len(plain), "page count mismatch"
    for (total, bpr, a), (_, _, b) in zip(packed, plain):
        assert len(b) == total * 2, "uncompressed size mismatch"
        assert decode(a, bpr) == b, f"compressed output differs ({opts or 'defaults'})"
    ratio = sum(len(p[2]) for p in packed) / sum(len(p[2]) for p in plain)
    print(f"ok  {opts or 'defaults':32} {len(packed)} page(s), compressed to {ratio:.1%}")
