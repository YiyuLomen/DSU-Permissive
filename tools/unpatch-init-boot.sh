#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "用法：$0 --input <已补丁 boot/init_boot 镜像.img> --output <还原镜像.img> [--magiskboot <路径>]" >&2
}

metadata_value() {
    local key=$1
    local file=$2
    awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2) }' "$file"
}

input=""
output=""
magiskboot_bin="${MAGISKBOOT:-magiskboot}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) input="${2:-}"; shift 2 ;;
        --output) output="${2:-}"; shift 2 ;;
        --magiskboot) magiskboot_bin="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "错误：未知参数 $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "$input" || -z "$output" ]]; then
    usage
    exit 2
fi

input=$(realpath -e -- "$input")
output_parent=$(realpath -e -- "$(dirname -- "$output")")
output="$output_parent/$(basename -- "$output")"
magiskboot_bin=$(command -v -- "$magiskboot_bin")

if [[ "$input" == "$output" ]]; then
    echo "错误：输出路径不得与输入镜像相同" >&2
    exit 1
fi
if [[ -e "$output" ]]; then
    echo "错误：输出文件已存在，拒绝覆盖：$output" >&2
    exit 1
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dsu-permissive-unpatch.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p "$work_dir/image" "$work_dir/extract" "$work_dir/verify"

cd "$work_dir/image"
if ! "$magiskboot_bin" unpack "$input"; then
    echo "错误：magiskboot 无法解包输入镜像" >&2
    exit 1
fi
if [[ ! -f ramdisk.cpio ]]; then
    echo "错误：输入镜像不含 ramdisk.cpio" >&2
    exit 1
fi
for entry in init init.next dsu_permissive.ko dsu_permissive.meta; do
    if ! "$magiskboot_bin" cpio ramdisk.cpio "exists $entry"; then
        echo "错误：缺少 DSU-Permissive 条目 /$entry" >&2
        exit 1
    fi
done

"$magiskboot_bin" cpio ramdisk.cpio \
    "extract init ../extract/current-loader" \
    "extract init.next ../extract/original-init" \
    "extract dsu_permissive.ko ../extract/current-module" \
    "extract dsu_permissive.meta ../extract/metadata"

if [[ "$(metadata_value format "$work_dir/extract/metadata")" != "1" ||
      "$(metadata_value project "$work_dir/extract/metadata")" != "DSU-Permissive" ]]; then
    echo "错误：补丁元数据格式不受支持" >&2
    exit 1
fi

expected_original=$(metadata_value original_init_sha256 "$work_dir/extract/metadata")
expected_loader=$(metadata_value loader_sha256 "$work_dir/extract/metadata")
expected_module=$(metadata_value module_sha256 "$work_dir/extract/metadata")
actual_original=$(sha256sum "$work_dir/extract/original-init" | awk '{print $1}')
actual_loader=$(sha256sum "$work_dir/extract/current-loader" | awk '{print $1}')
actual_module=$(sha256sum "$work_dir/extract/current-module" | awk '{print $1}')
if [[ -z "$expected_original" || "$actual_original" != "$expected_original" ||
      "$actual_loader" != "$expected_loader" || "$actual_module" != "$expected_module" ]]; then
    echo "错误：补丁内容已被修改，拒绝进行可能破坏现有 init 链的还原" >&2
    exit 1
fi

"$magiskboot_bin" cpio ramdisk.cpio \
    "rm init" \
    "rm dsu_permissive.ko" \
    "rm dsu_permissive.meta" \
    "mv init.next init"
"$magiskboot_bin" repack "$input" "$work_dir/candidate.img"

cd "$work_dir/verify"
if ! "$magiskboot_bin" unpack "$work_dir/candidate.img" >/dev/null; then
    echo "错误：还原候选镜像无法重新解包" >&2
    exit 1
fi
if ! "$magiskboot_bin" cpio ramdisk.cpio "exists init"; then
    echo "错误：还原候选镜像缺少 /init" >&2
    exit 1
fi
for entry in init.next dsu_permissive.ko dsu_permissive.meta; do
    if "$magiskboot_bin" cpio ramdisk.cpio "exists $entry" >/dev/null 2>&1; then
        echo "错误：还原候选镜像仍含 /$entry" >&2
        exit 1
    fi
done
"$magiskboot_bin" cpio ramdisk.cpio "extract init restored-init"
restored_sha256=$(sha256sum restored-init | awk '{print $1}')
if [[ "$restored_sha256" != "$expected_original" ]]; then
    echo "错误：还原后的 /init 哈希不一致" >&2
    exit 1
fi

install -m 0644 -- "$work_dir/candidate.img" "$output"
echo "完成：已生成还原镜像 $output"
echo "原输入镜像未被修改：$input"
