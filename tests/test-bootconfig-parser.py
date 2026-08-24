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
    vbmeta_patched: bool = True,
    selinux_intercept: bool,
) -> str:
    if (
        phase == "wait_system_init"
        and dsu_active
        and avb_intercept
        and not avb_enforced
    ):
        return 'androidboot.verifiedbootstate = "orange"\n' + original
    if phase == "selinux_setup" and dsu_active:
        prefix = ""
        if avb_intercept and not avb_enforced and vbmeta_patched:
            prefix += 'androidboot.veritymode = "disabled"\n'
        if selinux_intercept:
            prefix += 'androidboot.selinux = "permissive"\n'
        return prefix + original
    return original


def main() -> None:
    original = (
        'androidboot.verifiedbootstate = "green"\n'
        'androidboot.veritymode = "eio"\n'
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
    assert get_bootconfig(first_stage_view, "androidboot.veritymode") == "eio"
    assert get_bootconfig(first_stage_view, "androidboot.selinux") == "enforcing"

    # 进入 selinux_setup 后不再伪装 verifiedbootstate，但 AVB disabled
    # 视图必须同步为 veritymode=disabled，避免 vivo vfcheck 进入 eio 探测。
    assert get_bootconfig(selinux_setup_view, "androidboot.selinux") == "permissive"
    assert get_bootconfig(selinux_setup_view, "androidboot.veritymode") == "disabled"
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

    # selinux_setup 的 AVB 与 SELinux 注入仍由两个开关独立控制。
    combinations = (
        (True, True, "disabled", "permissive"),
        (True, False, "disabled", "enforcing"),
        (False, True, "eio", "permissive"),
        (False, False, "eio", "enforcing"),
    )
    for avb_intercept, selinux_intercept, veritymode, selinux in combinations:
        view = bootconfig_view(
            original,
            phase="selinux_setup",
            dsu_active=True,
            avb_intercept=avb_intercept,
            avb_enforced=False,
            selinux_intercept=selinux_intercept,
        )
        assert get_bootconfig(view, "androidboot.veritymode") == veritymode
        assert get_bootconfig(view, "androidboot.selinux") == selinux

    # avb_enforce 只关闭 AVB 状态同步，不影响单独启用的 SELinux 注入。
    enforced_view = bootconfig_view(
        original,
        phase="selinux_setup",
        dsu_active=True,
        avb_intercept=True,
        avb_enforced=True,
        selinux_intercept=True,
    )
    assert get_bootconfig(enforced_view, "androidboot.veritymode") == "eio"
    assert get_bootconfig(enforced_view, "androidboot.selinux") == "permissive"

    # 未命中 vbmeta 返回视图时不能仅凭配置伪报 disabled。
    missed_view = bootconfig_view(
        original,
        phase="selinux_setup",
        dsu_active=True,
        avb_intercept=True,
        avb_enforced=False,
        vbmeta_patched=False,
        selinux_intercept=True,
    )
    assert get_bootconfig(missed_view, "androidboot.veritymode") == "eio"
    assert get_bootconfig(missed_view, "androidboot.selinux") == "permissive"

    # second-stage 注销代理后，所有键都恢复为原始 bootconfig 视图。
    assert get_bootconfig(original, "androidboot.selinux") == "enforcing"
    assert get_bootconfig(original, "androidboot.veritymode") == "eio"
    assert get_bootconfig(original, "androidboot.verifiedbootstate") == "green"
    print("bootconfig 首项优先契约测试通过")


if __name__ == "__main__":
    main()
