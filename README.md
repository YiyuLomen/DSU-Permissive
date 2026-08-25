# DSU-Permissive

DSU-Permissive 面向 arm64 GKI，支持 `android12-5.10`、`android13-5.10`、`android13-5.15`、`android14-5.15`、`android14-6.1`、`android15-6.6` 与 `android16-6.12` 七个 DDK target。SELinux、AVB 与 dm-verity 表伪造配置在修补时写入 `init_boot` ramdisk；前两项默认开启，表伪造默认关闭。启动器在加载 KO 前读取并立即删除配置文件，再将结果作为模块参数传入。在 PID 1 的 first-stage 确认当前系统确实是 DSU 后，AVB 拦截会临时让 `libfs_avb` 从 `/proc/bootconfig` 读取到 `verifiedbootstate=orange`，并只修改该进程的顶层 vbmeta 读取视图，将顶层 `HASHTREE_DISABLED` flag（bit 0）临时打开，使链式 vbmeta 仍能被加载、但本次 DSU 启动跳过所有 Hashtree。若显式开启表伪造，模块会在同一 first-stage 截获 PID 1 的 `/dev/device-mapper` 协议：对 data/hash 均为同一已记录 `*_gsi` 映射的单 target `verity` table，统一改为不超过该映射容量的 `linear` table；不以表尺寸猜测其 hash tree 是否可信。宿主分区和 `userdata_gsi` 不在此范围。确认 vbmeta 返回视图实际修改成功后，进入 `selinux_setup` 还会让 PID 1 临时读取到 `veritymode=disabled`，使 vivo 等厂商 init 的完整性检查状态与 AVB disabled 视图一致。随后优先让原厂 init 读取到临时的：

```text
androidboot.selinux = "permissive"
```

对于以 `ALLOW_PERMISSIVE_SELINUX=0` 编译、会忽略该参数的 `user` init，SELinux 拦截开启时模块再通过 SELinux 自身的原始 `enforce` file operation 执行一次启动期 permissive。AVB 拦截开启时要求外部启动链已经允许当前镜像加载，DSU 未放置 `/metadata/gsi/dsu/avb_enforce`，并且 Android 的 first-stage 通过 `/proc/bootconfig` 读取 `verifiedbootstate`；该窗口仅对 first-stage PID 1 注入 `orange`，second-stage 仍读取 bootloader 原始状态。项目不写入或签名 vbmeta，不修改 system 或 DSU 文件，不定位或直接改写 `selinux_state`，不持续拦截 `setenforce`，也不依赖 KernelSU 源码。当前集成目标是已经由外部启动链允许启动、并由 KernelSU LKM 补丁处理过的 Android 12 `boot.img` 或 Android 13 及以上 `init_boot.img`。

## 工作链

```text
内核执行 /init
  → dsuinit 加载 /dsu_permissive.ko
  → dsuinit 执行 /init.next
  → KernelSU ksuinit 加载 /kernelsu.ko
  → ksuinit 将 /init 重建为指向 /init.real 的链接
  → 原厂 first-stage init
  → PID 1 从 /proc/bootconfig 临时读取 verifiedbootstate=orange
  → PID 1 读取宿主顶层 vbmeta
  → 仅返回缓冲区中的 flags 被临时 OR 0x01
  → libfs_avb 保留链式 vbmeta，并以 HashtreeDisabled 跳过该 AVB handle 的 Hashtree
  → PID 1 创建 *_gsi device-mapper 映射并记录真实扇区数
  → 若刷入时开启表伪造，将匹配的 DSU GSI verity table 统一改为 linear
  → /system/bin/init selinux_setup
  → 仅 PID 1 看到 veritymode=disabled 与可选的 permissive 前缀
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

## 统一配置

修补器将如下严格三行配置写入 ramdisk：

```text
/dsu_permissive.conf
```

内容为：

```text
selinux_intercept=1
avb_intercept=1
verity_table_spoof=0
```

三个键必须各出现一次，值只能是 `0` 或 `1`：

| 配置 | `1` | `0` |
| --- | --- | --- |
| `selinux_intercept` | 允许 bootconfig 注入与 selinuxfs/enforce 启动期切换 | 不注入 bootconfig，也不执行 permissive 切换 |
| `avb_intercept` | 修改 first-stage vbmeta 返回视图；实际修改成功后在 selinux_setup 同步 `veritymode=disabled` | 始终透传原始 vbmeta/DM table 数据且不覆盖 `veritymode` |
| `verity_table_spoof` | 在 `avb_intercept=1` 时，统一将匹配的 DSU GSI first-stage `verity` 表伪装为 `linear` | 所有 dm-verity 表原样透传 |

三项可以显式指定：`--selinux 0|1`、`--avb 0|1`、`--verity-table-spoof 0|1`。默认值为 `1/1/0`，交互终端只会询问未指定的项。表伪造依赖 AVB 拦截；`--avb 0` 时即使填写 `--verity-table-spoof 1` 也不会改写表。KO 不读取任何配置文件，因此不会导入厂商 GKI 可能拒绝的 `dentry_open()`、`kernel_read()` 等符号。模块参数不创建 sysfs 可读节点。

`/dsu_permissive.conf` 在 ramdisk 中的权限为 `0600`。`dsuinit` 以 `O_NOFOLLOW|O_CLOEXEC` 打开它后必须先 unlink 成功才读取；读取后立即关闭 FD。因此，进入后续 init 链的其他程序没有可打开的配置路径。raw `boot/init_boot` 镜像仍可被拥有离线 root/recovery 权限的一方提取，这不是运行时文件权限能够防止的。更改开关需要重新修补镜像；已修补镜像可用 `repatch-init-boot-config-android.sh` 仅替换配置并保留 loader、KO 和原 init。

## 构建

支持矩阵按 GKI KMI 世代限定，不支持非 GKI 内核：

| DDK target | Android KMI 世代 |
| --- | --- |
| `android16-6.12` | Android 16 |
| `android15-6.6` | Android 15 |
| `android14-6.1` | Android 14 |
| `android14-5.15` | Android 14 |
| `android13-5.15` | Android 13 |
| `android13-5.10` | Android 13 |
| `android12-5.10` | Android 12 |

不带参数时仍构建当前默认的 `android16-6.12`：

```bash
cd /home/yango/DSU-Permissive
tools/build.sh
```

构建单个目标或全部目标：

```bash
tools/build.sh --target android15-6.6
tools/build.sh --all
```

成功后 loader 由所有目标共用，KO 按 DDK target 隔离：

```text
out/dsuinit
out/patch-init-boot-android.sh
out/repatch-init-boot-config-android.sh
out/magiskboot-arm64
out/dsu-permissive-android-flasher.sh  # 仅 --all 生成，运行时自动识别 KMI
out/dsu_permissive-android16-6.12.ko
out/dsu_permissive-android15-6.6.ko
out/dsu_permissive-android14-6.1.ko
out/dsu_permissive-android14-5.15.ko
out/dsu_permissive-android13-5.15.ko
out/dsu_permissive-android13-5.10.ko
out/dsu_permissive-android12-5.10.ko
```

也可以只构建不依赖内核头文件的 loader：

```bash
make -C loader
```

## 修改 boot/init_boot 镜像

Android 12 出厂设备使用包含通用 ramdisk 的 `boot.img`，Android 13 及以上出厂设备通常使用 `init_boot.img`。工具只接受明确的输入和输出路径，拒绝覆盖输入或已有输出，不刷写、不签名：

```bash
tools/patch-init-boot.sh \
  --input /path/to/kernelsu-patched-boot-or-init_boot.img \
  --output /path/to/dsu-permissive-boot-or-init_boot.img \
  --loader out/dsuinit \
  --module out/dsu_permissive-android15-6.6.ko \
  --selinux 1 --avb 1 --verity-table-spoof 1
```

### 在 Android 上修补

[`tools/patch-init-boot-android.sh`](tools/patch-init-boot-android.sh) 只使用 `/system/bin/sh` 与 Android/toybox 常见命令，可在 `adb shell`、Termux 或 recovery shell 中运行。将输入镜像、对应 target 的 KO、loader 和修补脚本复制到设备后执行：

```sh
cd /data/local/tmp/dsu-permissive
MAGISKBOOT=/path/to/magiskboot sh ./patch-init-boot-android.sh \
  --input ./init_boot_ksu_patched.img \
  --output ./init_boot_dsu_patched.img \
  --loader ./dsuinit \
  --module ./dsu_permissive.ko \
  --selinux 1 --avb 1 --verity-table-spoof 1
```

脚本会在设备本地完成解包、条目冲突检查、SHA-256 元数据生成、重打包和再次解包校验；不会刷写分区，也不会覆盖输入或已有输出。若交互运行，未指定的 SELinux/AVB/dm-verity 表伪造参数会逐项询问；非交互运行采用默认 `1/1/0`。Android 端脚本不具备主机 LLVM 工具链，建议复制到设备前先运行 `tools/verify-artifacts.sh` 检查 loader/KO。

只变更开关而不替换 loader/KO 时：

```sh
MAGISKBOOT=/path/to/magiskboot sh ./repatch-init-boot-config-android.sh \
  --input ./init_boot_dsu_patched.img \
  --output ./init_boot_dsu_reconfigured.img \
  --selinux 0 --avb 1 --verity-table-spoof 1
```

[`tools/fetch-static-magiskboot.sh`](tools/fetch-static-magiskboot.sh) 会从官方 Magisk v30.7 APK 提取并验证 arm64 静态 magiskboot。`tools/build.sh` 将其输出到 `out/magiskboot-arm64`，可与 Android 修补脚本及其他产物分别复制到设备。

使用 `tools/build.sh --all` 时还会生成 `out/dsu-permissive-android-flasher.sh`。该单文件脚本内置全部支持的 KO，设备端根据 `uname -r` 中的 Android KMI 世代和内核分支自动选择匹配模块；单 target 构建不会生成绑定单一 KMI 的刷写脚本。

```sh
adb push out/dsu-permissive-android-flasher.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/dsu-permissive-android-flasher.sh'
```

交互终端会先询问是否直接刷入，回答 `y` 才会写入；非交互运行需显式传入 `--flash`。脚本不读取设备解锁状态，也不判断当前是否运行于 DSU。

验证镜像：

```bash
tools/verify-init-boot.sh \
  --input /path/to/dsu-permissive-boot-or-init_boot.img
```

生成逻辑还原镜像：

```bash
tools/unpatch-init-boot.sh \
  --input /path/to/dsu-permissive-boot-or-init_boot.img \
  --output /path/to/restored-boot-or-init_boot.img
```

还原会验证补丁时记录的原 init、loader 与 KO SHA-256；只要任一条目被其他工具继续修改，就会拒绝自动还原，避免破坏未知 init 链。新镜像不记录配置哈希，避免持久 metadata 枚举反推出两个开关。

## 重要限制

- 只支持表中列出的 arm64 GKI/DDK target；不支持 5.4、4.x、非 GKI 内核或 Android 11 及以下版本。
- 每个 GKI target 必须使用各自构建的 KO；即使内核主次版本相同，也不能在不同 Android KMI 世代之间复用模块。
- 自动识别 KMI 的单文件刷写脚本只在 `tools/build.sh --all` 时生成，单 target 构建不会生成绑定单一 KMI 的刷写脚本。
- 设备内核必须启用模块与 kprobe，并允许加载对应签名策略下的 KO；启用 SELinux 拦截时还要求 `CONFIG_SECURITY_SELINUX_DEVELOP`。
- AVB 拦截开启时，模块在 DSU first-stage 暂时向 PID 1 提供 `verifiedbootstate=orange`，并在 `selinux_setup` 窗口同步提供 `veritymode=disabled`。只有同时启用 `verity_table_spoof=1` 时，才将 data/hash 均命中同一已记录 `*_gsi` 的单 target first-stage `verity` table 改为 `linear`；长度不超过 backing 容量。若存在 `/metadata/gsi/dsu/avb_enforce`，三项作用均不触发表改写或 vbmeta 修改。
- 模块不会绕过 bootloader 对 `boot`、`init_boot` 或磁盘 vbmeta 的校验，也不会写入、签名或持久修改 vbmeta。顶层 vbmeta 修改只存在于 DSU first-stage PID 1 的单次读取返回缓冲区；无 footer GSI 的兼容改写只存在于该 PID 1 发出的单次 device-mapper `table_load()` 内核参数副本中。
- 若设备从 device tree、已初始化的 `ro.boot.verifiedbootstate` 或 `/proc/cmdline` 而非 `/proc/bootconfig` 取得状态，此版本不能改变该来源；KeyMint/TEE attestation 同样不受影响。
- `veritymode=disabled` 只存在于 DSU 的 `selinux_setup` PID 1 读取视图，用于跳过 vivo `vfcheck` 的 `eio` 探测；不会修改 bootloader bootconfig、磁盘分区或 second-stage 的 `ro.boot.veritymode`。
- 顶层 `HASHTREE_DISABLED` 会让本次 DSU 启动中由同一个 AVB handle 管理的 system、vendor、odm 等分区跳过 Hashtree，同时保留链式 vbmeta descriptor；正常启动仍读取磁盘原始 vbmeta。
- 开启表伪造后，对以已记录 `*_gsi` 映射为同一 data/hash 设备的单 target dm-verity v1 表，模块统一改为 `linear <same-device> 0`，并将 target 长度限制为原长度与 backing 容量的较小值；不再从 hash-tree 几何尺寸推断表是否可信。规则仅限 PID 1、DSU 已 active、first-stage、`avb_intercept=1`、`verity_table_spoof=1` 且不存在 `avb_enforce`；不会改写宿主 `system_a`、`vendor_a` 等非 GSI 映射或 `userdata_gsi`。
- 启动期 enforce fallback 只执行一次；second-stage 后模块不会阻止手动或系统主动切回 Enforcing。
- 产物检查会拒绝导入 `filp_open` / `dentry_open` / `kernel_read` / `filp_close` 文件读取链，以及设备 GKI 签名保护不允许的 `kernel_write` / `vfs_fsync` 系列符号。
- DDK 的通用 KMI 构建成功不等同于所有同版本厂商 GKI 都可运行，真机前必须核对 vermagic、符号与模块签名要求。
- 主机端 patch/verify/unpatch 工具与 Android 修补脚本均不刷写分区；自动识别 KMI 的单文件脚本仅按上述交互/`--flash` 规则执行刷写。

完整设计见 [docs/design.md](docs/design.md)，镜像布局见 [docs/image-layout.md](docs/image-layout.md)，验证说明见 [docs/testing.md](docs/testing.md)。vivo MT6991 无 footer GSI 的已验收分析见 [docs/research-vivo-dsu-avb.md](docs/research-vivo-dsu-avb.md)。
