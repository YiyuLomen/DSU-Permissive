#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "用法：$0 --input <已补丁 boot/init_boot 镜像.img> [--magiskboot <路径>]" >&2
}

metadata_value() {
    local key=$1
    local file=$2
    local count

    count=$(grep -c "^${key}=" "$file" || true)
    [[ "$count" == "1" ]] || return 1
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2) }' "$file"
}

input=""
magiskboot_bin="${MAGISKBOOT:-magiskboot}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) input="${2:-}"; shift 2 ;;
        --magiskboot) magiskboot_bin="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "错误：未知参数 $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$input" ]]; then
    usage
    exit 2
fi

input=$(realpath -e -- "$input")
magiskboot_bin=$(command -v -- "$magiskboot_bin")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dsu-permissive-verify.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p "$work_dir/image" "$work_dir/extract"

cd "$work_dir/image"
if ! "$magiskboot_bin" unpack "$input" >/dev/null; then
    echo "错误：magiskboot 无法解包镜像" >&2
    exit 1
fi
if [[ ! -f ramdisk.cpio ]]; then
    echo "错误：镜像不含 ramdisk.cpio" >&2
    exit 1
fi
for entry in init init.next dsu_permissive.ko dsu_permissive.meta; do
    if ! "$magiskboot_bin" cpio ramdisk.cpio "exists $entry"; then
        echo "错误：缺少 /$entry" >&2
        exit 1
    fi
done

"$magiskboot_bin" cpio ramdisk.cpio \
    "extract init ../extract/current-loader" \
    "extract init.next ../extract/original-init" \
    "extract dsu_permissive.ko ../extract/current-module" \
    "extract dsu_permissive.meta ../extract/metadata"

format=$(metadata_value format "$work_dir/extract/metadata") || format=""
project=$(metadata_value project "$work_dir/extract/metadata") || project=""
if [[ ( "$format" != "1" && "$format" != "2" && "$format" != "3" ) ||
      "$project" != "DSU-Permissive" ]]; then
    echo "错误：补丁元数据无效" >&2
    exit 1
fi

expected_original=$(metadata_value original_init_sha256 "$work_dir/extract/metadata") || expected_original=""
expected_loader=$(metadata_value loader_sha256 "$work_dir/extract/metadata") || expected_loader=""
expected_module=$(metadata_value module_sha256 "$work_dir/extract/metadata") || expected_module=""
actual_original=$(sha256sum "$work_dir/extract/original-init" | awk '{print $1}')
actual_loader=$(sha256sum "$work_dir/extract/current-loader" | awk '{print $1}')
actual_module=$(sha256sum "$work_dir/extract/current-module" | awk '{print $1}')
if [[ -z "$expected_original" || "$actual_original" != "$expected_original" ||
      "$actual_loader" != "$expected_loader" || "$actual_module" != "$expected_module" ]]; then
    echo "错误：镜像条目与补丁元数据哈希不一致" >&2
    exit 1
fi

case "$format" in
    1)
        if "$magiskboot_bin" cpio ramdisk.cpio "exists dsu_permissive.conf" \
            >/dev/null 2>&1; then
            echo "错误：format=1 镜像不应包含 /dsu_permissive.conf" >&2
            exit 1
        fi
        config_status="默认参数：SELinux 拦截=1，AVB 拦截=1"
        ;;
    2|3)
        if ! "$magiskboot_bin" cpio ramdisk.cpio \
            "exists dsu_permissive.conf" >/dev/null 2>&1; then
            echo "错误：format=$format 镜像缺少 /dsu_permissive.conf" >&2
            exit 1
        fi
        "$magiskboot_bin" cpio ramdisk.cpio \
            "extract dsu_permissive.conf ../extract/config"
        if [[ "$format" == "2" ]]; then
            expected_config=$(metadata_value config_sha256 "$work_dir/extract/metadata") || expected_config=""
            actual_config=$(sha256sum "$work_dir/extract/config" | awk '{print $1}')
            if [[ -z "$expected_config" || "$actual_config" != "$expected_config" ]]; then
                echo "错误：内嵌配置与补丁元数据哈希不一致" >&2
                exit 1
            fi
        fi
        config_selinux=$(awk -F= '$1 == "selinux_intercept" { print $2 }' \
            "$work_dir/extract/config")
        config_avb=$(awk -F= '$1 == "avb_intercept" { print $2 }' \
            "$work_dir/extract/config")
        if [[ "$config_selinux" != "0" && "$config_selinux" != "1" ]] ||
           [[ "$config_avb" != "0" && "$config_avb" != "1" ]]; then
            echo "错误：内嵌配置内容无效" >&2
            exit 1
        fi
        printf 'selinux_intercept=%s\navb_intercept=%s\n' \
            "$config_selinux" "$config_avb" > "$work_dir/extract/expected-config"
        if ! cmp -s "$work_dir/extract/config" \
            "$work_dir/extract/expected-config"; then
            echo "错误：内嵌配置必须为严格的两行格式" >&2
            exit 1
        fi
        config_status=$(tr '\n' ' ' < "$work_dir/extract/config")
        ;;
esac

if "$magiskboot_bin" cpio ramdisk.cpio "exists kernelsu.ko" &&
   "$magiskboot_bin" cpio ramdisk.cpio "exists init.real"; then
    chain="dsuinit → KernelSU ksuinit → /init.real"
else
    chain="dsuinit → 原有 /init.next"
fi

echo "验证通过：$input"
echo "init 链：$chain"
echo "原 init SHA-256：$actual_original"
echo "内嵌开关：$config_status"
