#!/usr/bin/env python3
"""生成仅用于主机端往返测试的最小 Android boot header v4 镜像。"""

from __future__ import annotations

import argparse
import pathlib
import struct


PAGE_SIZE = 4096
HEADER_SIZE = 1584


def pad(data: bytes) -> bytes:
    padding = (-len(data)) % PAGE_SIZE
    return data + bytes(padding)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--ramdisk", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    args = parser.parse_args()

    ramdisk = args.ramdisk.read_bytes()
    header = bytearray()
    header.extend(b"ANDROID!")
    header.extend(struct.pack("<IIII", 0, len(ramdisk), 0, HEADER_SIZE))
    header.extend(struct.pack("<IIII", 0, 0, 0, 0))
    header.extend(struct.pack("<I", 4))
    header.extend(bytes(1536))
    header.extend(struct.pack("<I", 0))
    if len(header) != HEADER_SIZE:
        raise RuntimeError(f"boot header 大小错误：{len(header)}")

    args.output.write_bytes(pad(bytes(header)) + pad(ramdisk))


if __name__ == "__main__":
    main()

