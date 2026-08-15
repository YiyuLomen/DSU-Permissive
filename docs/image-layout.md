# boot/init_boot ramdisk 布局

Android 12 出厂设备的通用 ramdisk 位于 `boot.img`；Android 13 及以上出厂设备通常将其放在 `init_boot.img`。下述逻辑要求输入镜像的 ramdisk 中存在首个 `/init`，与镜像文件名无关。

## KernelSU 补丁后的输入

预期的 KernelSU LKM 输入布局为：

```text
/init           KernelSU ksuinit
/init.real      原厂 init
/kernelsu.ko    KernelSU 模块
```

## DSU-Permissive 补丁后的输出

```text
/init                    dsuinit
/init.next               原有 /init，即 KernelSU ksuinit
/init.real               原厂 init，保持不变
/kernelsu.ko              KernelSU 模块，保持不变
/dsu_permissive.ko        新模块
/dsu_permissive.meta      可逆操作所需的格式和 SHA-256
```

`ksuinit` 的当前实现会在加载 KernelSU 后删除 `/init`，根据 `/init.real` 创建新的 `/init` 链接，再执行 `/init`。因此它虽然被移动到 `/init.next`，仍会正确转交 `/init.real`，不会重新执行 dsuinit。

patch 工具把输入镜像作为 repack 模板，所有操作在独立临时目录完成，最后才创建新的输出文件。它拒绝：

- 输入与输出为同一路径；
- 输出已存在；
- ramdisk 缺少 `/init`；
- 已存在 `/init.next`、`/dsu_permissive.ko` 或元数据；
- loader/KO 不是预期的 AArch64 ELF 产物。

unpatch 工具根据元数据验证原 init、loader 和 KO 的 SHA-256，再恢复 `/init.next → /init`。由于 magiskboot 可能重新压缩 ramdisk，“可逆”指条目与内容逻辑还原，不承诺输出镜像与原输入逐字节一致。
