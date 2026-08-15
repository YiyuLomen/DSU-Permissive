#!/usr/bin/env python3
"""固定 first-stage vbmeta 返回视图的偏移、门控与只读契约。"""

from dataclasses import dataclass


AVB_MAGIC = b"AVB0"
AVB_HEADER_SIZE = 256
AVB_FLAGS_OFFSET = 120
AVB_VERIFICATION_DISABLED_OFFSET = AVB_FLAGS_OFFSET + 3
AVB_VERIFICATION_DISABLED_MASK = 0x02


@dataclass
class ProxyState:
    header_confirmed: bool = False
    header_rejected: bool = False


def contains(read_offset: int, read_size: int, target: int, size: int) -> bool:
    if read_offset < 0 or read_size <= 0 or read_offset > target:
        return False
    relative = target - read_offset
    return relative <= read_size and size <= read_size - relative


def proxy_read(
    disk: bytes,
    read_offset: int,
    read_size: int,
    state: ProxyState,
    *,
    phase: str = "wait_system_init",
    pid: int = 1,
    dsu_active: bool = True,
    avb_enforced: bool = False,
    target_device: bool = True,
) -> bytes:
    returned = bytearray(disk[read_offset : read_offset + read_size])
    if (
        phase != "wait_system_init"
        or pid != 1
        or not dsu_active
        or avb_enforced
        or not target_device
    ):
        return bytes(returned)

    if not state.header_confirmed and not state.header_rejected:
        if contains(read_offset, len(returned), 0, len(AVB_MAGIC)):
            relative = -read_offset
            if returned[relative : relative + len(AVB_MAGIC)] == AVB_MAGIC:
                state.header_confirmed = True
            else:
                state.header_rejected = True

    if state.header_confirmed and contains(
        read_offset, len(returned), AVB_VERIFICATION_DISABLED_OFFSET, 1
    ):
        relative = AVB_VERIFICATION_DISABLED_OFFSET - read_offset
        returned[relative] |= AVB_VERIFICATION_DISABLED_MASK
    return bytes(returned)


def make_vbmeta(flags: int) -> bytes:
    image = bytearray(AVB_HEADER_SIZE)
    image[: len(AVB_MAGIC)] = AVB_MAGIC
    image[AVB_FLAGS_OFFSET : AVB_FLAGS_OFFSET + 4] = flags.to_bytes(4, "big")
    return bytes(image)


def flags_from(data: bytes) -> int:
    return int.from_bytes(data[AVB_FLAGS_OFFSET : AVB_FLAGS_OFFSET + 4], "big")


def main() -> None:
    assert AVB_VERIFICATION_DISABLED_OFFSET == 123

    disk = make_vbmeta(0x80000001)
    patched = proxy_read(disk, 0, len(disk), ProxyState())
    assert flags_from(patched) == 0x80000003
    assert disk == make_vbmeta(0x80000001)

    already_disabled = make_vbmeta(0x00000002)
    assert (
        proxy_read(already_disabled, 0, len(already_disabled), ProxyState())
        == already_disabled
    )

    state = ProxyState()
    ranges = ((0, 119), (119, 2), (121, 2), (123, 1), (124, 132))
    pieces = [proxy_read(disk, start, size, state) for start, size in ranges]
    assert b"".join(pieces) == patched

    state = ProxyState(header_confirmed=True)
    for start, size in ((119, 2), (121, 2), (124, 1), (256, 0)):
        assert proxy_read(disk, start, size, state) == disk[start : start + size]

    bad_magic = bytearray(disk)
    bad_magic[:4] = b"NOPE"
    assert proxy_read(bytes(bad_magic), 0, len(bad_magic), ProxyState()) == bytes(
        bad_magic
    )

    for gate in (
        {"phase": "selinux_setup_armed"},
        {"pid": 2},
        {"dsu_active": False},
        {"avb_enforced": True},
        {"target_device": False},
    ):
        assert proxy_read(disk, 0, len(disk), ProxyState(), **gate) == disk

    state = ProxyState()
    assert proxy_read(disk, 0, 4, state, dsu_active=False) == disk[:4]
    assert proxy_read(disk, 0, len(disk), state, dsu_active=True) == patched

    print("AVB header 返回视图契约测试通过")


if __name__ == "__main__":
    main()
