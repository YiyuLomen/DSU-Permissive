# Hook 设计

## 目标与边界

目标是在 DSU 已经完成映射后完成三件事：先在 first-stage 的 AVB 复验窗口内，只向 PID 1 临时呈现 `androidboot.verifiedbootstate=orange` 与带 `HASHTREE_DISABLED` 标志的顶层 vbmeta；该 flag 保留链式 vbmeta 的加载，同时让同一 AVB handle 的 Hashtree 全部跳过。然后在 `/dev/device-mapper` 的 `DM_DEV_CREATE`/`DM_TABLE_LOAD` 协议层记录 `*_gsi` 的实际设备号与扇区数；若厂商仍尝试为这些 GSI 映射加载单 target `verity` table，则在调用内核 dm target 前把它改为同容量 `linear` table，避免无 footer 镜像落入厂商内置 hash/FEC fallback。进入 `selinux_setup` 后再同步呈现 `androidboot.veritymode=disabled`，避免 vivo `vfcheck` 仍按 `eio` 模式探测关键文件；同时优先复用原厂 `androidboot.selinux=permissive` 路径，并兼容以 `ALLOW_PERMISSIVE_SELINUX=0` 编译的 `user` init。模块不写磁盘 vbmeta，不持久化 verified boot/verity 状态，不定位或直接写 `selinux_state`，也不 Hook `security_setenforce()` 或持续拦截 enforce 写入。

模块只支持 arm64 GKI，以及 `android12-5.10`、`android13-5.10`、`android13-5.15`、`android14-5.15`、`android14-6.1`、`android15-6.6`、`android16-6.12` 七个 DDK target。对应的 AOSP Android 12 至 Android 16 init 均在加载 policy 后调用 `SelinuxSetEnforcement()`，并通过 fs_mgr 读取 cmdline/bootconfig；fs_mgr 对重复 bootconfig 键采用第一项。Android 11 及以下和非 GKI 内核不在支持范围内。

## 统一配置链

统一配置由修补器写入 boot/init_boot ramdisk：

```text
/dsu_permissive.conf
```

内容固定为：

```text
selinux_intercept=0|1
avb_intercept=0|1
```

`dsuinit` 位于 first-stage init 之前，因而在加载 KO 前以普通用户空间 syscall 打开配置。配置严格限制为两行、固定键序和 `0|1` 值；读取前必须 unlink 成功，随后通过仍打开的 FD 读取，并在传给 `finit_module()` 后关闭。ramdisk 条目权限是 `0600`，模块参数权限为 `0000`，不创建 sysfs 可读节点。进入 `/init.next` 之前没有配置文件路径可供后续程序打开。离线 root/recovery 仍能读取 raw boot 镜像，这是镜像本身的信任边界。

厂商 GKI 对外部 LKM 的符号策略不能只由 DDK 编译判断：已观察到 `filp_open` 未导出、`dentry_open` 位于仅供文件系统实现使用的内部命名空间、`kernel_read` 被标记为 protected symbol。为避免 KO 在 PID 1 first-stage 加载时直接失败，模块不导入 `filp_open`、`dentry_open`、`kernel_read` 或 `filp_close`，只从 `finit_module()` 接收两个布尔参数。`selinux_intercept=0` 禁用 permissive bootconfig 注入与 enforce 切换；`avb_intercept=0` 让 vbmeta 代理始终透传原始读取结果，并且不注入 orange 或 `veritymode=disabled`。未指定修补器参数时两项均为 `1`。

模块仍通过 `kern_path()` 检查 DSU 标记并解析 vbmeta by-name 路径，因此同时声明 `ANDROID_GKI_VFS_EXPORT_ONLY` 与 `VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver` 两个独立的 import namespace。部分厂商 6.6 GKI 会对 `kern_path` 强制校验后一个 namespace；缺失时 `finit_module()` 会以 `EINVAL` 失败并记录 `Unknown symbol kern_path (err -22)`。

需要变更开关时重新修补镜像；Android 端 `repatch-init-boot-config-android.sh` 用 `--replace-existing --reuse-existing` 验证旧补丁，然后只替换内嵌配置并保留 loader、KO 和原 init。

## 状态机

```text
WAIT_SYSTEM_INIT
  │ 后台解析 by-name/vbmeta[_a|_b] 的块设备 dev_t
  │ PID 1 读取目标块设备，且 DSU booted 标记存在
  │ avb_enforce 不存在时，对 PID 1 的 bootconfig 临时注入 orange
  │ 仅修改 vbmeta 返回缓冲区的 HASHTREE_DISABLED flag
  │ 截获 PID 1 的 device-mapper ioctl，记录 *_gsi 映射设备号和容量
  │ 仅将以已记录 GSI 为数据设备的单 target verity table 改为 linear
  │ 磁盘内容与其他进程视图保持不变
  │ PID 1 第一次 exec /system/bin/init
  ▼
SELINUX_SETUP_ARMED
  │ PID 1 读取 procfs 根目录的 bootconfig
  │ vbmeta 返回视图实际修改成功时同步注入 veritymode=disabled
  │ SELinux 拦截生效时注入 selinux=permissive
  │ selinux_setup 窗口内后续读取同样处理
  │ PID 1 读取 selinuxfs 根目录的 enforce
  │ 通过原始 enforce write fop 执行一次 permissive
  │ 仅在该窗口向 PID 1 报告 enforcing
  │
  ├─ PID 1 第二次 exec /system/bin/init
  └─ 模块加载后 120 秒超时
  ▼
DRAINING
  │ workqueue 注销 tracepoint 与 kprobe
  ▼
DISABLED
  │ Hook 已全部退出
```

AVB 代理必须在 `WAIT_SYSTEM_INIT` 生效：目标设备日志中的顶层 vbmeta 处理发生在约 `0.603s`，而 PID 1 第一次 exec `/system/bin/init`、进入 `SELINUX_SETUP_ARMED` 是约 `0.628s`。阶段切换后，即使目标 file 尚未关闭，代理 read wrapper 也只透传原始内容。

状态机与早期观察点始终存在到 second-stage 或超时，以确保不会错过 first-stage 窗口。关闭某一路径时，对应 wrapper 可能仍完成一次原始读取，但不会注入或修改数据；共同的阶段门控继续负责及时注销所有观察点。

在整个 `selinux_setup` 窗口内处理 PID 1 的每次 bootconfig 打开，而不是假设第一次读取一定来自 `StatusFromProperty()`。这样可容纳 init 或其库在 enforcement 决策前新增其他 bootconfig 查询。作用域仍限定为 PID 1、指定阶段和单个 `/proc/bootconfig` file。

## vbmeta fops 代理

`vbmeta_proxy.c` 用 delayed work 在普通内核上下文中轮询解析以下符号链接，并保存最终块设备 inode 的 `dev_t`：

```text
/dev/block/by-name/vbmeta
/dev/block/by-name/vbmeta_a
/dev/block/by-name/vbmeta_b
/dev/block/bootdevice/by-name/vbmeta[_a|_b]
```

不能比较打开后的 dentry 名，因为 by-name 符号链接通常会落到 `sdeNN` 等真实节点；也不硬编码 major/minor 或访问非稳定的块层内部结构。`vfs_read` kprobe pre-handler 只执行阶段、PID、块设备类型和缓存 `dev_t` 比较，不在 kprobe 上下文中调用 `kern_path()` 或访问用户内存。

AOSP `libfs_avb` 通过 `pread64(offset=0)` 读取顶层 vbmeta。支持的 GKI 默认块设备路径使用 `read_iter`，代理仍同时接受原 fops 提供旧式 `read` 的情况，并在完整复制原 fops 后只覆盖：

- `owner = THIS_MODULE`；
- `read = proxy_read`；
- `release = proxy_release`。

当前 `vfs_read` 在 kprobe 返回后会优先进入代理 `read`。wrapper 按内核 `new_sync_read()` 的方式构造同步 `kiocb`：6.1 及以上使用 `iov_iter_ubuf()`，5.10/5.15 使用单段 `iovec` 与 `iov_iter_init()`，再通过保存的原 `read_iter` 函数指针完成真实读取。代理保留原 `read_iter`，所以 readv、io_uring 等非目标路径不会被扩展为 AVB 旁路。

真实读取完成后，普通进程上下文再次确认：

- 当前仍为 `WAIT_SYSTEM_INIT` 且 PID 为 1；
- `/metadata/gsi/dsu/booted` 存在；
- `/metadata/gsi/dsu/avb_enforce` 不存在；
- 返回缓冲区开头是 `AVB0`；
- 实际返回区间包含 flags 的目标字节。

`AvbVBMetaImageHeader.flags` 位于 `[120,124)`，序列化时使用网络字节序。`AVB_VBMETA_IMAGE_FLAGS_HASHTREE_DISABLED` 是 `1 << 0`，因此代理只对绝对偏移 `123` 的原字节执行 `OR 0x01`。例如 `0x80000002` 变为 `0x80000003`，其他位不会被覆盖。修改发生在用户读取缓冲区，磁盘分区、页缓存中的源数据和其他进程视图均不改变。

修改 flags 会使 vbmeta 的签名或 bootloader 提供的摘要不再匹配。first-stage 中，bootconfig 代理会在 PID 1 读取 `/proc/bootconfig` 时把 `androidboot.verifiedbootstate = "orange"` 放在原始条目之前；AOSP `fs_mgr` 对重复键取首项，因而 `IsDeviceUnlocked()` 会允许验证错误，并继续把修改后的顶层 header 识别为 `HashtreeDisabled`。该状态不会让 libavb 提前丢弃链式 vbmeta，因而可继续得到 vendor/odm descriptor；随后 fs_mgr 对同一 AVB handle 的所有 Hashtree 都跳过。代理只在 `WAIT_SYSTEM_INIT` 阶段选择这个前缀，首次 exec `/system/bin/init` 后的 SELinux 视图不含该键，second-stage 读取的仍是 bootloader 原始状态。若 `avb_enforce` 存在，则不注入 orange、不修改 vbmeta 并记录错误，避免在强制验证模式下把启动变成硬失败。

顶层状态为 `HashtreeDisabled` 后，同一个 `AvbHandle` 管理的分区都会跳过 Hashtree，同时保留链式 vbmeta descriptor，包括本次 DSU 启动涉及的宿主 vendor、odm 等条目，不仅是 DSU system。该影响仅存在于本次 first-stage 的内存视图，正常启动仍使用磁盘上的真实 vbmeta。

## 无 footer GSI 的 device-mapper 兜底

部分厂商 init 在 GSI system 没有独立 AVB footer 时，不会因顶层 `HashtreeDisabled` 直接挂载，而是从自带 fstab/参数构造 `verity` table。vivo 样本中这张表假设的 hash/FEC 设备容量大于 `system_gsi`，内核在 `DM_TABLE_LOAD` 返回 `Hash device is too small (-E2BIG)`，随后 PID 1 因 `/system` 无法挂载退出。

`dm_ioctl_proxy` 不调用未导出的 dm 内核函数。它优先在 PID 1 first-stage 的 device-mapper `dm_ctl_ioctl` 实际 `unlocked_ioctl` 入口挂接 file-operation 代理；若该静态符号不可被 kprobe 解析，才在 `vfs_ioctl` 入口按稳定的 `DM_IOCTL` UAPI magic 回退识别。代理在正常 ioctl 上下文中只负责记录 `DM_DEV_CREATE` 结果和布置 first-stage 策略；随后在 dm core 的 `table_load(file, param, param_size)` 入口处理已经复制到内核的表参数：

- `DM_DEV_CREATE` 成功返回后，记录名称以 `_gsi` 结尾且不等于 `userdata_gsi` 的映射设备号；
- 该映射的 `DM_TABLE_LOAD` 的内核 `param_size` 提供实际表末端扇区数，记录为可用容量；这一步同时按名称和 `dm_ioctl.dev` 的 `huge_encode_dev()` 值关联，因为厂商/平台 libdm 可用 `dev` 而非 `name` 选择已有映射；
- DSU active、`avb_intercept=1`、不存在 `avb_enforce` 时，解析后续单 target `verity` table 的 data-device token；只有它指向已记录的 `*_gsi` 时才把内核参数缓冲区内的 target type 和参数改为 `linear <same-device> 0`，并把 target length 改为记录的真实容量。

这里不能用 `param->data_size` 作为 target payload 边界：Android 15 / Linux 6.6 的 `ctl_ioctl()` 在调用 `table_load()` 前会把它复位为 `offsetof(struct dm_ioctl, data)`。模块使用第三参数 `param_size`；因此也不再从 fops proxy 对同一用户指针进行第二次 `copy_from_user()`。这规避了 vivo first-stage fallback 请求可被 dm core 正常处理、但额外 header 读取失败的路径。

因此规则同时覆盖 `/dev/block/dm-N`、`/dev/mapper/<name>`、`/dev/block/mapper/<name>` 与 `major:minor` 四种 libdm data-device 表示；不命中、多个 target、非零 start、非 DSU、非 PID 1、second-stage、`avb_enforce` 或非 GSI backing 均原样透传。

## exec 门控

`exec_gate.c` 通过 `for_each_kernel_tracepoint()` 查找 `sched_process_exec`，再用通用 tracepoint 注册接口挂载回调。回调只检查：

- `task->pid == 1`
- `bprm->filename` 精确等于 `/system/bin/init`

第一次命中对应 `selinux_setup`，第二次命中对应 `second_stage`。不读取用户态 argv，也不替换原厂 init 函数。

## bootconfig fops 代理

`bootconfig_proxy.c` 在 `vfs_read` 入口安装 kprobe，并且只在 `WAIT_SYSTEM_INIT` 或 `SELINUX_SETUP_ARMED` 阶段工作。pre-handler 不执行路径查找或其他可睡眠操作，只完成：

- 状态与 PID 检查；
- `PROC_SUPER_MAGIC`、根 dentry 和 `bootconfig` 文件名检查；
- 从预分配槽位复制原 `file_operations`；
- 将当前 `struct file` 的 `f_op` 切到代理。

支持的 GKI 均提供 `/proc/bootconfig`。代理同时兼容原 fops 的 `read_iter` 和旧式 `read`，并代理 `llseek` 与 `release`。代理槽位在模块初始化时静态分配，kprobe 上下文不分配内存。

真正的 DSU 检查在代理 read 的普通进程上下文执行，可安全调用 VFS 路径查找。只有以下 AOSP DSU 运行标记存在时才启用注入：

```text
/metadata/gsi/dsu/booted
```

AOSP 的 `IsGsiRunning()` 仅使用该标记。first-stage init 会在判断 DSU 前
删除旧标记，并且只在 DSU 映射成功后重新创建，因此正常启动不会因残留
状态被误判。`/system/system_ext/etc/init/init.gsi.rc` 属于
`IsGsiImage()` 的镜像类型判断，不能作为 DSU 运行条件：非 AOSP GSI
可以通过 DSU 启动但不包含该文件。

## 流视图

在 `WAIT_SYSTEM_INIT`，仅当 AVB 拦截开启且不存在 `avb_enforce` 时，注入视图为：

```text
androidboot.verifiedbootstate = "orange"\n
<原始 /proc/bootconfig 内容>
```

在 `SELINUX_SETUP_ARMED`，AVB 与 SELinux 两个开关分别选择前缀。两项均开启时视图为：

```text
androidboot.veritymode = "disabled"\n
androidboot.selinux = "permissive"\n
<原始 /proc/bootconfig 内容>
```

只开启 AVB 且 vbmeta 返回视图实际修改成功时仅注入 `veritymode=disabled`；只开启 SELinux 时仅注入 `selinux=permissive`。`avb_enforce` 存在或 vbmeta 代理未命中时不覆盖 `veritymode`。

代理把外部位置解释为“前缀长度 + 原文件位置”。读取前缀时不推进原 procfs 的位置；读取原内容前临时减去前缀长度，返回后再恢复逻辑位置。其他进程和其他文件对象始终使用原 fops。

代理 fops 的 owner 指向本模块。附加时取得模块引用，`__fput()` 在代理 `release` 返回后释放该引用，避免 file 尚未关闭时卸载模块代码。原 procfs fops 必须属于内核本体（owner 为空），否则拒绝附加。

first-stage orange 视图只影响从 `/proc/bootconfig` 读取 `verifiedbootstate` 的 `fs_mgr` 调用；device tree、已存在的 `ro.boot.verifiedbootstate` 与 `/proc/cmdline` 优先级更高时不会被改变。它不修改 `androidboot.vbmeta.device_state`，也不影响 KeyMint/TEE attestation。second-stage 注销后读取到的仍是原始 bootconfig。

`selinux_setup` 的 `veritymode=disabled` 视图用于让厂商 init 与已经得到的 `HashtreeDisabled` AVB handle 保持一致。静态分析的 vivo `SetupSelinux()` 只在 `veritymode=eio` 时执行 critical-file 读/xattr 探测，并在 `EIO` 时写入 `boot-survival` 后重启；`disabled` 会跳过该路径。覆盖只对这一阶段的 PID 1 file 生效，second-stage 恢复原始 bootconfig。

## selinuxfs enforce 启动期 fallback

AOSP Android 12 及以上的 `user` init 默认以 `ALLOW_PERMISSIVE_SELINUX=0`
编译。此时 `IsEnforcing()` 无条件返回 true，即使 bootconfig 注入成功也
不会调用 `security_setenforce(false)`。

`selinux_enforce_proxy.c` 因此在同一 `vfs_read` Hook 点仅识别：

- PID 1 与 `SELINUX_SETUP_ARMED` 阶段；
- `SELINUX_MAGIC` 文件系统根目录下名为 `enforce` 的文件；
- `/metadata/gsi/dsu/booted` 已存在。

代理先执行原始 `sel_read_enforce()`。第一次位置为 0 的有效读取会把该
用户缓冲区暂时置为 `0`，再调用当前 file 保存的原始 write fop。实际
执行的仍是内核 `sel_write_enforce()`，因此保留
`SECURITY__SETENFORCE` 权限检查、审计、状态页更新、通知和 LSM
notifier；模块不解析 `selinux_state`，也不依赖其随机化布局。

写入成功后，代理仅向这次启动窗口内的 PID 1 报告 `1`：

- permissive 已被允许的 init 通过 bootconfig 得到 desired=false，看到
  observed=true 后仍会走原厂 `security_setenforce(false)`；
- `user` init 的 desired=true，看到 observed=true 后不会把已经完成的
  permissive 写回 enforcing。

全局原子状态确保原始 write fop 最多调用一次。模块不 Hook
`vfs_write`；PID 1 第二次 exec `/system/bin/init` 后注销三个
`vfs_read` kprobe，后续 `setenforce 1` 及厂商主动切回 Enforcing 均走
原厂路径。

## 为什么等价于 boot 参数路径

fs_mgr 的 `GetBootconfigFromString()` 在首次找到目标 key 后不再覆盖结果。前缀因此优先于原 bootconfig 中可能存在的 `androidboot.selinux=enforcing`。允许 permissive 的 init 随后仍执行 `security_setenforce(false)`；`user` init 则由启动期 fallback 调用同一个内核 `sel_write_enforce()` 路径。SELinux 状态页、通知和审计仍由原始实现维护。

模块不负责在 second stage 后持续拦截 enforcing，也不会锁定 permissive。开机完成后手动 `setenforce 1` 必须可以恢复 Enforcing。

## 失败策略

- KO 打开或加载失败：`dsuinit`记录错误并继续原 init 链。
- 内嵌配置缺失、无法 unlink、读取失败或语法无效：loader 不传参数，模块使用默认 `1/1`，并记录错误；修补器与镜像验证器会拒绝生成或验证非严格格式的 format=3 镜像。
- KO 与设备 GKI/KMI target 不匹配：内核拒绝加载，`dsuinit`记录错误并继续原 init 链。
- `/init.next` 执行失败：依次尝试 `/init.real` 与 `/system/bin/init`，所有失败均记录。
- tracepoint 或 kprobe 注册失败：KO 加载失败并保留明确内核日志，系统启动仍由 loader 继续。
- vbmeta by-name 路径未及时解析或目标 read 未命中：不修改任何块设备数据，`libfs_avb` 按原始结果继续。
- `fs_mgr` 不从 `/proc/bootconfig` 读取 `verifiedbootstate`：模块无法伪装该来源；修改后的签名错误可能不被接受，因此启动不满足使用前提。
- `/metadata/gsi/dsu/avb_enforce` 存在：拒绝修改 vbmeta 返回视图并记录错误。
- `selinux_setup` 没有从 `/proc/bootconfig` 读取 `veritymode`：无法覆盖厂商从其他来源取得的值，vivo 兼容路径需要真机日志确认。
- vbmeta 魔数不匹配或用户缓冲区修改失败：保留原 read 返回值、记录错误，`libfs_avb` 看到原始数据。
- DSU booted 标记不存在：读取原 bootconfig，不注入。
- 原始 enforce write fop 不存在或调用失败：保留原始 enforce 读值并记录错误，系统继续以原状态启动。
- 120 秒内未完成阶段切换：注销 Hook。
