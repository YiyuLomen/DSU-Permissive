#!/system/bin/sh
set -eu

usage() {
    echo "用法：$0 --input <boot.img|init_boot.img> --output <新镜像.img> [--loader <dsuinit> --module <dsu_permissive.ko> | --reuse-existing] [--selinux 0|1] [--avb 0|1] [--verity-table-spoof 0|1] [--magiskboot <路径>] [--replace-existing]" >&2
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

prompt_switch() {
    prompt_label=$1
    prompt_default=$2

    printf '%s（0=关闭，1=开启，默认 %s）：' \
        "$prompt_label" "$prompt_default" >&2
    if ! IFS= read -r prompt_answer; then
        printf '\n' >&2
        printf '%s\n' "$prompt_default"
        return
    fi
    case "$prompt_answer" in
        "") printf '%s\n' "$prompt_default" ;;
        0|1) printf '%s\n' "$prompt_answer" ;;
        *)
            echo "错误：$prompt_label 只能输入 0、1 或直接回车" >&2
            exit 2
            ;;
    esac
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

validate_config_file() {
    config_file=$1
    config_format=$2
    config_first=$(sed -n '1p' "$config_file")
    config_second=$(sed -n '2p' "$config_file")
    config_third=$(sed -n '3p' "$config_file")
    config_lines=$(wc -l < "$config_file")

    case "$config_first" in selinux_intercept=0|selinux_intercept=1) ;; *) return 1 ;; esac
    case "$config_second" in avb_intercept=0|avb_intercept=1) ;; *) return 1 ;; esac
    case "$config_format" in
        3) [ "$config_third" = "" ] && [ "$config_lines" = "2" ] ;;
        4)
            case "$config_third" in verity_table_spoof=0|verity_table_spoof=1) ;; *) return 1 ;; esac
            [ "$config_lines" = "3" ]
            ;;
        *) return 1 ;;
    esac
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
reuse_existing=0
selinux_value=1
avb_value=1
verity_table_spoof_value=0
selinux_specified=0
avb_specified=0
verity_table_spoof_specified=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --input|--output|--loader|--module|--magiskboot|--selinux|--avb|--verity-table-spoof)
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
                --selinux) selinux_value=$value; selinux_specified=1 ;;
                --avb) avb_value=$value; avb_specified=1 ;;
                --verity-table-spoof)
                    verity_table_spoof_value=$value
                    verity_table_spoof_specified=1
                    ;;
            esac
            ;;
        --replace-existing)
            replace_existing=1
            shift
            ;;
        --reuse-existing)
            reuse_existing=1
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

[ -n "$input" ] && [ -n "$output" ] || {
    usage
    exit 2
}
if { [ -n "$loader" ] && [ -n "$module" ]; } ||
   { [ -z "$loader" ] && [ -z "$module" ]; }; then
    :
else
    fail "--loader 与 --module 必须同时提供"
fi
[ "$reuse_existing" -eq 0 ] || {
    [ "$replace_existing" -eq 1 ] ||
        fail "--reuse-existing 必须与 --replace-existing 一起使用"
    [ -z "$loader" ] && [ -z "$module" ] ||
        fail "--reuse-existing 不能与 --loader/--module 组合"
}
[ "$reuse_existing" -eq 1 ] || {
    [ -n "$loader" ] && [ -n "$module" ] || {
        usage
        exit 2
    }
}
case "$selinux_value" in 0|1) ;; *) fail "--selinux 只能是 0 或 1" ;; esac
case "$avb_value" in 0|1) ;; *) fail "--avb 只能是 0 或 1" ;; esac
case "$verity_table_spoof_value" in
    0|1) ;;
    *) fail "--verity-table-spoof 只能是 0 或 1" ;;
esac
if [ -t 0 ] && [ -t 2 ]; then
    if [ "$selinux_specified" -eq 0 ]; then
        selinux_value=$(prompt_switch "SELinux 拦截" "$selinux_value")
    fi
    if [ "$avb_specified" -eq 0 ]; then
        avb_value=$(prompt_switch "AVB 拦截" "$avb_value")
    fi
    if [ "$verity_table_spoof_specified" -eq 0 ]; then
        verity_table_spoof_value=$(prompt_switch "dm-verity 表伪造" "$verity_table_spoof_value")
    fi
fi

input=$(resolve_existing "$input") || fail "输入镜像不存在"
if [ "$reuse_existing" -eq 0 ]; then
    loader=$(resolve_existing "$loader") || fail "loader 不存在"
    module=$(resolve_existing "$module") || fail "内核模块不存在"
fi
output=$(resolve_output "$output") || fail "输出目录不存在"

if command -v "$magiskboot_bin" >/dev/null 2>&1; then
    magiskboot_bin=$(command -v "$magiskboot_bin")
else
    magiskboot_bin=$(resolve_existing "$magiskboot_bin") || fail "找不到 magiskboot"
fi

[ "$input" != "$output" ] || fail "输出路径不得与输入镜像相同"
[ ! -e "$output" ] || fail "输出文件已存在，拒绝覆盖：$output"
if [ "$reuse_existing" -eq 0 ]; then
    [ -s "$loader" ] || fail "loader 文件为空"
    [ -s "$module" ] || fail "内核模块文件为空"
fi

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
if [ "$reuse_existing" -eq 0 ]; then
    cp "$loader" "$work_dir/assets/dsuinit"
    cp "$module" "$work_dir/assets/dsu_permissive.ko"
fi
printf 'selinux_intercept=%s\navb_intercept=%s\nverity_table_spoof=%s\n' \
    "$selinux_value" "$avb_value" "$verity_table_spoof_value" \
    > "$work_dir/assets/dsu_permissive.conf"

cd "$work_dir/image"
"$magiskboot_bin" unpack "$input" || fail "magiskboot 无法解包输入镜像"
[ -f ramdisk.cpio ] || fail "输入镜像不含 ramdisk.cpio"
"$magiskboot_bin" cpio ramdisk.cpio "exists init" >/dev/null ||
    fail "ramdisk 中不存在 /init"
existing_count=0
for entry in init.next dsu_permissive.ko dsu_permissive.conf dsu_permissive.meta; do
    if "$magiskboot_bin" cpio ramdisk.cpio "exists $entry" >/dev/null 2>&1; then
        existing_count=$((existing_count + 1))
    fi
done

if [ "$existing_count" -gt 0 ]; then
    [ "$replace_existing" -eq 1 ] ||
        fail "ramdisk 已存在 DSU-Permissive/冲突条目，拒绝覆盖；确认是旧版完整补丁后可使用 --replace-existing"
    case "$existing_count" in 3|4) ;; *)
        fail "旧补丁条目不完整，拒绝自动替换"
    esac

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
    [ "$old_project" = "DSU-Permissive" ] ||
        fail "已有条目不是受支持的 DSU-Permissive 补丁"
    [ "$(hash_file "$work_dir/extract/old-original-init")" = \
        "$old_original_sha256" ] || fail "旧补丁原 init 哈希不一致"
    [ "$(hash_file "$work_dir/extract/old-loader")" = \
        "$old_loader_sha256" ] || fail "旧补丁 loader 哈希不一致"
    [ "$(hash_file "$work_dir/extract/old-module")" = \
        "$old_module_sha256" ] || fail "旧补丁模块哈希不一致"
    case "$old_format" in
        1)
            [ "$existing_count" -eq 3 ] ||
                fail "format=1 旧补丁不应包含内嵌配置"
            ;;
        2)
            [ "$existing_count" -eq 4 ] ||
                fail "format=2 旧补丁缺少内嵌配置"
            "$magiskboot_bin" cpio ramdisk.cpio \
                "extract dsu_permissive.conf ../extract/old-config"
            old_config_sha256=$(metadata_value config_sha256 \
                "$work_dir/extract/old-metadata") ||
                fail "旧补丁元数据缺少唯一内嵌配置哈希"
            [ "$(hash_file "$work_dir/extract/old-config")" = \
                "$old_config_sha256" ] || fail "旧补丁内嵌配置哈希不一致"
            ;;
        3|4)
            [ "$existing_count" -eq 4 ] ||
                fail "format=$old_format 旧补丁缺少内嵌配置"
            "$magiskboot_bin" cpio ramdisk.cpio \
                "extract dsu_permissive.conf ../extract/old-config"
            validate_config_file "$work_dir/extract/old-config" "$old_format" ||
                fail "旧补丁内嵌配置格式无效"
            ;;
        *) fail "旧补丁元数据格式不受支持：$old_format" ;;
    esac
    if [ "$reuse_existing" -eq 1 ] && [ "$old_format" != "4" ]; then
        fail "--reuse-existing 不能升级 format=$old_format 配置；请提供新版 --loader 与 --module 进行完整替换"
    fi
    if [ "$reuse_existing" -eq 1 ]; then
        cp "$work_dir/extract/old-loader" "$work_dir/assets/dsuinit"
        cp "$work_dir/extract/old-module" "$work_dir/assets/dsu_permissive.ko"
    fi

    "$magiskboot_bin" cpio ramdisk.cpio \
        "rm init" \
        "rm dsu_permissive.ko" \
        "rm dsu_permissive.meta" \
        "mv init.next init"
    if [ "$old_format" = "2" ] || [ "$old_format" = "3" ] || [ "$old_format" = "4" ]; then
        "$magiskboot_bin" cpio ramdisk.cpio "rm dsu_permissive.conf"
    fi
    echo "已验证旧补丁并恢复原 init 链，继续替换 loader/KO"
elif [ "$reuse_existing" -eq 1 ]; then
    fail "--reuse-existing 仅可用于已验证的 DSU-Permissive 补丁镜像"
fi

"$magiskboot_bin" cpio ramdisk.cpio \
    "extract init ../extract/original-init"
original_init_sha256=$(hash_file "$work_dir/extract/original-init")
loader_sha256=$(hash_file "$work_dir/assets/dsuinit")
module_sha256=$(hash_file "$work_dir/assets/dsu_permissive.ko")
{
    printf 'format=4\n'
    printf 'project=DSU-Permissive\n'
    printf 'original_init_sha256=%s\n' "$original_init_sha256"
    printf 'loader_sha256=%s\n' "$loader_sha256"
    printf 'module_sha256=%s\n' "$module_sha256"
} > "$work_dir/assets/dsu_permissive.meta"

"$magiskboot_bin" cpio ramdisk.cpio \
    "mv init init.next" \
    "add 0755 init ../assets/dsuinit" \
    "add 0644 dsu_permissive.ko ../assets/dsu_permissive.ko" \
    "add 0600 dsu_permissive.conf ../assets/dsu_permissive.conf" \
    "add 0644 dsu_permissive.meta ../assets/dsu_permissive.meta"
"$magiskboot_bin" repack "$input" "$work_dir/candidate.img" ||
    fail "magiskboot 无法重新打包镜像"

cd "$work_dir/verify"
"$magiskboot_bin" unpack "$work_dir/candidate.img" >/dev/null ||
    fail "补丁候选镜像无法重新解包"
[ -f ramdisk.cpio ] || fail "补丁候选镜像不含 ramdisk.cpio"
for entry in init init.next dsu_permissive.ko dsu_permissive.conf dsu_permissive.meta; do
    "$magiskboot_bin" cpio ramdisk.cpio "exists $entry" >/dev/null ||
        fail "补丁候选镜像缺少 /$entry"
done
"$magiskboot_bin" cpio ramdisk.cpio \
    "extract init current-loader" \
    "extract init.next current-original-init" \
    "extract dsu_permissive.ko current-module" \
    "extract dsu_permissive.conf current-config" \
    "extract dsu_permissive.meta current-metadata"

[ "$(hash_file current-loader)" = "$loader_sha256" ] ||
    fail "补丁候选镜像中的 loader 哈希不一致"
[ "$(hash_file current-original-init)" = "$original_init_sha256" ] ||
    fail "补丁候选镜像中的原 init 哈希不一致"
[ "$(hash_file current-module)" = "$module_sha256" ] ||
    fail "补丁候选镜像中的模块哈希不一致"
validate_config_file current-config 4 || fail "补丁候选镜像中的内嵌配置无效"
grep -qx 'format=4' current-metadata || fail "补丁元数据格式无效"
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
