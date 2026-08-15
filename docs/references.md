# 一手参考

- Android 16 init SELinux 流程：<https://android.googlesource.com/platform/system/core/+/refs/heads/android16-release/init/selinux.cpp>
- Android 16 init `ALLOW_PERMISSIVE_SELINUX` 构建开关：<https://android.googlesource.com/platform/system/core/+/refs/heads/android16-release/init/Android.bp>
- Android 主线 init SELinux 流程：<https://android.googlesource.com/platform/system/core/+/refs/heads/main/init/selinux.cpp>
- fs_mgr bootconfig 首项解析：<https://android.googlesource.com/platform/system/core/+/refs/heads/android16-release/fs_mgr/libfstab/boot_config.cpp>
- Android 16 `IsDeviceUnlocked()` 的 orange 判定：<https://android.googlesource.com/platform/system/core/+/refs/heads/android16-release/fs_mgr/libfs_avb/util.cpp>
- Android 16 顶层 vbmeta 加载、验证错误与 disabled flags：<https://android.googlesource.com/platform/system/core/+/refs/heads/android16-release/fs_mgr/libfs_avb/fs_avb.cpp>
- AVB vbmeta header、网络字节序与 flags 定义：<https://android.googlesource.com/platform/external/avb/+/refs/heads/android16-release/libavb/avb_vbmeta_image.h>
- Android 16 DSU `IsGsiRunning()` 与 booted 标记生命周期：<https://android.googlesource.com/platform/system/gsid/+/refs/heads/android16-release/libgsi.cpp>
- Android 17 DSU `IsGsiRunning()` 与 booted 标记生命周期：<https://android.googlesource.com/platform/system/gsid/+/refs/heads/android17-release/libgsi.cpp>
- DSU 映射后写入 booted 标记：<https://android.googlesource.com/platform/system/core/+/refs/heads/android16-release/init/first_stage_mount.cpp>
- Android 16 6.12 `vfs_read`：<https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12/fs/read_write.c>
- Android 16 6.12 默认块设备 fops：<https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12/block/fops.c>
- Android 16 6.12 `__fput()` / `fops_put()` 生命周期：<https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12/fs/file_table.c>
- Android 16 6.12 procfs fops：<https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12/fs/proc/inode.c>
- Android 16 6.12 SELinux enforce fops：<https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12/security/selinux/selinuxfs.c>
- Android 16 6.12 exec tracepoint：<https://android.googlesource.com/kernel/common/+/refs/heads/android16-6.12/include/trace/events/sched.h>
- KernelSU `ksuinit` 入口：<https://github.com/tiann/KernelSU/blob/main/userspace/ksuinit/src/main.rs>
- KernelSU init 重建逻辑：<https://github.com/tiann/KernelSU/blob/main/userspace/ksuinit/src/init.rs>
