# DSU-Permissive

DSU-Permissive 面向 arm64、Android 16/17 与 `android16-6.12` KMI。它在 PID 1 的 first-stage 确认当前系统确实是 DSU 后，只修改返回给该进程的顶层 vbmeta 读取视图，让后期 `libfs_avb` 将本次 DSU 启动识别为 `VerificationDisabled`；随后在 `selinux_setup` 阶段优先让原厂 init 读取到临时的：

```text
androidboot.selinux = "permissive"
```

对于以 `ALLOW_PERMISSIVE_SELINUX=0` 编译、会忽略该参数的 `user` init，模块再通过 SELinux 自身的原始 `enforce` file operation 执行一次启动期 permissive。AVB 路径要求 bootloader 已报告 `verifiedbootstate=orange`，且 DSU 未放置 `/metadata/gsi/dsu/avb_enforce`。项目不写入或签名 vbmeta，不修改 system 或 DSU 文件，不定位或直接改写 `selinux_state`，不持续拦截 `setenforce`，也不依赖 KernelSU 源码。当前集成目标是已经由外部启动链允许启动、并由 KernelSU LKM 补丁处理过的 `init_boot.img`。

## 工作链

```text
内核执行 /init
  → dsuinit 加载 /dsu_permissive.ko
  → dsuinit 执行 /init.next
  → KernelSU ksuinit 加载 /kernelsu.ko
  → ksuinit 将 /init 重建为指向 /init.real 的链接
  → 原厂 first-stage init
  → PID 1 读取宿主顶层 vbmeta
  → 仅返回缓冲区中的 flags 被临时 OR 0x02
  → libfs_avb 返回 VerificationDisabled，跳过该 AVB handle 的 Hashtree
  → /system/bin/init selinux_setup
  → 仅 PID 1 看到带 permissive 前缀的 /proc/bootconfig
  → 允许 permissive 的 init 调用 security_setenforce(false)
  → user init 读取 selinuxfs/enforce 时触发一次原始 enforce 写 0
  → /system/bin/init second_stage，Hook 注销
  → 后续手动 setenforce 1 走原厂路径
```

正常系统即使进入同一 init 流程，也必须存在 AOSP first-stage init 在
DSU 映射成功后写入的运行标记，AVB 返回视图、bootconfig 注入和启动期
enforce fallback 才会生效：

```text
/metadata/gsi/dsu/booted
```

first-stage init 会在每次判断 DSU 前删除旧标记，因此正常启动不会沿用
上一次 DSU 的状态。`init.gsi.rc` 只用于判断系统镜像是否为特定 GSI，
不是 DSU 正在运行的条件，非 AOSP GSI 也可能不包含该文件。

## 构建

本项目固定 DDK target 为 `android16-6.12`：

```bash
cd /home/yango/DSU-Permissive
tools/build.sh
```

成功后产物位于：

```text
out/dsuinit
out/dsu_permissive.ko
```

也可以只构建不依赖内核头文件的 loader：

```bash
make -C loader
```

## 修改 init_boot 镜像

工具只接受明确的输入和输出路径，拒绝覆盖输入或已有输出，不刷写、不签名：

```bash
tools/patch-init-boot.sh \
  --input /path/to/kernelsu-patched-init_boot.img \
  --output /path/to/dsu-permissive-init_boot.img \
  --loader out/dsuinit \
  --module out/dsu_permissive.ko
```

验证镜像：

```bash
tools/verify-init-boot.sh \
  --input /path/to/dsu-permissive-init_boot.img
```

生成逻辑还原镜像：

```bash
tools/unpatch-init-boot.sh \
  --input /path/to/dsu-permissive-init_boot.img \
  --output /path/to/restored-init_boot.img
```

还原会验证补丁时记录的三个 SHA-256；只要 `/init`、`/init.next` 或模块被其他工具继续修改，就会拒绝自动还原，避免破坏未知 init 链。

## 重要限制

- 设备内核必须启用模块、kprobe 与 `CONFIG_SECURITY_SELINUX_DEVELOP`，并允许加载对应签名策略下的 KO。
- AVB 后期旁路只适用于 bootloader 已报告 `verifiedbootstate=orange` 的解锁设备；若存在 `/metadata/gsi/dsu/avb_enforce`，模块会拒绝修改读取视图。
- 模块不会绕过 bootloader 对 `init_boot` 或磁盘 vbmeta 的校验，也不会写入、签名或持久修改 vbmeta。修改只存在于 DSU first-stage PID 1 的单次读取返回缓冲区中。
- 顶层 `VERIFICATION_DISABLED` 会让本次 DSU 启动中由同一个 AVB handle 管理的 system、vendor、odm 等分区跳过 Hashtree，而不只影响 DSU system；正常启动仍读取磁盘原始 vbmeta。
- 启动期 enforce fallback 只执行一次；second-stage 后模块不会阻止手动或系统主动切回 Enforcing。
- 产物检查会拒绝导入该设备 GKI 签名保护不允许的 `kernel_write` / `vfs_fsync` 系列符号。
- DDK 的通用 KMI 构建成功不等同于所有厂商 6.12 内核都可运行，真机前必须核对 vermagic、符号与模块签名要求。
- 项目工具不会执行 fastboot 或刷写命令。

完整设计见 [docs/design.md](docs/design.md)，镜像布局见 [docs/image-layout.md](docs/image-layout.md)，验证说明见 [docs/testing.md](docs/testing.md)。
