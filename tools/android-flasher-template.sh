#!/system/bin/sh
set -eu

bundle_format='1'
bundle_mode='@BUNDLE_MODE@'
bundle_targets='@BUNDLE_TARGETS@'
bundle_magisk_version='@MAGISK_VERSION@'
bundle_magisk_source='@MAGISK_SOURCE@'
default_selinux='@DEFAULT_SELINUX@'
default_avb='@DEFAULT_AVB@'
magiskboot_sha256='@MAGISKBOOT_SHA256@'
loader_sha256='@LOADER_SHA256@'
module_android12_5_10_sha256='@MODULE_ANDROID12_5_10_SHA256@'
module_android13_5_10_sha256='@MODULE_ANDROID13_5_10_SHA256@'
module_android13_5_15_sha256='@MODULE_ANDROID13_5_15_SHA256@'
module_android14_5_15_sha256='@MODULE_ANDROID14_5_15_SHA256@'
module_android14_6_1_sha256='@MODULE_ANDROID14_6_1_SHA256@'
module_android15_6_6_sha256='@MODULE_ANDROID15_6_6_SHA256@'
module_android16_6_12_sha256='@MODULE_ANDROID16_6_12_SHA256@'
patcher_sha256='@PATCHER_SHA256@'

usage() {
    cat >&2 <<EOF
用法：
  sh $0 [--flash] [--partition <块设备>] [--slot current|a|b|none]
       [--backup-dir <目录>] [--selinux 0|1] [--avb 0|1]
       [--keep-work]
  sh $0 --verify-bundle

交互终端会先询问是否在备份和修补后直接刷入，默认回答为否。
非交互运行只有显式传入 --flash 才会刷入；刷入后会回读相同长度进行 SHA-256 校验。

内置模式：$bundle_mode
内置 targets：$bundle_targets
内置 magiskboot：Magisk $bundle_magisk_version，完全静态 arm64 ET_EXEC
EOF
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

prompt_for_flash() {
    [ "$operation" = "patch" ] || return 0
    [ -t 0 ] && [ -t 2 ] || return 0

    printf '检测到交互终端，是否在完成备份和修补后直接刷入目标分区？[y/N] ' >&2
    if ! IFS= read -r flash_answer; then
        echo >&2
        echo "未读取到确认，继续只生成备份和补丁镜像" >&2
        return 0
    fi

    case "$flash_answer" in
        y|Y|yes|YES|Yes)
            operation=flash
            echo "已选择在备份和修补后直接刷入目标分区" >&2
            ;;
        *)
            echo "继续只生成备份和补丁镜像，不刷入目标分区" >&2
            ;;
    esac
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
        *) fail "$prompt_label 只能输入 0、1 或直接回车" ;;
    esac
}

find_command() {
    find_name=$1
    if command -v "$find_name" >/dev/null 2>&1; then
        command -v "$find_name"
        return 0
    fi
    return 1
}

hash_file() {
    hash_path=$1
    if [ -n "${sha256_bin:-}" ]; then
        hash_line=$("$sha256_bin" "$hash_path") || return 1
    elif [ -n "${toybox_bin:-}" ]; then
        hash_line=$($toybox_bin sha256sum "$hash_path") || return 1
    elif [ -n "${busybox_bin:-}" ]; then
        hash_line=$($busybox_bin sha256sum "$hash_path") || return 1
    else
        return 1
    fi
    hash_value=${hash_line%%[[:space:]]*}
    [ -n "$hash_value" ] || return 1
    printf '%s\n' "$hash_value"
}

decode_base64() {
    if [ -n "${base64_bin:-}" ]; then
        "$base64_bin" -d
    elif [ -n "${toybox_bin:-}" ]; then
        "$toybox_bin" base64 -d
    elif [ -n "${busybox_bin:-}" ]; then
        "$busybox_bin" base64 -d
    else
        return 1
    fi
}

extract_asset() {
    asset_name=$1
    asset_output=$2
    asset_expected_sha256=$3
    asset_begin="__DSU_PAYLOAD_${asset_name}_BEGIN__"
    asset_end="__DSU_PAYLOAD_${asset_name}_END__"

    [ "$(grep -c "^${asset_begin}\$" "$self_path")" = "1" ] ||
        fail "内置资源起始标记无效：$asset_name"
    [ "$(grep -c "^${asset_end}\$" "$self_path")" = "1" ] ||
        fail "内置资源结束标记无效：$asset_name"
    sed -n "/^${asset_begin}\$/,/^${asset_end}\$/p" "$self_path" |
        sed '1d;$d' | decode_base64 > "$asset_output" ||
        fail "无法解码内置资源：$asset_name"
    asset_actual_sha256=$(hash_file "$asset_output") ||
        fail "无法计算内置资源哈希：$asset_name"
    [ "$asset_actual_sha256" = "$asset_expected_sha256" ] ||
        fail "内置资源 SHA-256 不匹配：$asset_name"
}

verify_module_asset() {
    verify_module_name=$1
    verify_module_sha256=$2
    [ -n "$verify_module_sha256" ] || return 0
    extract_asset "$verify_module_name" \
        "$work_dir/assets/$verify_module_name.ko" \
        "$verify_module_sha256"
}

verify_all_module_assets() {
    verify_module_asset module_android12_5_10 \
        "$module_android12_5_10_sha256"
    verify_module_asset module_android13_5_10 \
        "$module_android13_5_10_sha256"
    verify_module_asset module_android13_5_15 \
        "$module_android13_5_15_sha256"
    verify_module_asset module_android14_5_15 \
        "$module_android14_5_15_sha256"
    verify_module_asset module_android14_6_1 \
        "$module_android14_6_1_sha256"
    verify_module_asset module_android15_6_6 \
        "$module_android15_6_6_sha256"
    verify_module_asset module_android16_6_12 \
        "$module_android16_6_12_sha256"
}

select_module_for_kernel() {
    select_kernel_release=$1
    selected_target=""
    selected_module_asset=""
    selected_module_sha256=""

    case "$select_kernel_release" in
        5.10.*android12*|5.10-*android12*)
            selected_target=android12-5.10
            selected_module_asset=module_android12_5_10
            selected_module_sha256=$module_android12_5_10_sha256
            ;;
        5.10.*android13*|5.10-*android13*)
            selected_target=android13-5.10
            selected_module_asset=module_android13_5_10
            selected_module_sha256=$module_android13_5_10_sha256
            ;;
        5.15.*android13*|5.15-*android13*)
            selected_target=android13-5.15
            selected_module_asset=module_android13_5_15
            selected_module_sha256=$module_android13_5_15_sha256
            ;;
        5.15.*android14*|5.15-*android14*)
            selected_target=android14-5.15
            selected_module_asset=module_android14_5_15
            selected_module_sha256=$module_android14_5_15_sha256
            ;;
        6.1.*android14*|6.1-*android14*)
            selected_target=android14-6.1
            selected_module_asset=module_android14_6_1
            selected_module_sha256=$module_android14_6_1_sha256
            ;;
        6.6.*android15*|6.6-*android15*)
            selected_target=android15-6.6
            selected_module_asset=module_android15_6_6
            selected_module_sha256=$module_android15_6_6_sha256
            ;;
        6.12.*android16*|6.12-*android16*)
            selected_target=android16-6.12
            selected_module_asset=module_android16_6_12
            selected_module_sha256=$module_android16_6_12_sha256
            ;;
        5.10.*|5.10-*|5.15.*|5.15-*)
            fail "无法从内核版本识别唯一 KMI target：$select_kernel_release"
            ;;
        *)
            fail "不支持当前内核 KMI target：$select_kernel_release"
            ;;
    esac

    [ -n "$selected_module_sha256" ] ||
        fail "当前 bundle 未包含 $selected_target 对应的 KO"
}

file_size() {
    size_value=$(wc -c < "$1") || return 1
    printf '%s\n' "$size_value"
}

block_device_size() {
    size_device=$1
    if [ -n "${blockdev_bin:-}" ]; then
        "$blockdev_bin" --getsize64 "$size_device"
    elif [ -n "${toybox_bin:-}" ]; then
        "$toybox_bin" blockdev --getsize64 "$size_device"
    elif [ -n "${busybox_bin:-}" ]; then
        "$busybox_bin" blockdev --getsize64 "$size_device"
    else
        return 1
    fi
}

truncate_file() {
    truncate_size=$1
    truncate_path=$2
    if [ -n "${truncate_bin:-}" ]; then
        "$truncate_bin" -s "$truncate_size" "$truncate_path"
    elif [ -n "${toybox_bin:-}" ]; then
        "$toybox_bin" truncate -s "$truncate_size" "$truncate_path"
    elif [ -n "${busybox_bin:-}" ]; then
        "$busybox_bin" truncate -s "$truncate_size" "$truncate_path"
    else
        return 1
    fi
}

get_property() {
    property_name=$1
    if [ -n "${getprop_bin:-}" ]; then
        "$getprop_bin" "$property_name" 2>/dev/null || true
    else
        printf '\n'
    fi
}

resolve_self() {
    case "$0" in
        /*) self_path=$0 ;;
        *)
            self_dir=$(dirname "$0")
            self_base=$(basename "$0")
            self_dir=$(CDPATH='' cd "$self_dir" 2>/dev/null && pwd -P) ||
                fail "无法解析脚本路径"
            self_path=$self_dir/$self_base
            ;;
    esac
    [ -f "$self_path" ] || fail "自解包脚本必须从普通文件执行"
}

detect_slot_suffix() {
    case "$requested_slot" in
        a|b)
            slot_suffix=_$requested_slot
            ;;
        none)
            slot_suffix=""
            ;;
        current)
            slot_suffix=$(get_property ro.boot.slot_suffix)
            if [ -z "$slot_suffix" ]; then
                slot_name=$(get_property ro.boot.slot)
                case "$slot_name" in
                    a|b) slot_suffix=_$slot_name ;;
                esac
            fi
            ;;
        *) fail "--slot 只能是 current、a、b 或 none" ;;
    esac
}

resolve_partition() {
    if [ -n "$partition_override" ]; then
        [ -b "$partition_override" ] ||
            fail "指定路径不是块设备：$partition_override"
        partition_path=$partition_override
        return
    fi

    detect_slot_suffix
    for partition_root in \
        /dev/block/by-name \
        /dev/block/bootdevice/by-name \
        /dev/block/platform/*/by-name; do
        [ -d "$partition_root" ] || continue
        for partition_name in "init_boot$slot_suffix" "boot$slot_suffix"; do
            partition_candidate=$partition_root/$partition_name
            if [ -b "$partition_candidate" ]; then
                partition_path=$partition_candidate
                return
            fi
        done
    done

    if [ "$requested_slot" = "current" ] && [ -z "$slot_suffix" ]; then
        fail "无法确定当前槽位或找到无槽位 boot/init_boot；请显式使用 --slot a|b|none 或 --partition"
    fi
    fail "找不到目标 init_boot/boot 块设备"
}

# shellcheck disable=SC2329
cleanup() {
    if [ "$keep_work" -eq 0 ] && [ -n "${work_dir:-}" ] &&
        [ -d "$work_dir" ]; then
        rm -rf "$work_dir"
    elif [ -n "${work_dir:-}" ] && [ -d "$work_dir" ]; then
        echo "保留临时目录：$work_dir" >&2
    fi
}

operation='patch'
partition_override=""
requested_slot=current
backup_dir=/data/local/tmp/dsu-permissive-backups
selinux_value=$default_selinux
avb_value=$default_avb
selinux_specified=0
avb_specified=0
keep_work=0
work_dir=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --flash)
            operation=flash
            shift
            ;;
        --verify-bundle)
            operation=verify
            shift
            ;;
        --partition|--slot|--backup-dir|--selinux|--avb)
            [ "$#" -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
            option=$1
            value=$2
            shift 2
            case "$option" in
                --partition) partition_override=$value ;;
                --slot) requested_slot=$value ;;
                --backup-dir) backup_dir=$value ;;
                --selinux) selinux_value=$value; selinux_specified=1 ;;
                --avb) avb_value=$value; avb_specified=1 ;;
            esac
            ;;
        --keep-work)
            keep_work=1
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

case "$selinux_value" in 0|1) ;; *) fail "--selinux 只能是 0 或 1" ;; esac
case "$avb_value" in 0|1) ;; *) fail "--avb 只能是 0 或 1" ;; esac
if [ "$operation" != "verify" ] && [ -t 0 ] && [ -t 2 ]; then
    if [ "$selinux_specified" -eq 0 ]; then
        selinux_value=$(prompt_switch "SELinux 拦截" "$selinux_value")
    fi
    if [ "$avb_specified" -eq 0 ]; then
        avb_value=$(prompt_switch "AVB 拦截" "$avb_value")
    fi
fi
prompt_for_flash

resolve_self
sha256_bin=$(find_command sha256sum || true)
base64_bin=$(find_command base64 || true)
toybox_bin=$(find_command toybox || true)
busybox_bin=$(find_command busybox || true)
blockdev_bin=$(find_command blockdev || true)
truncate_bin=$(find_command truncate || true)
getprop_bin=$(find_command getprop || true)

[ -n "$sha256_bin" ] || [ -n "$toybox_bin" ] || [ -n "$busybox_bin" ] ||
    fail "找不到 sha256sum/toybox/busybox"
[ -n "$base64_bin" ] || [ -n "$toybox_bin" ] || [ -n "$busybox_bin" ] ||
    fail "找不到 base64/toybox/busybox"
command -v sed >/dev/null 2>&1 || fail "找不到 sed"
command -v grep >/dev/null 2>&1 || fail "找不到 grep"
command -v wc >/dev/null 2>&1 || fail "找不到 wc"
command -v mktemp >/dev/null 2>&1 || fail "找不到 mktemp"

temp_root=${TMPDIR:-}
if [ -z "$temp_root" ] || [ ! -d "$temp_root" ] || [ ! -w "$temp_root" ]; then
    temp_root=""
    for temp_candidate in /data/local/tmp /tmp; do
        if [ -d "$temp_candidate" ] && [ -w "$temp_candidate" ]; then
            temp_root=$temp_candidate
            break
        fi
    done
fi
[ -n "$temp_root" ] || fail "找不到可写临时目录"

work_dir=$(mktemp -d "$temp_root/dsu-permissive-flash.XXXXXX") ||
    fail "无法创建临时目录"
trap cleanup 0 HUP INT TERM
mkdir -p "$work_dir/assets"

extract_asset magiskboot "$work_dir/assets/magiskboot" "$magiskboot_sha256"
extract_asset loader "$work_dir/assets/dsuinit" "$loader_sha256"
extract_asset patcher "$work_dir/assets/patch-init-boot-android.sh" "$patcher_sha256"
chmod 0755 "$work_dir/assets/magiskboot" "$work_dir/assets/dsuinit" \
    "$work_dir/assets/patch-init-boot-android.sh"

if [ "$operation" = "verify" ]; then
    verify_all_module_assets
    echo "自解包资源校验通过"
    echo "bundle format：$bundle_format"
    echo "bundle mode：$bundle_mode"
    echo "targets：$bundle_targets"
    echo "magiskboot：Magisk $bundle_magisk_version"
    echo "来源：$bundle_magisk_source"
    exit 0
fi

[ "$(id -u)" = "0" ] || fail "提取或刷写 boot/init_boot 需要 root"
machine=$(uname -m)
case "$machine" in
    aarch64|arm64) ;;
    *) fail "内置工具仅支持 arm64，当前架构：$machine" ;;
esac
kernel_release=$(uname -r)
select_module_for_kernel "$kernel_release"
extract_asset "$selected_module_asset" \
    "$work_dir/assets/dsu_permissive.ko" "$selected_module_sha256"
chmod 0644 "$work_dir/assets/dsu_permissive.ko"
echo "当前内核：$kernel_release"
echo "自动选择 target：$selected_target"

resolve_partition
partition_size=$(block_device_size "$partition_path") ||
    fail "无法读取目标分区大小"
case "$partition_size" in
    ''|*[!0-9]*) fail "目标分区大小无效：$partition_size" ;;
esac
[ "$partition_size" -gt 0 ] || fail "目标分区大小为 0"

mkdir -p "$backup_dir" || fail "无法创建备份目录：$backup_dir"
chmod 0700 "$backup_dir" 2>/dev/null || true
backup_dir=$(CDPATH='' cd "$backup_dir" 2>/dev/null && pwd -P) ||
    fail "无法解析备份目录"
partition_label=$(basename "$partition_path")
timestamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
run_name=$partition_label-$timestamp-$$
backup_image=$backup_dir/$run_name-original.img
patched_image=$backup_dir/$run_name-dsu-permissive.img

echo "目标分区：$partition_path"
echo "分区大小：$partition_size bytes"
echo "开始完整备份：$backup_image"
dd if="$partition_path" of="$backup_image" bs=4194304 ||
    fail "读取目标分区失败"
sync
backup_size=$(file_size "$backup_image") || fail "无法读取备份大小"
[ "$backup_size" = "$partition_size" ] ||
    fail "备份大小 $backup_size 与分区大小 $partition_size 不一致"
backup_sha256=$(hash_file "$backup_image") || fail "无法计算备份哈希"

echo "开始修补备份镜像"
MAGISKBOOT="$work_dir/assets/magiskboot" \
    sh "$work_dir/assets/patch-init-boot-android.sh" \
        --input "$backup_image" \
        --output "$patched_image" \
        --loader "$work_dir/assets/dsuinit" \
        --module "$work_dir/assets/dsu_permissive.ko" \
        --selinux "$selinux_value" \
        --avb "$avb_value" \
        --magiskboot "$work_dir/assets/magiskboot" \
        --replace-existing ||
    fail "镜像修补或内部验证失败；原分区未写入"

patched_size=$(file_size "$patched_image") || fail "无法读取补丁镜像大小"
[ "$patched_size" -le "$partition_size" ] ||
    fail "补丁镜像大于目标分区，拒绝刷入"
patched_sha256=$(hash_file "$patched_image") || fail "无法计算补丁镜像哈希"

echo "原始备份 SHA-256：$backup_sha256"
echo "补丁镜像 SHA-256：$patched_sha256"
echo "补丁镜像已生成：$patched_image"

if [ "$operation" != "flash" ]; then
    echo "未传入 --flash，目标分区未修改"
    echo "确认备份可恢复后，可重新运行本脚本并显式传入 --flash"
    exit 0
fi

echo "开始刷入：$partition_path"
dd if="$patched_image" of="$partition_path" bs=4194304 ||
    fail "刷写失败；原始完整备份位于 $backup_image"
sync

readback_image=$work_dir/readback.img
readback_blocks=$(( (patched_size + 4194303) / 4194304 ))
dd if="$partition_path" of="$readback_image" bs=4194304 \
    count="$readback_blocks" ||
    fail "刷后回读失败；原始完整备份位于 $backup_image"
truncate_file "$patched_size" "$readback_image" ||
    fail "无法裁剪回读镜像进行校验"
readback_sha256=$(hash_file "$readback_image") || fail "无法计算回读哈希"
[ "$readback_sha256" = "$patched_sha256" ] ||
    fail "刷后回读 SHA-256 不一致；请勿重启，原始完整备份位于 $backup_image"

echo "刷入并回读校验成功"
echo "目标分区：$partition_path"
echo "补丁 SHA-256：$patched_sha256"
echo "原始完整备份：$backup_image"
echo "手动恢复命令：dd if='$backup_image' of='$partition_path' bs=4194304 && sync"
echo "现在可以重启设备；SELinux/AVB 配置已固化在 init_boot，并会在下次启动时加载"

exit 0

# 生成器会在此行之后追加 Base64 资源。请勿手工添加 payload 标记。
