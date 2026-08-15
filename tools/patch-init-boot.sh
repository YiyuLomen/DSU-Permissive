#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "用法：$0 --input <boot.img|init_boot.img> --output <新镜像.img> --loader <dsuinit> --module <dsu_permissive.ko> [--magiskboot <路径>]" >&2
}

input=""
output=""
loader=""
module=""
magiskboot_bin="${MAGISKBOOT:-magiskboot}"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) input="${2:-}"; shift 2 ;;
        --output) output="${2:-}"; shift 2 ;;
        --loader) loader="${2:-}"; shift 2 ;;
        --module) module="${2:-}"; shift 2 ;;
        --magiskboot) magiskboot_bin="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "错误：未知参数 $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$input" || -z "$output" || -z "$loader" || -z "$module" ]]; then
    usage
    exit 2
fi

input=$(realpath -e -- "$input")
loader=$(realpath -e -- "$loader")
module=$(realpath -e -- "$module")
output_parent=$(realpath -e -- "$(dirname -- "$output")")
output="$output_parent/$(basename -- "$output")"
magiskboot_bin=$(command -v -- "$magiskboot_bin")
"$script_dir/verify-artifacts.sh" --loader "$loader" --module "$module" >/dev/null

if [[ "$input" == "$output" ]]; then
    echo "错误：输出路径不得与输入镜像相同" >&2
    exit 1
fi
if [[ -e "$output" ]]; then
    echo "错误：输出文件已存在，拒绝覆盖：$output" >&2
    exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dsu-permissive-patch.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p "$work_dir/image" "$work_dir/assets" "$work_dir/extract"
cp -- "$loader" "$work_dir/assets/dsuinit"
cp -- "$module" "$work_dir/assets/dsu_permissive.ko"

cd "$work_dir/image"
if ! "$magiskboot_bin" unpack "$input"; then
    echo "错误：magiskboot 无法解包输入镜像" >&2
    exit 1
fi
if [[ ! -f ramdisk.cpio ]]; then
    echo "错误：输入镜像不含 ramdisk.cpio" >&2
    exit 1
fi
if ! "$magiskboot_bin" cpio ramdisk.cpio "exists init"; then
    echo "错误：ramdisk 中不存在 /init" >&2
    exit 1
fi
for entry in init.next dsu_permissive.ko dsu_permissive.meta; do
    if "$magiskboot_bin" cpio ramdisk.cpio "exists $entry" >/dev/null 2>&1; then
        echo "错误：ramdisk 已存在 /$entry，拒绝覆盖" >&2
        exit 1
    fi
done

"$magiskboot_bin" cpio ramdisk.cpio "extract init ../extract/original-init"
original_init_sha256=$(sha256sum "$work_dir/extract/original-init" | awk '{print $1}')
loader_sha256=$(sha256sum "$work_dir/assets/dsuinit" | awk '{print $1}')
module_sha256=$(sha256sum "$work_dir/assets/dsu_permissive.ko" | awk '{print $1}')
{
    printf 'format=1\n'
    printf 'project=DSU-Permissive\n'
    printf 'original_init_sha256=%s\n' "$original_init_sha256"
    printf 'loader_sha256=%s\n' "$loader_sha256"
    printf 'module_sha256=%s\n' "$module_sha256"
} > "$work_dir/assets/dsu_permissive.meta"

"$magiskboot_bin" cpio ramdisk.cpio \
    "mv init init.next" \
    "add 0755 init ../assets/dsuinit" \
    "add 0644 dsu_permissive.ko ../assets/dsu_permissive.ko" \
    "add 0644 dsu_permissive.meta ../assets/dsu_permissive.meta"

"$magiskboot_bin" repack "$input" "$work_dir/candidate.img"
"$script_dir/verify-init-boot.sh" --input "$work_dir/candidate.img" \
    --magiskboot "$magiskboot_bin" >/dev/null
install -m 0644 -- "$work_dir/candidate.img" "$output"

echo "完成：已生成补丁镜像 $output"
echo "原输入镜像未被修改：$input"
