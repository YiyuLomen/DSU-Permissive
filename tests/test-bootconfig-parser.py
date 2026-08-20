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


def bootconfig_view(
    original: str,
    *,
    phase: str,
    dsu_active: bool,
    avb_intercept: bool,
    avb_enforced: bool,
    selinux_intercept: bool,
) -> str:
    if (
        phase == "wait_system_init"
        and dsu_active
        and avb_intercept
        and not avb_enforced
    ):
        return 'androidboot.verifiedbootstate = "orange"\n' + original
    if phase == "selinux_setup" and dsu_active and selinux_intercept:
        return 'androidboot.selinux = "permissive"\n' + original
    return original


def main() -> None:
    original = (
        'androidboot.verifiedbootstate = "green"\n'
        'androidboot.selinux = "enforcing"\n'
        'androidboot.hardware = "test"\n'
    )
    first_stage_view = bootconfig_view(
        original,
        phase="wait_system_init",
        dsu_active=True,
        avb_intercept=True,
        avb_enforced=False,
        selinux_intercept=True,
    )
    selinux_setup_view = bootconfig_view(
        original,
        phase="selinux_setup",
        dsu_active=True,
        avb_intercept=True,
        avb_enforced=False,
        selinux_intercept=True,
    )

    # AVB 复验窗口必须先读取临时 orange，重复键仍由 fs_mgr 取首项。
    assert get_bootconfig(first_stage_view, "androidboot.verifiedbootstate") == "orange"
    assert get_bootconfig(first_stage_view, "androidboot.selinux") == "enforcing"

    # 进入 selinux_setup 后不再伪装 verifiedbootstate。
    assert get_bootconfig(selinux_setup_view, "androidboot.selinux") == "permissive"
    assert (
        get_bootconfig(selinux_setup_view, "androidboot.verifiedbootstate")
        == "green"
    )
    assert get_bootconfig(selinux_setup_view, "androidboot.hardware") == "test"
    assert get_bootconfig(selinux_setup_view, "missing") is None

    # avb_enforce、非 DSU 或关闭 AVB 拦截时，不可伪装为 orange。
    for gate in (
        {"dsu_active": False},
        {"avb_intercept": False},
        {"avb_enforced": True},
    ):
        arguments = {
            "dsu_active": True,
            "avb_intercept": True,
            "avb_enforced": False,
            "selinux_intercept": True,
        }
        arguments.update(gate)
        view = bootconfig_view(
            original,
            phase="wait_system_init",
            **arguments,
        )
        assert get_bootconfig(view, "androidboot.verifiedbootstate") == "green"

    # second-stage 注销代理后，所有键都恢复为原始 bootconfig 视图。
    assert get_bootconfig(original, "androidboot.selinux") == "enforcing"
    assert get_bootconfig(original, "androidboot.verifiedbootstate") == "green"
    print("bootconfig 首项优先契约测试通过")


if __name__ == "__main__":
    main()
