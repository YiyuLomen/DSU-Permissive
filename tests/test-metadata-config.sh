#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dsu-permissive-config.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
config_path="$work_dir/metadata/gsi/dsu_permissive.conf"

sh "$root_dir/tools/configure-metadata.sh" \
    --selinux 0 --avb 1 --path "$config_path" >/dev/null
expected=$'selinux_intercept=0\navb_intercept=1'
[[ "$(<"$config_path")" == "$expected" ]]
show_output=$(sh "$root_dir/tools/configure-metadata.sh" \
    --show --path "$config_path")
grep -q 'SELinux 拦截=0，AVB 拦截=1' <<<"$show_output"

sh "$root_dir/tools/configure-metadata.sh" \
    --install "$root_dir/config/dsu_permissive.conf" \
    --path "$config_path" >/dev/null
cmp "$root_dir/config/dsu_permissive.conf" "$config_path"

printf 'selinux_intercept=1\nunknown=0\n' > "$work_dir/invalid.conf"
if sh "$root_dir/tools/configure-metadata.sh" \
    --install "$work_dir/invalid.conf" --path "$config_path" \
    >/dev/null 2>&1; then
    echo "错误：metadata 配置工具接受了非法配置" >&2
    exit 1
fi

sh "$root_dir/tools/configure-metadata.sh" \
    --remove --path "$config_path" >/dev/null
[[ ! -e "$config_path" ]]
fallback_output=$(sh "$root_dir/tools/configure-metadata.sh" \
    --show --path "$config_path")
grep -q 'SELinux 拦截=1，AVB 拦截=1' <<<"$fallback_output"

echo "metadata 统一配置工具测试通过"
