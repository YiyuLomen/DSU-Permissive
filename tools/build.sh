#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat >&2 <<'EOF'
用法：
  tools/build.sh
  tools/build.sh --target <DDK target>
  tools/build.sh --all
  tools/build.sh --list-targets
EOF
}

supported_targets=(
    android12-5.10
    android13-5.10
    android13-5.15
    android14-5.15
    android14-6.1
    android15-6.6
    android16-6.12
)

android_version_for_target() {
    case "$1" in
        android12-5.10) echo "Android 12" ;;
        android13-5.10) echo "Android 13 / 5.10" ;;
        android13-5.15) echo "Android 13" ;;
        android14-5.15) echo "Android 14 / 5.15" ;;
        android14-6.1) echo "Android 14" ;;
        android15-6.6) echo "Android 15" ;;
        android16-6.12) echo "Android 16 及以上" ;;
        *) return 1 ;;
    esac
}

is_supported_target() {
    local candidate=$1
    local target

    for target in "${supported_targets[@]}"; do
        if [[ "$candidate" == "$target" ]]; then
            return 0
        fi
    done
    return 1
}

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
targets=(android16-6.12)
build_all=0

case "${1:-}" in
    "") ;;
    --target)
        if [[ $# -ne 2 || -z "${2:-}" ]]; then
            usage
            exit 2
        fi
        targets=("$2")
        ;;
    --all)
        if [[ $# -ne 1 ]]; then
            usage
            exit 2
        fi
        targets=("${supported_targets[@]}")
        build_all=1
        ;;
    --list-targets)
        if [[ $# -ne 1 ]]; then
            usage
            exit 2
        fi
        for target in "${supported_targets[@]}"; do
            printf '%s\t%s\n' "$target" "$(android_version_for_target "$target")"
        done
        exit 0
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

for target in "${targets[@]}"; do
    if ! is_supported_target "$target"; then
        echo "错误：不支持 DDK target $target" >&2
        echo "可用 target：" >&2
        "$0" --list-targets >&2
        exit 2
    fi
done

ddk_bin="${DDK:-ddk}"
ddk_bin=$(command -v -- "$ddk_bin")

cd "$root_dir"
mkdir -p out/.build
for target in "${targets[@]}"; do
    echo "开始构建 $target（$(android_version_for_target "$target")）"
    "$ddk_bin" clean "$target"
    "$ddk_bin" build "$target" -- module "OUT_DIR=out/.build/$target" \
        "DSU_DDK_TARGET=$target" -j"$(nproc)"
    install -m 0644 -- "out/.build/$target/dsu_permissive.ko" \
        "out/dsu_permissive-$target.ko"
done

make -C loader clean all
mkdir -p out
cp -f loader/dsuinit out/dsuinit
cp -f tools/patch-init-boot-android.sh out/patch-init-boot-android.sh
cp -f tools/repatch-init-boot-config-android.sh \
    out/repatch-init-boot-config-android.sh
chmod 0755 out/patch-init-boot-android.sh \
    out/repatch-init-boot-config-android.sh

magiskboot_path=$("$root_dir/tools/fetch-static-magiskboot.sh")
cp -f "$magiskboot_path" out/magiskboot-arm64
chmod 0755 out/magiskboot-arm64

for target in "${targets[@]}"; do
    "$root_dir/tools/verify-artifacts.sh" \
        --loader "$root_dir/out/dsuinit" \
        --module "$root_dir/out/dsu_permissive-$target.ko" \
        --target "$target"
done

if [[ "$build_all" -eq 1 ]]; then
    universal_flasher="$root_dir/out/dsu-permissive-android-flasher.sh"
    rm -f -- "$universal_flasher"
    "$root_dir/tools/generate-android-flasher.sh" \
        --target auto \
        --module-dir "$root_dir/out" \
        --loader "$root_dir/out/dsuinit" \
        --magiskboot "$root_dir/out/magiskboot-arm64" \
        --output "$universal_flasher"
fi

echo "构建完成："
echo "  loader：$root_dir/out/dsuinit"
echo "  Android 修补脚本：$root_dir/out/patch-init-boot-android.sh"
echo "  Android 重修补配置脚本：$root_dir/out/repatch-init-boot-config-android.sh"
echo "  arm64 静态 magiskboot：$root_dir/out/magiskboot-arm64"
for target in "${targets[@]}"; do
    echo "  $target：$root_dir/out/dsu_permissive-$target.ko"
done
if [[ "$build_all" -eq 1 ]]; then
    echo "  全 KO 自动选择刷写脚本：$root_dir/out/dsu-permissive-android-flasher.sh"
fi
