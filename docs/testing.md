# 构建与验证

## 主机端检查

不需要 DDK 的检查：

```bash
tests/static-check.sh
tests/test-image-roundtrip.sh
```

DDK 产物存在时，可让往返测试直接注入真实 KO：

```bash
MODULE_UNDER_TEST=out/android15-6.6/dsu_permissive.ko \
  tests/test-image-roundtrip.sh
```

覆盖内容：

- AArch64 freestanding loader 构建；
- loader 无 `PT_INTERP`、无动态依赖、无未解析符号；
- metadata 统一配置两个键的四种组合、非法配置安全关闭，以及 Android 配置工具的写入/查看/删除；
- AVB header `AVB0`、flags `[120,124)` 与目标字节 123 的偏移契约；
- `0x80000001 → 0x80000003`、已含 `0x02` 时幂等，以及分片读取边界；
- 非 PID 1、非 WAIT 阶段、非 DSU、非目标设备、`avb_enforce` 与错误魔数均不修改；
- “磁盘”输入字节保持不变，只修改返回缓冲区副本；
- AOSP bootconfig 首项优先契约；
- SELinux setup 只覆盖 `androidboot.selinux`，verified boot 状态保持原值，second-stage 恢复完整原始视图；
- `user` / `userdebug` init 的 enforce fallback 状态矩阵；
- KO 不得导入部分厂商 GKI 未导出的 `filp_open`，也不得导入目标设备拒绝的 `kernel_write` / `vfs_fsync` 系列符号；
- 主机 Bash 与 Android `/system/bin/sh` 两套脚本生成相同 `format=1` 镜像元数据布局，Android 脚本还覆盖旧补丁哈希校验、逻辑还原和 loader/KO 替换往返；
- 可代表 Android 12 `boot.img` 或 Android 13 及以上 `init_boot.img` 的最小 boot header v4 镜像往返；
- KernelSU 的 `/init.real` 与 `/kernelsu.ko` 在往返后哈希不变。

默认回归构建 `android16-6.12`：

```bash
tools/build.sh
```

构建指定 target 或完整支持矩阵：

```bash
tools/build.sh --target android15-6.6
tools/build.sh --all
```

完整矩阵包括：

| DDK target | Android KMI 世代 |
| --- | --- |
| `android16-6.12` | Android 16 |
| `android15-6.6` | Android 15 |
| `android14-6.1` | Android 14 |
| `android14-5.15` | Android 14 |
| `android13-5.15` | Android 13 |
| `android13-5.10` | Android 13 |
| `android12-5.10` | Android 12 |

KO 输出到 `out/<DDK target>/dsu_permissive.ko`。`tools/verify-artifacts.sh` 会检查 loader/KO 的 ELF 架构、类型、动态依赖、GPL modinfo、metadata 配置路径、内嵌 DDK target、Android GKI VFS 命名空间声明、vermagic、产物是否与指定 target 一致，并拒绝导入 `filp_open` 等不允许符号的 KO。

AVB Python 测试固定的是主机端行为契约，不会执行内核中的 C 回调。实际 fops、kprobe、KMI 和用户缓冲区路径仍必须由 DDK 构建与真机日志验证。

静态 magiskboot 拉取验证：

```bash
tools/fetch-static-magiskboot.sh --force
```

该命令需要网络，会校验固定的官方 Magisk v30.7 APK SHA-256、内部 arm64 magiskboot SHA-256、ELF 架构以及不存在动态解释器/动态依赖，因此不放入默认离线回归。

## 真机前检查

项目不自动执行以下操作。使用者应在刷写前自行确认：

1. 镜像来自当前设备与当前槽位；
2. 设备允许加载该 KO，且 vermagic/KMI/模块签名匹配；
3. 已保留可恢复的原镜像和可用的 bootloader/recovery 路径；
4. 若启用 AVB 拦截，bootloader 已报告 `verifiedbootstate=orange`，并且未创建 `/metadata/gsi/dsu/avb_enforce`；
5. 外部启动链已经允许当前 `boot` 或 `init_boot` 镜像启动。

还应在启动前运行 `tools/configure-metadata.sh --show`，确认 `/metadata/gsi/dsu_permissive.conf` 与预期一致。若只测试其中一条路径，应分别使用 `selinux_intercept=0` 或 `avb_intercept=0`，重启 DSU 后确认被关闭路径的注入/修改计数始终为 0。

## 预期真机结果

正常系统：

```text
dsu-permissive：已进入 selinux_setup 观察窗口
dsu-permissive：Hook 已注销（...，vbmeta ...，修改 0，...；bootconfig ...，注入 0；...，切换 0，...）
getenforce → Enforcing
```

正常系统即使读取同一个宿主 vbmeta，修改计数也必须为 0。

DSU：

```text
dsu-permissive：已定位 first-stage vbmeta 块设备
dsu-permissive：metadata 统一配置已加载，SELinux 拦截=开启，AVB 拦截=开启
dsu-permissive：已为 PID 1 临时呈现 verification-disabled vbmeta
init: [libfs_avb] Failed to verify vbmeta digest
init: [libfs_avb] Returning avb_handle with status: VerificationDisabled
init: Top-level vbmeta is disabled, skip Hashtree setup for /system
dsu-permissive：DSU booted 标记有效，已为 PID 1 注入 permissive bootconfig
dsu-permissive：已通过 SELinux 原始 enforce 接口执行一次启动期 permissive
dsu-permissive：Hook 已注销（PID 1 已进入 second_stage，vbmeta ...，修改至少 1，错误 0；...，切换 1，错误 0）
getenforce → Permissive
```

修改 flags 会破坏签名或摘要，因此出现对应验证错误是预期中间状态；最终必须继续到 `VerificationDisabled`，不能停在 `AvbHandle::Open()` 失败。模块不改 verified boot bootconfig，second-stage 的 `ro.boot.verifiedbootstate` 应保持 bootloader 提供的真实 `orange`。

还应在启动前后比较 vbmeta 分区原始 header 或完整哈希，确认磁盘 flags 没有变化。DSU 中由同一顶层 AVB handle 管理的 system、vendor、odm 等条目可能都出现 `Top-level vbmeta is disabled`，这是该方案的预期作用范围。

DSU 开机完成后还必须验证代理已经退出且允许手动恢复：

```bash
adb shell su -c 'setenforce 1'
adb shell getenforce
```

结果必须为 `Enforcing`。还应验证正常系统与 DSU 各自至少冷启动一次，并确认 KernelSU 仍可用。只有主机端构建和镜像往返通过，不能代替以上真机验证。

`vfs_read` 依赖运行时 kprobe 符号解析，且同版本厂商 GKI 的 vermagic、BTF、符号版本与模块签名策略仍可能不同。即使七个 DDK target 全部构建成功，也不能据此声称已完成真机兼容验证。非 GKI 内核不在验证或支持范围内。
