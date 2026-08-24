#!/usr/bin/env python3
"""固定 DSU device-mapper AVB bypass 的协议、容量与门控契约。"""

from dataclasses import dataclass
from pathlib import Path


@dataclass
class GsiDevice:
    name: str
    encoded_dev: int
    sectors: int = 0

    @property
    def major(self) -> int:
        return huge_decode_dev(self.encoded_dev)[0]

    @property
    def minor(self) -> int:
        return huge_decode_dev(self.encoded_dev)[1]


def huge_encode_dev(major: int, minor: int) -> int:
    """Linux huge_encode_dev(), which dm_ioctl.dev returns to userspace."""
    return (minor & 0xFF) | (major << 8) | ((minor & ~0xFF) << 12)


def huge_decode_dev(encoded: int) -> tuple[int, int]:
    """Linux huge_decode_dev(), required before MAJOR/MINOR extraction."""
    major = (encoded & 0xFFF00) >> 8
    minor = (encoded & 0xFF) | ((encoded >> 12) & 0xFFF00)
    return major, minor


def is_dsu_image_name(name: str) -> bool:
    return name.endswith("_gsi") and name != "userdata_gsi"


def data_device(params: str) -> str:
    fields = params.split()
    assert len(fields) >= 2
    return fields[1]


def matches(token: str, device: GsiDevice) -> bool:
    return token in {
        f"/dev/block/dm-{device.minor}",
        f"/dev/mapper/{device.name}",
        f"/dev/block/mapper/{device.name}",
        f"{device.major}:{device.minor}",
    }


def rewrite(
    target_type: str,
    params: str,
    start: int,
    length: int,
    devices: list[GsiDevice],
    *,
    pid: int = 1,
    phase: str = "wait_system_init",
    dsu_active: bool = True,
    avb_enforced: bool = False,
    avb_intercept: bool = True,
) -> tuple[str, str, int]:
    if (
        pid != 1
        or phase != "wait_system_init"
        or not dsu_active
        or avb_enforced
        or not avb_intercept
        or target_type != "verity"
        or start != 0
    ):
        return target_type, params, length
    token = data_device(params)
    for device in devices:
        if device.sectors and matches(token, device):
            return "linear", f"{token} 0", device.sectors
    return target_type, params, length


def main() -> None:
    # DM_DEV_CREATE 的 dm_ioctl.dev 是 huge_encode_dev()，不能直接作 dev_t。
    system = GsiDevice(
        "system_gsi", huge_encode_dev(254, 16), sectors=3_659_624
    )
    vendor = GsiDevice(
        "vendor_gsi", huge_encode_dev(254, 17), sectors=1_024_000
    )
    devices = [system, vendor]
    assert system.encoded_dev == 0xFE10
    assert (system.major, system.minor) == (254, 16)
    assert (vendor.major, vendor.minor) == (254, 17)

    source = (
        Path(__file__).resolve().parents[1] / "module" / "dm_ioctl_proxy.c"
    ).read_text(encoding="utf-8")
    assert "dev_t decoded = huge_decode_dev(device->dev);" in source
    assert "MAJOR((dev_t)device->dev)" not in source
    assert "已注册 first-stage device-mapper dm_ctl_ioctl kprobe" in source
    assert "return _IOC_TYPE(command) == DM_IOCTL;" in source
    assert "is_device_mapper_control" not in source
    assert ".symbol_name = \"dm_ctl_ioctl\"" in source
    assert "find_gsi_device_by_encoded_dev_locked" in source
    assert ".symbol_name = \"table_load\"" in source
    assert "static int on_table_load" in source
    assert "registers->regs[2]" in source
    assert "record_gsi_table_size(header, table_size);" in source
    assert "rewrite_verity_table(header, table_size);" in source
    assert "parameter_offset = target_offset + sizeof(*target);" in source
    assert "跳过 first-stage verity 改写" in source
    assert "#define DM_IOCTL_HEADER_SIZE offsetof(struct dm_ioctl, data)" in source
    assert "copy_from_user(header, argument, DM_IOCTL_HEADER_SIZE)" in source
    assert "DM_TABLE_MAX_TARGETS" not in source
    assert is_dsu_image_name(system.name)
    assert is_dsu_image_name(vendor.name)
    assert not is_dsu_image_name("userdata_gsi")

    built_in = (
        "1 /dev/block/dm-16 /dev/block/dm-16 4096 4096 "
        "2034643 2034643 sha256 deadbeef cafe"
    )
    target_type, params, length = rewrite(
        "verity", built_in, 0, 16_277_144, devices
    )
    assert target_type == "linear"
    assert params == "/dev/block/dm-16 0"
    assert length == system.sectors

    # 三种映射名和 major:minor 表示均可命中，不依赖固定 dm-16。
    target_type, params, length = rewrite(
        "verity", "1 /dev/mapper/vendor_gsi x 4096", 0, 99, devices
    )
    assert (target_type, params, length) == (
        "linear",
        "/dev/mapper/vendor_gsi 0",
        vendor.sectors,
    )
    target_type, params, length = rewrite(
        "verity", "1 /dev/block/mapper/vendor_gsi x 4096", 0, 99, devices
    )
    assert (target_type, params, length) == (
        "linear",
        "/dev/block/mapper/vendor_gsi 0",
        vendor.sectors,
    )
    target_type, params, length = rewrite(
        "verity", "1 254:16 x 4096", 0, 99, devices
    )
    assert (target_type, params, length) == ("linear", "254:16 0", system.sectors)

    # 非 GSI backing、非 PID 1、非 first-stage、avb_enforce 与关闭开关都透传。
    for gate in (
        {"params": "1 /dev/block/dm-7 /dev/block/dm-7 4096"},
        {"pid": 2},
        {"phase": "selinux_setup"},
        {"dsu_active": False},
        {"avb_enforced": True},
        {"avb_intercept": False},
        {"start": 8},
    ):
        args = {"target_type": "verity", "params": built_in, "start": 0, "length": 42}
        args.update(gate)
        assert rewrite(devices=devices, **args) == (
            args["target_type"],
            args["params"],
            args["length"],
        )

    print("DSU device-mapper AVB bypass 契约测试通过")


if __name__ == "__main__":
    main()
