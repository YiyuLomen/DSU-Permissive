#!/usr/bin/env python3
"""固定 init_boot 内嵌配置的严格解析与拦截行为组合契约。"""

from dataclasses import dataclass


@dataclass(frozen=True)
class InterceptPlan:
    bootconfig_injection: bool
    selinux_transition: bool
    vbmeta_patch: bool
    verity_table_spoof: bool


def parse_config(text: str) -> tuple[bool, bool, bool]:
    if text.endswith("\n"):
        text = text[:-1]
    prefix = "selinux_intercept="
    separator = "\navb_intercept="
    verity_separator = "\nverity_table_spoof="
    if not text.startswith(prefix):
        raise ValueError("SELinux 配置必须位于首行")
    remainder = text[len(prefix) :]
    selinux, marker, remainder = remainder.partition(separator)
    avb, verity_marker, verity_table_spoof = remainder.partition(verity_separator)
    if (
        marker != separator
        or verity_marker != verity_separator
        or selinux not in {"0", "1"}
        or avb not in {"0", "1"}
        or verity_table_spoof not in {"0", "1"}
    ):
        raise ValueError("配置格式或值无效")
    return selinux == "1", avb == "1", verity_table_spoof == "1"


def intercept_plan(selinux: bool, avb: bool, verity_table_spoof: bool) -> InterceptPlan:
    return InterceptPlan(
        bootconfig_injection=selinux,
        selinux_transition=selinux,
        vbmeta_patch=avb,
        verity_table_spoof=verity_table_spoof,
    )


def main() -> None:
    for selinux in (False, True):
        for avb in (False, True):
            for verity_table_spoof in (False, True):
                parsed = parse_config(
                    f"selinux_intercept={int(selinux)}\n"
                    f"avb_intercept={int(avb)}\n"
                    f"verity_table_spoof={int(verity_table_spoof)}\n"
                )
                assert parsed == (selinux, avb, verity_table_spoof)
                plan = intercept_plan(*parsed)
                assert plan.bootconfig_injection is selinux
                assert plan.selinux_transition is selinux
                assert plan.vbmeta_patch is avb
                assert plan.verity_table_spoof is verity_table_spoof

    for invalid in (
        "",
        "selinux_intercept=1",
        "selinux_intercept=1 avb_intercept=2",
        "selinux_intercept=1 avb_intercept=0 unknown=1",
        "selinux_intercept=1 selinux_intercept=0 avb_intercept=1",
        "avb_intercept=0\nselinux_intercept=1",
        "selinux_intercept=1\n\navb_intercept=0",
        "selinux_intercept=1\navb_intercept=1",
        "selinux_intercept=1\navb_intercept=1\nverity_table_spoof=2",
        "selinux_intercept=1\navb_intercept=1\nmetadata_error_log=2",
        "selinux_intercept=1\navb_intercept=1\nverity_table_spoof=0\nextra=1",
    ):
        try:
            parse_config(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError(f"无效配置被接受：{invalid!r}")

    print("init_boot 内嵌配置与拦截矩阵测试通过")


if __name__ == "__main__":
    main()
