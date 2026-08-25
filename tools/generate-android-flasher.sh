#!/usr/bin/env bash
set -euo pipefail

OFFICIAL_MAGISK_VERSION="v30.7"
OFFICIAL_MAGISK_SOURCE="https://github.com/topjohnwu/Magisk/releases/download/v30.7/Magisk-v30.7.apk"
OFFICIAL_MAGISKBOOT_SHA256="d7440e2cd89899426e809554bf793baef9804ccbe5a52ce34a8b6242725d3c77"

supported_targets=(
    android12-5.10
    android13-5.10
    android13-5.15
    android14-5.15
    android14-6.1
    android15-6.6
    android16-6.12
)

usage() {
    cat >&2 <<'EOF'
用法：
  # 把全部 KO 封装，设备端按 uname -r 自动选择
  tools/generate-android-flasher.sh --target auto --output <脚本>
      [--module-dir <包含各 target KO 的目录>]
      [--loader <dsuinit>] [--magiskboot <静态 arm64 magiskboot>]
      [--selinux <0|1>] [--avb <0|1>] [--verity-table-spoof <0|1>]

未指定 magiskboot 时会拉取并校验固定的官方 Magisk v30.7 静态 arm64
magiskboot。生成结果是一个包含全部所需资源的离线 Android shell 脚本。
EOF
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

hash_file() {
    sha256sum "$1" | awk '{print $1}'
}

asset_name_for_target() {
    case "$1" in
        android12-5.10) echo "module_android12_5_10" ;;
        android13-5.10) echo "module_android13_5_10" ;;
        android13-5.15) echo "module_android13_5_15" ;;
        android14-5.15) echo "module_android14_5_15" ;;
        android14-6.1) echo "module_android14_6_1" ;;
        android15-6.6) echo "module_android15_6_6" ;;
        android16-6.12) echo "module_android16_6_12" ;;
        *) return 1 ;;
    esac
}

escape_sed_replacement() {
    printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

verify_static_magiskboot() {
    local binary=$1
    local elf_header
    local program_headers
    local dynamic_section

    [[ -s "$binary" ]] || fail "magiskboot 文件不存在或为空：$binary"
    elf_header=$("$readelf_bin" -h "$binary")
    grep -q 'Class:.*ELF64' <<<"$elf_header" ||
        fail "magiskboot 不是 ELF64"
    grep -q 'Type:.*EXEC' <<<"$elf_header" ||
        fail "magiskboot 不是完全静态 ET_EXEC"
    grep -q 'Machine:.*AArch64' <<<"$elf_header" ||
        fail "magiskboot 不是 AArch64"

    program_headers=$("$readelf_bin" -l "$binary")
    if grep -Eq '(^|[[:space:]])(INTERP|DYNAMIC)([[:space:]]|$)' \
        <<<"$program_headers"; then
        fail "magiskboot 含动态解释器或动态段"
    fi
    dynamic_section=$("$readelf_bin" -d "$binary" 2>/dev/null || true)
    if grep -q 'NEEDED' <<<"$dynamic_section"; then
        fail "magiskboot 含动态依赖"
    fi
}

append_payload() {
    local name=$1
    local source=$2
    local destination=$3

    {
        printf '__DSU_PAYLOAD_%s_BEGIN__\n' "$name"
        base64 -w 76 "$source"
        printf '\n__DSU_PAYLOAD_%s_END__\n' "$name"
    } >> "$destination"
}

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
template="$root_dir/tools/android-flasher-template.sh"
loader="$root_dir/out/dsuinit"
module_dir="$root_dir/out"
magiskboot=""
target=""
output=""
default_selinux=1
default_avb=1
default_verity_table_spoof=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target|--output|--loader|--module-dir|--magiskboot|--selinux|--avb|--verity-table-spoof)
            [[ $# -ge 2 && -n "${2:-}" ]] || { usage; exit 2; }
            option=$1
            value=$2
            shift 2
            case "$option" in
                --target) target=$value ;;
                --output) output=$value ;;
                --loader) loader=$value ;;
                --module-dir) module_dir=$value ;;
                --magiskboot) magiskboot=$value ;;
                --selinux) default_selinux=$value ;;
                --avb) default_avb=$value ;;
                --verity-table-spoof) default_verity_table_spoof=$value ;;
            esac
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

[[ "$target" == "auto" && -n "$output" ]] || {
    usage
    exit 2
}
case "$default_selinux" in 0|1) ;; *) fail "--selinux 只能是 0 或 1" ;; esac
case "$default_avb" in 0|1) ;; *) fail "--avb 只能是 0 或 1" ;; esac
case "$default_verity_table_spoof" in
    0|1) ;;
    *) fail "--verity-table-spoof 只能是 0 或 1" ;;
esac

bundle_mode=auto
selected_targets=("${supported_targets[@]}")
bundle_targets="${selected_targets[*]}"

loader=$(realpath -e -- "$loader")
module_dir=$(realpath -e -- "$module_dir")
[[ -f "$template" ]] || fail "缺少 Android 刷写脚本模板：$template"

for command_name in base64 grep sed sha256sum awk mktemp realpath chmod mv; do
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

if [[ -z "$magiskboot" ]]; then
    magiskboot=$("$root_dir/tools/fetch-static-magiskboot.sh")
fi
magiskboot=$(realpath -e -- "$magiskboot")
verify_static_magiskboot "$magiskboot"

declare -A module_paths=()
declare -A module_hashes=()
for selected_target in "${selected_targets[@]}"; do
    module_path="$module_dir/dsu_permissive-$selected_target.ko"
    if [[ ! -e "$module_path" ]]; then
        module_path="$module_dir/$selected_target/dsu_permissive.ko"
    fi
    module_path=$(realpath -e -- "$module_path")
    "$root_dir/tools/verify-artifacts.sh" \
        --loader "$loader" --module "$module_path" \
        --target "$selected_target" >/dev/null
    module_paths["$selected_target"]=$module_path
    module_hashes["$selected_target"]=$(hash_file "$module_path")
done

magiskboot_sha256=$(hash_file "$magiskboot")
loader_sha256=$(hash_file "$loader")
patcher_sha256=$(hash_file "$root_dir/tools/patch-init-boot-android.sh")
if [[ "$magiskboot_sha256" == "$OFFICIAL_MAGISKBOOT_SHA256" ]]; then
    magisk_version=$OFFICIAL_MAGISK_VERSION
    magisk_source=$OFFICIAL_MAGISK_SOURCE
else
    magisk_version=custom
    magisk_source="user-provided-static-magiskboot"
fi

module_android12_5_10_sha256="${module_hashes[android12-5.10]:-}"
module_android13_5_10_sha256="${module_hashes[android13-5.10]:-}"
module_android13_5_15_sha256="${module_hashes[android13-5.15]:-}"
module_android14_5_15_sha256="${module_hashes[android14-5.15]:-}"
module_android14_6_1_sha256="${module_hashes[android14-6.1]:-}"
module_android15_6_6_sha256="${module_hashes[android15-6.6]:-}"
module_android16_6_12_sha256="${module_hashes[android16-6.12]:-}"

output_parent=$(realpath -e -- "$(dirname -- "$output")")
output="$output_parent/$(basename -- "$output")"
[[ ! -e "$output" ]] || fail "输出文件已存在，拒绝覆盖：$output"
temp_output=$(mktemp "$output_parent/.dsu-flasher.XXXXXX")
trap 'rm -f -- "$temp_output"' EXIT

sed \
    -e "s|@BUNDLE_MODE@|$(escape_sed_replacement "$bundle_mode")|g" \
    -e "s|@BUNDLE_TARGETS@|$(escape_sed_replacement "$bundle_targets")|g" \
    -e "s|@MAGISK_VERSION@|$(escape_sed_replacement "$magisk_version")|g" \
    -e "s|@MAGISK_SOURCE@|$(escape_sed_replacement "$magisk_source")|g" \
    -e "s|@DEFAULT_SELINUX@|$default_selinux|g" \
    -e "s|@DEFAULT_AVB@|$default_avb|g" \
    -e "s|@DEFAULT_VERITY_TABLE_SPOOF@|$default_verity_table_spoof|g" \
    -e "s|@MAGISKBOOT_SHA256@|$magiskboot_sha256|g" \
    -e "s|@LOADER_SHA256@|$loader_sha256|g" \
    -e "s|@MODULE_ANDROID12_5_10_SHA256@|$module_android12_5_10_sha256|g" \
    -e "s|@MODULE_ANDROID13_5_10_SHA256@|$module_android13_5_10_sha256|g" \
    -e "s|@MODULE_ANDROID13_5_15_SHA256@|$module_android13_5_15_sha256|g" \
    -e "s|@MODULE_ANDROID14_5_15_SHA256@|$module_android14_5_15_sha256|g" \
    -e "s|@MODULE_ANDROID14_6_1_SHA256@|$module_android14_6_1_sha256|g" \
    -e "s|@MODULE_ANDROID15_6_6_SHA256@|$module_android15_6_6_sha256|g" \
    -e "s|@MODULE_ANDROID16_6_12_SHA256@|$module_android16_6_12_sha256|g" \
    -e "s|@PATCHER_SHA256@|$patcher_sha256|g" \
    "$template" > "$temp_output"

if grep -Eq '@[A-Z][A-Z0-9_]+@' "$temp_output"; then
    fail "刷写脚本模板仍含未替换占位符"
fi

append_payload magiskboot "$magiskboot" "$temp_output"
append_payload loader "$loader" "$temp_output"
for selected_target in "${selected_targets[@]}"; do
    module_asset=$(asset_name_for_target "$selected_target")
    append_payload "$module_asset" \
        "${module_paths[$selected_target]}" "$temp_output"
done
append_payload patcher "$root_dir/tools/patch-init-boot-android.sh" "$temp_output"

chmod 0755 "$temp_output"
sh -n "$temp_output"
TMPDIR=${TMPDIR:-/tmp} sh "$temp_output" --verify-bundle >/dev/null
mv -- "$temp_output" "$output"
trap - EXIT

echo "已生成完全自包含的 Android 刷写脚本：$output"
echo "bundle mode：$bundle_mode"
echo "targets：$bundle_targets"
echo "magiskboot：$magisk_version（$magiskboot_sha256）"
echo "默认配置：SELinux 拦截=$default_selinux，AVB 拦截=$default_avb，dm-verity 表伪造=$default_verity_table_spoof"
echo "设备端会在备份和修补前按 uname -r 选择 KO；交互运行会询问是否直接刷入，非交互运行需显式传入 --flash"
