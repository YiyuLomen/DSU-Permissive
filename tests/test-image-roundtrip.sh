#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
magiskboot_bin=$(command -v -- "${MAGISKBOOT:-magiskboot}")
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/dsu-permissive-roundtrip.XXXXXX")
trap 'rm -rf -- "$work_dir"' EXIT
mkdir -p "$work_dir/root" "$work_dir/check"

printf '#!/system/bin/sh\n' > "$work_dir/root/init"
printf '原厂 init 占位内容\n' >> "$work_dir/root/init"
printf 'KernelSU ksuinit 测试占位内容\n' > "$work_dir/root/ksuinit-source"
cp -- "$work_dir/root/init" "$work_dir/root/init.real"
cp -- "$work_dir/root/ksuinit-source" "$work_dir/root/init"
printf 'KernelSU 模块测试占位内容\n' > "$work_dir/root/kernelsu.ko"
if [[ -n "${MODULE_UNDER_TEST:-}" ]]; then
    module_under_test=$(realpath -e -- "$MODULE_UNDER_TEST")
else
    clang --target=aarch64-linux-gnu -c "$root_dir/tests/fake_module.S" \
        -o "$work_dir/fake-module.ko"
    module_under_test="$work_dir/fake-module.ko"
fi
chmod 0755 "$work_dir/root/init" "$work_dir/root/init.real"

(
    cd "$work_dir/root"
    printf '%s\n' . init init.real kernelsu.ko | cpio -o -H newc \
        > "$work_dir/ramdisk.cpio" 2>/dev/null
)
"$root_dir/tests/make-test-init-boot.py" \
    --ramdisk "$work_dir/ramdisk.cpio" --output "$work_dir/original.img"
original_init_sha256=$(sha256sum "$work_dir/root/init" | awk '{print $1}')
original_real_sha256=$(sha256sum "$work_dir/root/init.real" | awk '{print $1}')
original_ksu_sha256=$(sha256sum "$work_dir/root/kernelsu.ko" | awk '{print $1}')

if "$root_dir/tools/patch-init-boot.sh" \
    --input "$work_dir/original.img" \
    --output "$work_dir/original.img" \
    --loader "$root_dir/loader/dsuinit" \
    --module "$module_under_test" \
    --magiskboot "$magiskboot_bin" >/dev/null 2>&1; then
    echo "错误：patch 工具未拒绝覆盖输入镜像" >&2
    exit 1
fi
if "$root_dir/tools/unpatch-init-boot.sh" \
    --input "$work_dir/original.img" \
    --output "$work_dir/invalid-restored.img" \
    --magiskboot "$magiskboot_bin" >/dev/null 2>&1; then
    echo "错误：unpatch 工具接受了未安装补丁的镜像" >&2
    exit 1
fi
"$root_dir/tools/patch-init-boot.sh" \
    --input "$work_dir/original.img" \
    --output "$work_dir/patched.img" \
    --loader "$root_dir/loader/dsuinit" \
    --module "$module_under_test" \
    --magiskboot "$magiskboot_bin" >/dev/null
"$root_dir/tools/verify-init-boot.sh" \
    --input "$work_dir/patched.img" --magiskboot "$magiskboot_bin" >/dev/null
if "$root_dir/tools/patch-init-boot.sh" \
    --input "$work_dir/patched.img" \
    --output "$work_dir/double-patched.img" \
    --loader "$root_dir/loader/dsuinit" \
    --module "$module_under_test" \
    --magiskboot "$magiskboot_bin" >/dev/null 2>&1; then
    echo "错误：patch 工具接受了重复补丁" >&2
    exit 1
fi

sh "$root_dir/tools/patch-init-boot-android.sh" \
    --input "$work_dir/original.img" \
    --output "$work_dir/android-patched.img" \
    --loader "$root_dir/loader/dsuinit" \
    --module "$module_under_test" \
    --magiskboot "$magiskboot_bin" >/dev/null
"$root_dir/tools/verify-init-boot.sh" \
    --input "$work_dir/android-patched.img" \
    --magiskboot "$magiskboot_bin" >/dev/null
if sh "$root_dir/tools/patch-init-boot-android.sh" \
    --input "$work_dir/android-patched.img" \
    --output "$work_dir/android-double-patched.img" \
    --loader "$root_dir/loader/dsuinit" \
    --module "$module_under_test" \
    --magiskboot "$magiskboot_bin" >/dev/null 2>&1; then
    echo "错误：Android 修补脚本未拒绝未授权的重复补丁" >&2
    exit 1
fi
cp -- "$module_under_test" "$work_dir/replacement-module.ko"
printf '\0' >> "$work_dir/replacement-module.ko"
sh "$root_dir/tools/patch-init-boot-android.sh" \
    --input "$work_dir/android-patched.img" \
    --output "$work_dir/android-updated.img" \
    --loader "$root_dir/loader/dsuinit" \
    --module "$work_dir/replacement-module.ko" \
    --magiskboot "$magiskboot_bin" \
    --replace-existing >/dev/null
"$root_dir/tools/verify-init-boot.sh" \
    --input "$work_dir/android-updated.img" \
    --magiskboot "$magiskboot_bin" >/dev/null
"$root_dir/tools/unpatch-init-boot.sh" \
    --input "$work_dir/android-updated.img" \
    --output "$work_dir/android-restored.img" \
    --magiskboot "$magiskboot_bin" >/dev/null

"$root_dir/tools/unpatch-init-boot.sh" \
    --input "$work_dir/patched.img" \
    --output "$work_dir/restored.img" \
    --magiskboot "$magiskboot_bin" >/dev/null

cd "$work_dir/check"
"$magiskboot_bin" unpack "$work_dir/restored.img" >/dev/null
for unexpected in init.next dsu_permissive.ko dsu_permissive.meta; do
    if "$magiskboot_bin" cpio ramdisk.cpio "exists $unexpected" >/dev/null 2>&1; then
        echo "错误：往返还原后仍存在 /$unexpected" >&2
        exit 1
    fi
done
"$magiskboot_bin" cpio ramdisk.cpio \
    "extract init restored-init" \
    "extract init.real restored-init.real" \
    "extract kernelsu.ko restored-kernelsu.ko"

[[ "$(sha256sum restored-init | awk '{print $1}')" == "$original_init_sha256" ]]
[[ "$(sha256sum restored-init.real | awk '{print $1}')" == "$original_real_sha256" ]]
[[ "$(sha256sum restored-kernelsu.ko | awk '{print $1}')" == "$original_ksu_sha256" ]]

mkdir -p "$work_dir/android-restored-check"
(
    cd "$work_dir/android-restored-check"
    "$magiskboot_bin" unpack "$work_dir/android-restored.img" >/dev/null
    for unexpected in init.next dsu_permissive.ko dsu_permissive.meta; do
        if "$magiskboot_bin" cpio ramdisk.cpio "exists $unexpected" >/dev/null 2>&1; then
            echo "错误：Android 脚本产物还原后仍存在 /$unexpected" >&2
            exit 1
        fi
    done
    "$magiskboot_bin" cpio ramdisk.cpio \
        "extract init restored-init" \
        "extract init.real restored-init.real" \
        "extract kernelsu.ko restored-kernelsu.ko"
    [[ "$(sha256sum restored-init | awk '{print $1}')" == "$original_init_sha256" ]]
    [[ "$(sha256sum restored-init.real | awk '{print $1}')" == "$original_real_sha256" ]]
    [[ "$(sha256sum restored-kernelsu.ko | awk '{print $1}')" == "$original_ksu_sha256" ]]
)
echo "boot/init_boot 补丁/还原往返测试通过"
