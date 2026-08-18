#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dsu-flasher-generator.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

targets=(
    android12-5.10
    android13-5.10
    android13-5.15
    android14-5.15
    android14-6.1
    android15-6.6
    android16-6.12
)

kernel_branch_for_target() {
    case "$1" in
        android12-5.10) echo 5.10 ;;
        android13-5.10) echo 5.10 ;;
        android13-5.15) echo 5.15 ;;
        android14-5.15) echo 5.15 ;;
        android14-6.1) echo 6.1 ;;
        android15-6.6) echo 6.6 ;;
        android16-6.12) echo 6.12 ;;
        *) return 1 ;;
    esac
}

asset_name_for_target() {
    printf 'module_%s\n' "${1//[-.]/_}"
}

make -C "$root_dir/loader" clean all >/dev/null
mkdir -p "$work_dir/modules"
for target in "${targets[@]}"; do
    branch=$(kernel_branch_for_target "$target")
    module_dir="$work_dir/modules/$target"
    mkdir -p "$module_dir"
    vermagic="vermagic=$branch.0-$target-test SMP preempt mod_unload aarch64"
    clang --target=aarch64-linux-gnu \
        "-DTEST_VERMAGIC=\"$vermagic\"" \
        "-DTEST_DDK_TARGET=\"$target\"" \
        -c "$root_dir/tests/fake_module.S" \
        -o "$module_dir/dsu_permissive.ko"
done

auto_output="$work_dir/dsu-permissive-auto-flasher.sh"
"$root_dir/tools/generate-android-flasher.sh" \
    --target auto \
    --module-dir "$work_dir/modules" \
    --loader "$root_dir/loader/dsuinit" \
    --magiskboot "$root_dir/loader/dsuinit" \
    --output "$auto_output" >/dev/null

[[ -x "$auto_output" ]]
sh -n "$auto_output"
auto_verify=$(sh "$auto_output" --verify-bundle)
grep -q '自解包资源校验通过' <<<"$auto_verify"
grep -q 'bundle mode：auto' <<<"$auto_verify"
grep -q '是否在完成备份和修补后直接刷入目标分区' "$auto_output"
if grep -Eq 'ro\.boot\.(vbmeta\.device_state|flash\.locked)|--allow-locked|--allow-dsu|/metadata/gsi/dsu/booted' \
    "$auto_output"; then
    echo "错误：生成的刷写脚本仍获取或判断设备解锁/DSU 运行状态" >&2
    exit 1
fi
if command -v script >/dev/null 2>&1; then
    set +e
    interactive_output=$(
        printf '\n\nn\n' |
            script -q -e -c \
                "sh '$auto_output' --partition '$work_dir/not-a-block-device'" \
                /dev/null 2>&1
    )
    interactive_status=$?
    set -e
    [[ "$interactive_status" -ne 0 ]]
    grep -q '是否在完成备份和修补后直接刷入目标分区' \
        <<<"$interactive_output"
    grep -q 'SELinux 拦截（0=关闭，1=开启，默认 1）' \
        <<<"$interactive_output"
    grep -q 'AVB 拦截（0=关闭，1=开启，默认 1）' \
        <<<"$interactive_output"
    grep -q '继续只生成备份和补丁镜像，不刷入目标分区' \
        <<<"$interactive_output"
fi
for target in "${targets[@]}"; do
    grep -q "$target" <<<"$auto_verify"
    asset=$(asset_name_for_target "$target")
    [[ "$(grep -c "^__DSU_PAYLOAD_${asset}_BEGIN__$" "$auto_output")" -eq 1 ]]
    [[ "$(grep -c "^__DSU_PAYLOAD_${asset}_END__$" "$auto_output")" -eq 1 ]]
done

mkdir -p "$work_dir/fake-bin"
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/sh' \
    'case "${1:-}" in' \
    '    -m) printf "%s\\n" aarch64 ;;' \
    '    -r) printf "%s\\n" "${TEST_KERNEL_RELEASE:?}" ;;' \
    '    *) exit 2 ;;' \
    'esac' > "$work_dir/fake-bin/uname"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" 0' > "$work_dir/fake-bin/id"
chmod 0755 "$work_dir/fake-bin/uname" "$work_dir/fake-bin/id"

for target in "${targets[@]}"; do
    branch=$(kernel_branch_for_target "$target")
    kernel_release="$branch.123-$target-test"
    if selection_output=$(
        PATH="$work_dir/fake-bin:$PATH" \
        TEST_KERNEL_RELEASE="$kernel_release" \
        TMPDIR="$work_dir" \
        sh "$auto_output" \
            --partition "$work_dir/not-a-block-device" 2>&1
    ); then
        echo "错误：自动选择测试意外进入分区操作：$target" >&2
        exit 1
    fi
    grep -q "当前内核：$kernel_release" <<<"$selection_output"
    grep -q "自动选择 target：$target" <<<"$selection_output"
    grep -q '指定路径不是块设备' <<<"$selection_output"
done

for ambiguous_release in 5.10.123-vendor-test 5.15.123-vendor-test; do
    if ambiguous_output=$(
        PATH="$work_dir/fake-bin:$PATH" \
        TEST_KERNEL_RELEASE="$ambiguous_release" \
        TMPDIR="$work_dir" \
        sh "$auto_output" \
            --partition "$work_dir/not-a-block-device" 2>&1
    ); then
        echo "错误：自动选择器接受了无 Android KMI 世代的内核版本" >&2
        exit 1
    fi
    grep -q '无法从内核版本识别唯一 KMI target' <<<"$ambiguous_output"
    if grep -q '自动选择 target：' <<<"$ambiguous_output"; then
        echo "错误：歧义内核版本仍选择了 KO" >&2
        exit 1
    fi
done

if "$root_dir/tools/generate-android-flasher.sh" \
    --target android16-6.12 \
    --module-dir "$work_dir/modules" \
    --loader "$root_dir/loader/dsuinit" \
    --magiskboot "$root_dir/loader/dsuinit" \
    --output "$work_dir/single-target.sh" >/dev/null 2>&1; then
    echo "错误：生成器仍接受绑定单一 KMI 的 target" >&2
    exit 1
fi

echo "Android 全 KO 自动选择刷写脚本生成器测试通过"
