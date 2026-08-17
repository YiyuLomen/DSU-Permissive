#!/system/bin/sh
set -eu

usage() {
    echo "用法：$0 --input <boot.img|init_boot.img> --output <新镜像.img> --loader <dsuinit> --module <dsu_permissive.ko> [--magiskboot <路径>] [--replace-existing]" >&2
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

resolve_existing() {
    resolve_path=$1
    [ -e "$resolve_path" ] || return 1
    resolve_dir=$(dirname "$resolve_path")
    resolve_base=$(basename "$resolve_path")
    resolve_dir=$(CDPATH='' cd "$resolve_dir" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$resolve_dir" "$resolve_base"
}

resolve_output() {
    resolve_path=$1
    resolve_dir=$(dirname "$resolve_path")
    resolve_base=$(basename "$resolve_path")
    resolve_dir=$(CDPATH='' cd "$resolve_dir" 2>/dev/null && pwd -P) || return 1
    printf '%s/%s\n' "$resolve_dir" "$resolve_base"
}

hash_file() {
    if [ "$sha256_mode" = "direct" ]; then
        hash_line=$(sha256sum "$1") || return 1
    else
        hash_line=$(toybox sha256sum "$1") || return 1
    fi
    hash_value=${hash_line%%[[:space:]]*}
    [ -n "$hash_value" ] || return 1
    printf '%s\n' "$hash_value"
}

metadata_value() {
    metadata_key=$1
    metadata_file=$2
    metadata_count=$(grep -c "^${metadata_key}=" "$metadata_file" || true)
    [ "$metadata_count" = "1" ] || return 1
    metadata_line=$(grep "^${metadata_key}=" "$metadata_file") || return 1
    printf '%s\n' "${metadata_line#*=}"
}

cleanup() {
    if [ -n "${work_dir:-}" ] && [ -d "$work_dir" ]; then
        rm -rf "$work_dir"
    fi
}

input=""
output=""
loader=""
module=""
magiskboot_bin=${MAGISKBOOT:-magiskboot}
work_dir=""
replace_existing=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --input|--output|--loader|--module|--magiskboot)
            [ "$#" -ge 2 ] && [ -n "$2" ] || {
                usage
                exit 2
            }
            option=$1
            value=$2
            shift 2
            case "$option" in
                --input) input=$value ;;
                --output) output=$value ;;
                --loader) loader=$value ;;
                --module) module=$value ;;
                --magiskboot) magiskboot_bin=$value ;;
            esac
            ;;
        --replace-existing)
            replace_existing=1
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

[ -n "$input" ] && [ -n "$output" ] && [ -n "$loader" ] && [ -n "$module" ] || {
    usage
    exit 2
}

input=$(resolve_existing "$input") || fail "输入镜像不存在"
loader=$(resolve_existing "$loader") || fail "loader 不存在"
module=$(resolve_existing "$module") || fail "内核模块不存在"
output=$(resolve_output "$output") || fail "输出目录不存在"

if command -v "$magiskboot_bin" >/dev/null 2>&1; then
    magiskboot_bin=$(command -v "$magiskboot_bin")
else
    magiskboot_bin=$(resolve_existing "$magiskboot_bin") || fail "找不到 magiskboot"
fi

[ "$input" != "$output" ] || fail "输出路径不得与输入镜像相同"
[ ! -e "$output" ] || fail "输出文件已存在，拒绝覆盖：$output"
[ -s "$loader" ] || fail "loader 文件为空"
[ -s "$module" ] || fail "内核模块文件为空"

if command -v sha256sum >/dev/null 2>&1; then
    sha256_mode=direct
elif command -v toybox >/dev/null 2>&1; then
    sha256_mode=toybox
else
    fail "找不到 sha256sum 或 toybox"
fi
command -v mktemp >/dev/null 2>&1 || fail "找不到 mktemp"
command -v grep >/dev/null 2>&1 || fail "找不到 grep"

temp_root=${TMPDIR:-}
if [ -z "$temp_root" ] || [ ! -d "$temp_root" ] || [ ! -w "$temp_root" ]; then
    temp_root=""
    for candidate in /data/local/tmp /tmp; do
        if [ -d "$candidate" ] && [ -w "$candidate" ]; then
            temp_root=$candidate
            break
        fi
    done
fi
[ -n "$temp_root" ] || fail "找不到可写临时目录"

work_dir=$(mktemp -d "$temp_root/dsu-permissive-patch.XXXXXX") ||
    fail "无法创建临时目录"
trap cleanup 0 HUP INT TERM
mkdir -p "$work_dir/image" "$work_dir/assets" "$work_dir/extract" \
    "$work_dir/verify"
cp "$loader" "$work_dir/assets/dsuinit"
cp "$module" "$work_dir/assets/dsu_permissive.ko"

cd "$work_dir/image"
"$magiskboot_bin" unpack "$input" || fail "magiskboot 无法解包输入镜像"
[ -f ramdisk.cpio ] || fail "输入镜像不含 ramdisk.cpio"
"$magiskboot_bin" cpio ramdisk.cpio "exists init" >/dev/null ||
    fail "ramdisk 中不存在 /init"
existing_count=0
for entry in init.next dsu_permissive.ko dsu_permissive.meta; do
    if "$magiskboot_bin" cpio ramdisk.cpio "exists $entry" >/dev/null 2>&1; then
        existing_count=$((existing_count + 1))
    fi
done

if [ "$existing_count" -gt 0 ]; then
    [ "$replace_existing" -eq 1 ] ||
        fail "ramdisk 已存在 DSU-Permissive/冲突条目，拒绝覆盖；确认是旧版完整补丁后可使用 --replace-existing"
    [ "$existing_count" -eq 3 ] ||
        fail "旧补丁条目不完整，拒绝自动替换"

    "$magiskboot_bin" cpio ramdisk.cpio \
        "extract init ../extract/old-loader" \
        "extract init.next ../extract/old-original-init" \
        "extract dsu_permissive.ko ../extract/old-module" \
        "extract dsu_permissive.meta ../extract/old-metadata"
    old_format=$(metadata_value format "$work_dir/extract/old-metadata") ||
        fail "旧补丁元数据缺少唯一 format"
    old_project=$(metadata_value project "$work_dir/extract/old-metadata") ||
        fail "旧补丁元数据缺少唯一 project"
    old_original_sha256=$(metadata_value original_init_sha256 \
        "$work_dir/extract/old-metadata") ||
        fail "旧补丁元数据缺少唯一原 init 哈希"
    old_loader_sha256=$(metadata_value loader_sha256 \
        "$work_dir/extract/old-metadata") ||
        fail "旧补丁元数据缺少唯一 loader 哈希"
    old_module_sha256=$(metadata_value module_sha256 \
        "$work_dir/extract/old-metadata") ||
        fail "旧补丁元数据缺少唯一模块哈希"
    [ "$old_format" = "1" ] && [ "$old_project" = "DSU-Permissive" ] ||
        fail "已有条目不是受支持的 DSU-Permissive 补丁"
    [ "$(hash_file "$work_dir/extract/old-original-init")" = \
        "$old_original_sha256" ] || fail "旧补丁原 init 哈希不一致"
    [ "$(hash_file "$work_dir/extract/old-loader")" = \
        "$old_loader_sha256" ] || fail "旧补丁 loader 哈希不一致"
    [ "$(hash_file "$work_dir/extract/old-module")" = \
        "$old_module_sha256" ] || fail "旧补丁模块哈希不一致"

    "$magiskboot_bin" cpio ramdisk.cpio \
        "rm init" \
        "rm dsu_permissive.ko" \
        "rm dsu_permissive.meta" \
        "mv init.next init"
    echo "已验证旧补丁并恢复原 init 链，继续替换 loader/KO"
fi

"$magiskboot_bin" cpio ramdisk.cpio \
    "extract init ../extract/original-init"
original_init_sha256=$(hash_file "$work_dir/extract/original-init")
loader_sha256=$(hash_file "$work_dir/assets/dsuinit")
module_sha256=$(hash_file "$work_dir/assets/dsu_permissive.ko")
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
"$magiskboot_bin" repack "$input" "$work_dir/candidate.img" ||
    fail "magiskboot 无法重新打包镜像"

cd "$work_dir/verify"
"$magiskboot_bin" unpack "$work_dir/candidate.img" >/dev/null ||
    fail "补丁候选镜像无法重新解包"
[ -f ramdisk.cpio ] || fail "补丁候选镜像不含 ramdisk.cpio"
for entry in init init.next dsu_permissive.ko dsu_permissive.meta; do
    "$magiskboot_bin" cpio ramdisk.cpio "exists $entry" >/dev/null ||
        fail "补丁候选镜像缺少 /$entry"
done
"$magiskboot_bin" cpio ramdisk.cpio \
    "extract init current-loader" \
    "extract init.next current-original-init" \
    "extract dsu_permissive.ko current-module" \
    "extract dsu_permissive.meta current-metadata"

[ "$(hash_file current-loader)" = "$loader_sha256" ] ||
    fail "补丁候选镜像中的 loader 哈希不一致"
[ "$(hash_file current-original-init)" = "$original_init_sha256" ] ||
    fail "补丁候选镜像中的原 init 哈希不一致"
[ "$(hash_file current-module)" = "$module_sha256" ] ||
    fail "补丁候选镜像中的模块哈希不一致"
grep -qx 'format=1' current-metadata || fail "补丁元数据格式无效"
grep -qx 'project=DSU-Permissive' current-metadata || fail "补丁元数据项目无效"
grep -qx "original_init_sha256=$original_init_sha256" current-metadata ||
    fail "补丁元数据中的原 init 哈希无效"
grep -qx "loader_sha256=$loader_sha256" current-metadata ||
    fail "补丁元数据中的 loader 哈希无效"
grep -qx "module_sha256=$module_sha256" current-metadata ||
    fail "补丁元数据中的模块哈希无效"

cp "$work_dir/candidate.img" "$output"
chmod 0644 "$output"

echo "完成：已生成补丁镜像 $output"
echo "原输入镜像未被修改：$input"
echo "脚本未执行任何刷写操作"
