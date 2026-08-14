#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "用法：$0 [--loader <dsuinit>] [--module <dsu_permissive.ko>]" >&2
}

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
loader="$root_dir/out/dsuinit"
module="$root_dir/out/dsu_permissive.ko"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --loader) loader="${2:-}"; shift 2 ;;
        --module) module="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "错误：未知参数 $1" >&2; usage; exit 2 ;;
    esac
done

loader=$(realpath -e -- "$loader")
module=$(realpath -e -- "$module")

loader_header=$(llvm-readelf -h "$loader")
if ! grep -q 'Type:.*EXEC' <<<"$loader_header" ||
   ! grep -q 'Machine:.*AArch64' <<<"$loader_header"; then
    echo "错误：dsuinit 不是 AArch64 ET_EXEC" >&2
    exit 1
fi
loader_program_headers=$(llvm-readelf -l "$loader")
if grep -q 'INTERP' <<<"$loader_program_headers"; then
    echo "错误：dsuinit 含动态解释器" >&2
    exit 1
fi
loader_dynamic=$(llvm-readelf -d "$loader" 2>/dev/null)
if grep -q 'NEEDED' <<<"$loader_dynamic"; then
    echo "错误：dsuinit 含动态依赖" >&2
    exit 1
fi
if [[ -n "$(llvm-nm -u "$loader" 2>/dev/null)" ]]; then
    echo "错误：dsuinit 含未解析符号" >&2
    exit 1
fi

module_header=$(llvm-readelf -h "$module")
if ! grep -q 'Type:.*REL' <<<"$module_header" ||
   ! grep -q 'Machine:.*AArch64' <<<"$module_header"; then
    echo "错误：内核模块不是 AArch64 ET_REL" >&2
    exit 1
fi
module_modinfo=$(llvm-readelf -p .modinfo "$module")
if ! grep -q 'license=GPL' <<<"$module_modinfo"; then
    echo "错误：内核模块缺少 GPL modinfo" >&2
    exit 1
fi
if ! grep -q 'vermagic=' <<<"$module_modinfo"; then
    echo "错误：内核模块缺少 vermagic" >&2
    exit 1
fi

echo "产物验证通过："
echo "  loader：$loader"
echo "  module：$module"
