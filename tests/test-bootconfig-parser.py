#!/usr/bin/env python3
"""固定 AOSP fs_mgr 对重复 bootconfig 键采用首项的契约。"""


def get_bootconfig(bootconfig: str, wanted: str) -> str | None:
    for line in bootconfig.splitlines():
        key, separator, value = line.partition("=")
        key = key.strip()
        if not key or key != wanted:
            continue
        if not separator:
            return ""
        return value.strip().removeprefix('"').removesuffix('"')
    return None


def main() -> None:
    content = (
        'androidboot.selinux = "permissive"\n'
        'androidboot.hardware = "test"\n'
        'androidboot.selinux = "enforcing"\n'
    )
    assert get_bootconfig(content, "androidboot.selinux") == "permissive"
    assert get_bootconfig(content, "androidboot.hardware") == "test"
    assert get_bootconfig(content, "missing") is None
    print("bootconfig 首项优先契约测试通过")


if __name__ == "__main__":
    main()

