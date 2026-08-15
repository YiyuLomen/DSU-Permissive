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
    original = (
        'androidboot.verifiedbootstate = "orange"\n'
        'androidboot.selinux = "enforcing"\n'
        'androidboot.hardware = "test"\n'
    )
    selinux_setup_view = 'androidboot.selinux = "permissive"\n' + original

    assert get_bootconfig(selinux_setup_view, "androidboot.selinux") == "permissive"
    assert (
        get_bootconfig(selinux_setup_view, "androidboot.verifiedbootstate")
        == "orange"
    )
    assert get_bootconfig(selinux_setup_view, "androidboot.hardware") == "test"
    assert get_bootconfig(selinux_setup_view, "missing") is None

    # second-stage 注销代理后，所有键都恢复为原始 bootconfig 视图。
    assert get_bootconfig(original, "androidboot.selinux") == "enforcing"
    assert get_bootconfig(original, "androidboot.verifiedbootstate") == "orange"
    print("bootconfig 首项优先契约测试通过")


if __name__ == "__main__":
    main()
