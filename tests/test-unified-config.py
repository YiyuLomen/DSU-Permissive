#!/usr/bin/env python3
"""固定 init_boot 内嵌配置的严格解析与拦截行为组合契约。"""

from dataclasses import dataclass


@dataclass(frozen=True)
class InterceptPlan:
    bootconfig_injection: bool
    selinux_transition: bool
    vbmeta_patch: bool


def parse_config(text: str) -> tuple[bool, bool]:
    if text.endswith("\n"):
        text = text[:-1]
    prefix = "selinux_intercept="
    separator = "\navb_intercept="
    if not text.startswith(prefix):
        raise ValueError("SELinux 配置必须位于首行")
    remainder = text[len(prefix) :]
    selinux, marker, avb = remainder.partition(separator)
    if marker != separator or selinux not in {"0", "1"} or avb not in {"0", "1"}:
        raise ValueError("配置格式或值无效")
    return selinux == "1", avb == "1"


def intercept_plan(selinux: bool, avb: bool) -> InterceptPlan:
    return InterceptPlan(
        bootconfig_injection=selinux,
        selinux_transition=selinux,
        vbmeta_patch=avb,
    )


def main() -> None:
    for selinux in (False, True):
        for avb in (False, True):
            parsed = parse_config(
                f"selinux_intercept={int(selinux)}\n"
                f"avb_intercept={int(avb)}\n"
            )
            assert parsed == (selinux, avb)
            plan = intercept_plan(*parsed)
            assert plan.bootconfig_injection is selinux
            assert plan.selinux_transition is selinux
            assert plan.vbmeta_patch is avb

    for invalid in (
        "",
        "selinux_intercept=1",
        "selinux_intercept=1 avb_intercept=2",
        "selinux_intercept=1 avb_intercept=0 unknown=1",
        "selinux_intercept=1 selinux_intercept=0 avb_intercept=1",
        "avb_intercept=0\nselinux_intercept=1",
        "selinux_intercept=1\n\navb_intercept=0",
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
