#!/usr/bin/env python3
"""固定 metadata 统一配置的严格解析与拦截行为组合契约。"""

from dataclasses import dataclass


@dataclass(frozen=True)
class InterceptPlan:
    bootconfig_injection: bool
    selinux_transition: bool
    vbmeta_patch: bool


def parse_config(text: str) -> tuple[bool, bool]:
    values: dict[str, bool] = {}
    for token in text.split():
        key, separator, value = token.partition("=")
        if not separator or key not in {"selinux_intercept", "avb_intercept"}:
            raise ValueError("未知配置键")
        if key in values or value not in {"0", "1"}:
            raise ValueError("重复配置键或非法值")
        values[key] = value == "1"
    if values.keys() != {"selinux_intercept", "avb_intercept"}:
        raise ValueError("缺少配置键")
    return values["selinux_intercept"], values["avb_intercept"]


def intercept_plan(selinux: bool, avb: bool) -> InterceptPlan:
    return InterceptPlan(
        bootconfig_injection=selinux,
        selinux_transition=selinux,
        vbmeta_patch=avb,
    )


def effective_config(text: str | None) -> tuple[bool, bool]:
    if text is None:
        return True, True
    try:
        return parse_config(text)
    except ValueError:
        return False, False


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

    assert parse_config("avb_intercept=0 selinux_intercept=1") == (True, False)
    assert effective_config(None) == (True, True)
    for invalid in (
        "",
        "selinux_intercept=1",
        "selinux_intercept=1 avb_intercept=2",
        "selinux_intercept=1 avb_intercept=0 unknown=1",
        "selinux_intercept=1 selinux_intercept=0 avb_intercept=1",
    ):
        try:
            parse_config(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError(f"无效配置被接受：{invalid!r}")
        assert effective_config(invalid) == (False, False)

    print("metadata 统一配置与拦截矩阵测试通过")


if __name__ == "__main__":
    main()
