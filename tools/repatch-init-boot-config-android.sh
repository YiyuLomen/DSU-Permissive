#!/system/bin/sh
set -eu

usage() {
    echo "用法：$0 --input <已修补 boot/init_boot.img> --output <新镜像.img> [--selinux 0|1] [--avb 0|1] [--magiskboot <路径>]" >&2
}

script_dir=$(CDPATH='' cd "$(dirname "$0")" 2>/dev/null && pwd -P) || exit 1
input=""
output=""
selinux_value=""
avb_value=""
magiskboot_bin=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --input|--output|--selinux|--avb|--magiskboot)
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
                --selinux) selinux_value=$value ;;
                --avb) avb_value=$value ;;
                --magiskboot) magiskboot_bin=$value ;;
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

[ -n "$input" ] && [ -n "$output" ] || {
    usage
    exit 2
}

set -- "$script_dir/patch-init-boot-android.sh" \
    --input "$input" --output "$output" \
    --replace-existing --reuse-existing
[ -z "$selinux_value" ] || set -- "$@" --selinux "$selinux_value"
[ -z "$avb_value" ] || set -- "$@" --avb "$avb_value"
[ -z "$magiskboot_bin" ] || set -- "$@" --magiskboot "$magiskboot_bin"
exec sh "$@"
