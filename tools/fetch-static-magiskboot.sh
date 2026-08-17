#!/usr/bin/env bash
set -euo pipefail

MAGISK_VERSION="v30.7"
MAGISK_APK_NAME="Magisk-v30.7.apk"
MAGISK_APK_URL="https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk"
MAGISK_APK_SHA256="e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5"
MAGISKBOOT_APK_PATH="lib/arm64-v8a/libmagiskboot.so"
MAGISKBOOT_SHA256="d7440e2cd89899426e809554bf793baef9804ccbe5a52ce34a8b6242725d3c77"

usage() {
    cat >&2 <<'EOF'
用法：tools/fetch-static-magiskboot.sh [--output <路径>] [--force]

从官方 Magisk v30.7 APK 提取 arm64 静态 magiskboot，并校验固定 SHA-256、
ELF 架构、动态解释器和动态依赖。默认输出到项目 .cache 目录。
EOF
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

hash_file() {
    sha256sum "$1" | awk '{print $1}'
}

verify_magiskboot() {
    local binary=$1
    local actual_sha256
    local elf_header
    local program_headers
    local dynamic_section

    [[ -s "$binary" ]] || fail "magiskboot 文件不存在或为空：$binary"
    actual_sha256=$(hash_file "$binary")
    [[ "$actual_sha256" == "$MAGISKBOOT_SHA256" ]] ||
        fail "magiskboot SHA-256 不匹配：$actual_sha256"

    elf_header=$("$readelf_bin" -h "$binary")
    grep -q 'Class:.*ELF64' <<<"$elf_header" ||
        fail "magiskboot 不是 ELF64"
    grep -q 'Type:.*EXEC' <<<"$elf_header" ||
        fail "magiskboot 不是静态 ET_EXEC"
    grep -q 'Machine:.*AArch64' <<<"$elf_header" ||
        fail "magiskboot 不是 AArch64"

    program_headers=$("$readelf_bin" -l "$binary")
    if grep -Eq '(^|[[:space:]])(INTERP|DYNAMIC)([[:space:]]|$)' \
        <<<"$program_headers"; then
        fail "magiskboot 含动态解释器或动态段，不是完全静态产物"
    fi

    dynamic_section=$("$readelf_bin" -d "$binary" 2>/dev/null || true)
    if grep -q 'NEEDED' <<<"$dynamic_section"; then
        fail "magiskboot 含动态依赖"
    fi
}

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cache_dir="$root_dir/.cache/magiskboot/$MAGISK_VERSION"
output="$cache_dir/magiskboot"
force=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 && -n "${2:-}" ]] || { usage; exit 2; }
            output=$2
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "错误：未知参数 $1" >&2
            usage
            exit 2
            ;;
    esac
done

for command_name in curl unzip sha256sum awk grep mktemp install; do
    command -v -- "$command_name" >/dev/null 2>&1 ||
        fail "找不到依赖命令：$command_name"
done
if command -v llvm-readelf >/dev/null 2>&1; then
    readelf_bin=$(command -v llvm-readelf)
elif command -v readelf >/dev/null 2>&1; then
    readelf_bin=$(command -v readelf)
else
    fail "找不到 llvm-readelf/readelf"
fi

output_parent=$(dirname -- "$output")
mkdir -p -- "$output_parent" "$cache_dir"
output_parent=$(realpath -e -- "$output_parent")
output="$output_parent/$(basename -- "$output")"
apk_path="$cache_dir/$MAGISK_APK_NAME"

if [[ -e "$output" && "$force" -eq 0 ]]; then
    verify_magiskboot "$output"
    printf '%s\n' "$output"
    exit 0
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dsu-magiskboot.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT

if [[ ! -f "$apk_path" || "$(hash_file "$apk_path")" != "$MAGISK_APK_SHA256" ]]; then
    echo "下载官方 $MAGISK_APK_NAME" >&2
    curl -fL --retry 3 --retry-delay 1 \
        --output "$work_dir/$MAGISK_APK_NAME" "$MAGISK_APK_URL"
    actual_apk_sha256=$(hash_file "$work_dir/$MAGISK_APK_NAME")
    [[ "$actual_apk_sha256" == "$MAGISK_APK_SHA256" ]] ||
        fail "Magisk APK SHA-256 不匹配：$actual_apk_sha256"
    install -m 0644 -- "$work_dir/$MAGISK_APK_NAME" "$apk_path"
fi

unzip -p "$apk_path" "$MAGISKBOOT_APK_PATH" > "$work_dir/magiskboot"
chmod 0755 "$work_dir/magiskboot"
verify_magiskboot "$work_dir/magiskboot"
install -m 0755 -- "$work_dir/magiskboot" "$output"
verify_magiskboot "$output"

echo "已提取 Magisk $MAGISK_VERSION arm64 静态 magiskboot" >&2
echo "来源：$MAGISK_APK_URL" >&2
echo "SHA-256：$MAGISKBOOT_SHA256" >&2
printf '%s\n' "$output"
