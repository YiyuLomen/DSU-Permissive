#!/system/bin/sh
set -eu

DEFAULT_CONFIG_PATH=/metadata/gsi/dsu_permissive.conf

usage() {
    cat >&2 <<'EOF'
用法：
  configure-metadata.sh --selinux <0|1> --avb <0|1> [--path <路径>]
  configure-metadata.sh --install <配置文件> [--path <路径>]
  configure-metadata.sh --show [--path <路径>]
  configure-metadata.sh --remove [--path <路径>]
EOF
}

fail() {
    echo "错误：$*" >&2
    exit 1
}

parse_config() {
    cfg_source=$1
    cfg_selinux=""
    cfg_avb=""
    cfg_cr=$(printf '\r')

    while IFS= read -r cfg_line || [ -n "$cfg_line" ]; do
        cfg_line=${cfg_line%"$cfg_cr"}
        case "$cfg_line" in
            "") ;;
            selinux_intercept=0|selinux_intercept=1)
                [ -z "$cfg_selinux" ] || return 1
                cfg_selinux=${cfg_line#*=}
                ;;
            avb_intercept=0|avb_intercept=1)
                [ -z "$cfg_avb" ] || return 1
                cfg_avb=${cfg_line#*=}
                ;;
            *) return 1 ;;
        esac
    done < "$cfg_source"

    [ -n "$cfg_selinux" ] && [ -n "$cfg_avb" ]
}

require_metadata_root() {
    case "$config_path" in
        /metadata|/metadata/*)
            [ "$(id -u)" = "0" ] ||
                fail "写入 /metadata 需要 root，请通过 su 或 recovery 执行"
            ;;
    esac
}

restore_label() {
    case "$config_path" in
        /metadata|/metadata/*)
            if command -v restorecon >/dev/null 2>&1; then
                if ! restorecon "$config_path"; then
                    echo "警告：restorecon 失败，请确认 metadata 文件标签" >&2
                fi
            fi
            ;;
    esac
}

write_config() {
    config_parent=$(dirname "$config_path")
    mkdir -p "$config_parent" || fail "无法创建配置目录 $config_parent"
    command -v mktemp >/dev/null 2>&1 || fail "找不到 mktemp"
    config_temp=$(mktemp "$config_parent/.dsu_permissive.conf.XXXXXX") ||
        fail "无法在 metadata 创建临时配置"
    trap 'rm -f "$config_temp"' 0 HUP INT TERM
    printf 'selinux_intercept=%s\navb_intercept=%s\n' \
        "$cfg_selinux" "$cfg_avb" > "$config_temp"
    chmod 0644 "$config_temp"
    mv -f "$config_temp" "$config_path"
    trap - 0 HUP INT TERM
    restore_label
    case "$config_path" in
        /metadata|/metadata/*)
            if command -v sync >/dev/null 2>&1; then
                sync
            fi
            ;;
    esac
    echo "已写入：$config_path"
    echo "SELinux 拦截=$cfg_selinux，AVB 拦截=$cfg_avb"
    echo "配置将在下次启动 DSU 时生效"
}

config_path=$DEFAULT_CONFIG_PATH
action=""
install_source=""
selinux_value=""
avb_value=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --selinux|--avb|--install|--path)
            [ "$#" -ge 2 ] && [ -n "$2" ] || {
                usage
                exit 2
            }
            option=$1
            value=$2
            shift 2
            case "$option" in
                --selinux) selinux_value=$value ;;
                --avb) avb_value=$value ;;
                --install) install_source=$value ;;
                --path) config_path=$value ;;
            esac
            ;;
        --show|--remove)
            [ -z "$action" ] || fail "只能选择一个操作"
            action=${1#--}
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

if [ -n "$install_source" ]; then
    [ -z "$action" ] && [ -z "$selinux_value" ] && [ -z "$avb_value" ] ||
        fail "--install 不能与其他配置操作组合"
    [ -f "$install_source" ] || fail "配置文件不存在：$install_source"
    parse_config "$install_source" ||
        fail "配置必须各包含一次 selinux_intercept=0|1 与 avb_intercept=0|1"
    action='write'
elif [ -n "$selinux_value" ] || [ -n "$avb_value" ]; then
    [ -z "$action" ] || fail "开关参数不能与 --show/--remove 组合"
    case "$selinux_value" in 0|1) ;; *) fail "--selinux 只能是 0 或 1" ;; esac
    case "$avb_value" in 0|1) ;; *) fail "--avb 只能是 0 或 1" ;; esac
    cfg_selinux=$selinux_value
    cfg_avb=$avb_value
    action='write'
fi

[ -n "$action" ] || {
    usage
    exit 2
}

case "$action" in
    write)
        require_metadata_root
        write_config
        ;;
    show)
        [ -z "$install_source" ] && [ -z "$selinux_value" ] &&
            [ -z "$avb_value" ] || fail "--show 不能与写入参数组合"
        if [ ! -e "$config_path" ]; then
            echo "配置不存在：$config_path"
            echo "当前回退值：SELinux 拦截=1，AVB 拦截=1"
            exit 0
        fi
        if parse_config "$config_path"; then
            echo "配置路径：$config_path"
            echo "SELinux 拦截=$cfg_selinux，AVB 拦截=$cfg_avb"
        else
            echo "配置无效：$config_path" >&2
            echo "下次 DSU 启动将关闭全部拦截" >&2
            exit 1
        fi
        ;;
    remove)
        [ -z "$install_source" ] && [ -z "$selinux_value" ] &&
            [ -z "$avb_value" ] || fail "--remove 不能与写入参数组合"
        require_metadata_root
        if [ -e "$config_path" ]; then
            rm -f "$config_path"
            echo "已删除：$config_path"
        else
            echo "配置原本不存在：$config_path"
        fi
        echo "下次 DSU 启动将回退为 SELinux/AVB 拦截均开启"
        ;;
    *) fail "内部操作状态无效" ;;
esac
