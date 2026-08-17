#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root_dir"

for script in tools/*.sh tests/*.sh; do
    bash -n "$script"
done
sh -n tools/patch-init-boot-android.sh
sh -n tools/android-flasher-template.sh
if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -x tools/fetch-static-magiskboot.sh \
        tools/generate-android-flasher.sh \
        tests/test-android-flasher-generator.sh \
        tests/test-image-roundtrip.sh tools/build.sh
    shellcheck -s sh tools/android-flasher-template.sh \
        tools/patch-init-boot-android.sh tools/configure-metadata.sh
fi
expected_config=$'selinux_intercept=1\navb_intercept=1'
actual_config=$(<config/dsu_permissive.conf)
if [[ "$actual_config" != "$expected_config" ]]; then
    echo "错误：默认统一配置内容不符合预期" >&2
    exit 1
fi
expected_targets=$'android12-5.10\nandroid13-5.10\nandroid13-5.15\nandroid14-5.15\nandroid14-6.1\nandroid15-6.6\nandroid16-6.12'
actual_targets=$(tools/build.sh --list-targets | cut -f1)
if [[ "$actual_targets" != "$expected_targets" ]]; then
    echo "错误：DDK 支持矩阵与预期不一致" >&2
    exit 1
fi
if tools/build.sh --target android11-5.4 >/dev/null 2>&1; then
    echo "错误：构建脚本接受了非支持的 GKI target" >&2
    exit 1
fi
python3 tests/make-test-init-boot.py --help >/dev/null
python3 tests/test-avb-header-range.py
python3 tests/test-bootconfig-parser.py
python3 tests/test-enforcement-flow.py
python3 tests/test-unified-config.py
tests/test-metadata-config.sh
tests/test-android-flasher-generator.sh
make -C loader clean all

if llvm-readelf -l loader/dsuinit | grep -q INTERP; then
    echo "错误：dsuinit 含动态解释器" >&2
    exit 1
fi
if [[ -n "$(llvm-nm -u loader/dsuinit 2>/dev/null)" ]]; then
    echo "错误：dsuinit 含未解析符号" >&2
    exit 1
fi

echo "静态检查通过"
