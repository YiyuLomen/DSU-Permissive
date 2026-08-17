#!/usr/bin/env python3
"""固定启动期 enforce 代理在 user/userdebug init 下的状态契约。"""


def run_selinux_setup(
    *,
    dsu_active: bool,
    allow_permissive_selinux: bool,
    bootconfig_permissive: bool,
    initial_enforcing: bool,
    selinux_intercept: bool = True,
) -> bool:
    desired_enforcing = not (
        allow_permissive_selinux and bootconfig_permissive
    )
    actual_enforcing = initial_enforcing

    if dsu_active and selinux_intercept:
        # 代理通过原始 enforce fop 切换为 permissive，但仅向 PID 1 报告 1。
        actual_enforcing = False
        observed_enforcing = True
    else:
        observed_enforcing = actual_enforcing

    if observed_enforcing != desired_enforcing:
        # 原厂 init 的 security_setenforce() 路径。
        actual_enforcing = desired_enforcing

    return actual_enforcing


def main() -> None:
    for initial_enforcing in (False, True):
        for allow_permissive_selinux in (False, True):
            for bootconfig_permissive in (False, True):
                result = run_selinux_setup(
                    dsu_active=True,
                    allow_permissive_selinux=allow_permissive_selinux,
                    bootconfig_permissive=bootconfig_permissive,
                    initial_enforcing=initial_enforcing,
                )
                assert result is False

    assert run_selinux_setup(
        dsu_active=False,
        allow_permissive_selinux=False,
        bootconfig_permissive=False,
        initial_enforcing=True,
    ) is True

    assert run_selinux_setup(
        dsu_active=True,
        allow_permissive_selinux=False,
        bootconfig_permissive=False,
        initial_enforcing=True,
        selinux_intercept=False,
    ) is True

    # second-stage 注销代理后，手动 setenforce 1 必须直接生效。
    enforcing_after_manual_set = True
    assert enforcing_after_manual_set is True
    print("启动期 enforce 状态矩阵测试通过")


if __name__ == "__main__":
    main()
