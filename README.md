# DSU-Permissive

DSU-Permissive 面向 arm64 GKI，支持 `android12-5.10`、`android13-5.10`、`android13-5.15`、`android14-5.15`、`android14-6.1`、`android15-6.6` 与 `android16-6.12` 七个 DDK target。它通过 `/metadata/gsi/dsu_permissive.conf` 独立控制 SELinux 与 AVB 拦截，修改配置后只需重新启动 DSU，无需再次修补 boot/init_boot。默认两项均开启：在 PID 1 的 first-stage 确认当前系统确实是 DSU 后，只修改返回给该进程的顶层 vbmeta 读取视图，让后期 `libfs_avb` 将本次 DSU 启动识别为 `VerificationDisabled`；随后在 `selinux_setup` 阶段优先让原厂 init 读取到临时的：

```text
androidboot.selinux = "permissive"
```

对于以 `ALLOW_PERMISSIVE_SELINUX=0` 编译、会忽略该参数的 `user` init，SELinux 拦截开启时模块再通过 SELinux 自身的原始 `enforce` file operation 执行一次启动期 permissive。AVB 拦截开启时要求 bootloader 已报告 `verifiedbootstate=orange`，且 DSU 未放置 `/metadata/gsi/dsu/avb_enforce`。项目不写入或签名 vbmeta，不修改 system 或 DSU 文件，不定位或直接改写 `selinux_state`，不持续拦截 `setenforce`，也不依赖 KernelSU 源码。当前集成目标是已经由外部启动链允许启动、并由 KernelSU LKM 补丁处理过的 Android 12 `boot.img` 或 Android 13 及以上 `init_boot.img`。

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

## 统一配置

配置模板位于 [`config/dsu_permissive.conf`](config/dsu_permissive.conf)，实际生效路径固定为：

```text
/metadata/gsi/dsu_permissive.conf
```

内容为：

```text
selinux_intercept=1
avb_intercept=1
```

两个键必须各出现一次，值只能是 `0` 或 `1`：

| 配置 | `1` | `0` |
| --- | --- | --- |
| `selinux_intercept` | 允许 bootconfig 注入与 selinuxfs/enforce 启动期切换 | 不注入 bootconfig，也不执行 permissive 切换 |
| `avb_intercept` | 允许修改 first-stage vbmeta 返回视图 | 始终透传原始 vbmeta 数据 |

两项可以任意组合。由于 `dsuinit` 执行时 `/metadata` 尚未由 first-stage init 挂载，KO 会先注册短生命周期观察点；等 DSU `booted` 标记出现、代理回调即将实际修改数据时，模块才读取并缓存 metadata 配置。关闭的路径即使因早期识别而临时附加 file-operations 代理，也只调用原始操作并透传数据。配置不存在时按两项均开启处理；配置存在但读取失败、缺键、重复、含未知键或非法值时，本次启动关闭两项拦截并记录错误。配置在一次启动内只读取一次，因此修改后需重启 DSU。

Android/recovery 中可直接管理配置：

```sh
# SELinux 拦截开、AVB 拦截关
su -c 'sh /data/local/tmp/configure-metadata.sh --selinux 1 --avb 0'

# 查看当前配置；文件不存在时会显示默认 1/1
su -c 'sh /data/local/tmp/configure-metadata.sh --show'

# 安装编辑好的模板
su -c 'sh /data/local/tmp/configure-metadata.sh --install /data/local/tmp/dsu_permissive.conf'
```

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
out/dsu_permissive.conf
out/patch-init-boot-android.sh
out/configure-metadata.sh
out/magiskboot-arm64
out/dsu-permissive-android-flasher.sh
out/android16-6.12/dsu_permissive.ko
out/android16-6.12/dsu-permissive-android-flasher.sh
out/android15-6.6/dsu_permissive.ko
out/android14-6.1/dsu_permissive.ko
out/android14-5.15/dsu_permissive.ko
out/android13-5.15/dsu_permissive.ko
out/android13-5.10/dsu_permissive.ko
out/android12-5.10/dsu_permissive.ko
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
  --module out/android15-6.6/dsu_permissive.ko
```

### 在 Android 上修补

[`tools/patch-init-boot-android.sh`](tools/patch-init-boot-android.sh) 只使用 `/system/bin/sh` 与 Android/toybox 常见命令，可在 `adb shell`、Termux 或 recovery shell 中运行。将输入镜像、对应 target 的 KO、loader 和修补脚本复制到设备后执行：

```sh
cd /data/local/tmp/dsu-permissive
MAGISKBOOT=/path/to/magiskboot sh ./patch-init-boot-android.sh \
  --input ./init_boot_ksu_patched.img \
  --output ./init_boot_dsu_patched.img \
  --loader ./dsuinit \
  --module ./dsu_permissive.ko
```

脚本会在设备本地完成解包、条目冲突检查、SHA-256 元数据生成、重打包和再次解包校验；不会刷写分区，也不会覆盖输入或已有输出。SELinux/AVB 开关由独立的 `configure-metadata.sh` 管理，不固化进镜像。Android 端脚本不具备主机 LLVM 工具链，建议复制到设备前先运行 `tools/verify-artifacts.sh` 检查 loader/KO。

### 生成单文件自动刷写脚本

[`tools/fetch-static-magiskboot.sh`](tools/fetch-static-magiskboot.sh) 会从官方 Magisk v30.7 APK 提取 `lib/arm64-v8a/libmagiskboot.so`，固定校验 APK 与二进制 SHA-256，并确认它是 AArch64 `ET_EXEC`、不含 `PT_INTERP`、动态段或 `DT_NEEDED`。缓存位于 `.cache/magiskboot/v30.7/`，构建输出另存为 `out/magiskboot-arm64`。

[`tools/generate-android-flasher.sh`](tools/generate-android-flasher.sh) 会把静态 magiskboot、静态 dsuinit、KO、Android 修补脚本和 metadata 配置工具全部 Base64 封装为一个可离线复制的 Android shell 脚本。推荐使用 `auto`，把七个 target 的 KO 全部打包到同一个文件：

```bash
tools/generate-android-flasher.sh \
  --target auto \
  --module-dir out \
  --output out/dsu-permissive-android-flasher.sh
```

设备端在读取或写入分区之前调用 `uname -r`，同时匹配其中的 Android KMI 世代和内核分支：`android12 + 5.10 → android12-5.10`、`android13 + 5.10 → android13-5.10`、`android13 + 5.15 → android13-5.15`、`android14 + 5.15 → android14-5.15`、`android14 + 6.1 → android14-6.1`、`android15 + 6.6 → android15-6.6`、`android16 + 6.12 → android16-6.12`。脚本只解包并校验被选中的 KO；缺少 Android 世代标识、组合不受支持或 bundle 缺少对应 KO 时，在接触分区前直接终止。该选择不会替代内核加载阶段对符号 CRC、vermagic 与模块签名策略的最终校验。

`tools/build.sh --target ...` 仍会生成单 target 脚本；`tools/build.sh --all` 会额外生成包含全部七个 KO 的 `out/dsu-permissive-android-flasher.sh`。脚本不需要设备端另外安装 magiskboot，也不会在设备端联网；仍以 Android 自带 `/system/bin/sh` 和 toybox 基础命令作为运行环境。

复制到设备后，默认运行只自动识别当前槽位和 `init_boot/boot`、完整提取分区、保存持久备份并生成已验证的补丁镜像，不写块设备：

```sh
adb push out/dsu-permissive-android-flasher.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/dsu-permissive-android-flasher.sh'
```

确认恢复路径后，显式加入 `--flash` 才会写入。脚本会在写入后回读相同长度并比较 SHA-256：

```sh
adb shell su -c 'sh /data/local/tmp/dsu-permissive-android-flasher.sh --flash --selinux 1 --avb 1'
```

自动流程包括：

- 根据 `ro.boot.slot_suffix` / `ro.boot.slot` 选择当前槽位；
- 优先选择 `init_boot[_a|_b]`，不存在时回退到 `boot[_a|_b]`；
- 在接触分区前从完整 `uname -r` 识别 Android KMI 世代与内核分支，从七个内置 KO 中选择对应 DDK target；
- 完整备份整个目标分区并核对块设备大小；
- 使用内置静态 magiskboot 修补并重新解包校验；
- 若检测到完整旧版 DSU-Permissive 补丁，先校验旧 loader、KO 与原 init 三项哈希，再恢复原 init 链并安全替换；条目不完整或哈希不一致时拒绝继续；
- 拒绝在已知 bootloader locked 状态或 DSU 内直接刷写，除非显式覆盖；
- 写入 metadata 配置、刷入、同步并回读校验；
- 保留原始完整镜像和补丁镜像，并打印可直接使用的恢复命令。

可用 `--partition` 指定块设备、`--slot a|b|none` 覆盖自动槽位、`--backup-dir` 改变备份位置，或先执行 `--verify-bundle` 只校验内置资源。详细参数通过 `--help` 查看。

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

还原会验证补丁时记录的原 init、loader 与 KO 三个 SHA-256；只要任一条目被其他工具继续修改，就会拒绝自动还原，避免破坏未知 init 链。metadata 配置独立于 boot/init_boot 镜像，不受还原操作影响。

## 重要限制

- 只支持表中列出的 arm64 GKI/DDK target；不支持 5.4、4.x、非 GKI 内核或 Android 11 及以下版本。
- 每个 GKI target 必须使用各自构建的 KO；即使内核主次版本相同，也不能在不同 Android KMI 世代之间复用模块。
- `auto` 刷写脚本内置全部七个 KO，并按 `uname -r` 中的 Android KMI 世代与内核分支共同选择；单 target 脚本仍只接受完全对应的 target。
- 设备内核必须启用模块与 kprobe，并允许加载对应签名策略下的 KO；启用 SELinux 拦截时还要求 `CONFIG_SECURITY_SELINUX_DEVELOP`。
- AVB 拦截开启时，后期旁路只适用于 bootloader 已报告 `verifiedbootstate=orange` 的解锁设备；若存在 `/metadata/gsi/dsu/avb_enforce`，模块会拒绝修改读取视图。
- 模块不会绕过 bootloader 对 `boot`、`init_boot` 或磁盘 vbmeta 的校验，也不会写入、签名或持久修改 vbmeta。修改只存在于 DSU first-stage PID 1 的单次读取返回缓冲区中。
- 顶层 `VERIFICATION_DISABLED` 会让本次 DSU 启动中由同一个 AVB handle 管理的 system、vendor、odm 等分区跳过 Hashtree，而不只影响 DSU system；正常启动仍读取磁盘原始 vbmeta。
- 启动期 enforce fallback 只执行一次；second-stage 后模块不会阻止手动或系统主动切回 Enforcing。
- 产物检查会拒绝导入该设备 GKI 签名保护不允许的 `kernel_write` / `vfs_fsync` 系列符号。
- DDK 的通用 KMI 构建成功不等同于所有同版本厂商 GKI 都可运行，真机前必须核对 vermagic、符号与模块签名要求。
- 主机端 patch/verify/unpatch 工具不刷写分区；生成的 Android flasher 只有在显式传入 `--flash` 时才执行块设备写入。

完整设计见 [docs/design.md](docs/design.md)，镜像布局见 [docs/image-layout.md](docs/image-layout.md)，验证说明见 [docs/testing.md](docs/testing.md)。
