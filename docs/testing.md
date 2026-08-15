# 构建与验证

## 主机端检查

不需要 DDK 的检查：

```bash
tests/static-check.sh
tests/test-image-roundtrip.sh
```

DDK 产物存在时，可让往返测试直接注入真实 KO：

```bash
MODULE_UNDER_TEST=out/dsu_permissive.ko tests/test-image-roundtrip.sh
```

覆盖内容：

- AArch64 freestanding loader 构建；
- loader 无 `PT_INTERP`、无动态依赖、无未解析符号；
- AVB header `AVB0`、flags `[120,124)` 与目标字节 123 的偏移契约；
- `0x80000001 → 0x80000003`、已含 `0x02` 时幂等，以及分片读取边界；
- 非 PID 1、非 WAIT 阶段、非 DSU、非目标设备、`avb_enforce` 与错误魔数均不修改；
- “磁盘”输入字节保持不变，只修改返回缓冲区副本；
- AOSP bootconfig 首项优先契约；
- SELinux setup 只覆盖 `androidboot.selinux`，verified boot 状态保持原值，second-stage 恢复完整原始视图；
- `user` / `userdebug` init 的 enforce fallback 状态矩阵；
- KO 不得导入目标设备拒绝的 `kernel_write` / `vfs_fsync` 系列符号；
- 最小 boot header v4 镜像的 patch、verify、unpatch 往返；
- KernelSU 的 `/init.real` 与 `/kernelsu.ko` 在往返后哈希不变。

完整 DDK 构建：

```bash
tools/build.sh
```

`tools/verify-artifacts.sh` 会检查 loader/KO 的 ELF 架构、类型、动态依赖、GPL modinfo 与 vermagic。

AVB Python 测试固定的是主机端行为契约，不会执行内核中的 C 回调。实际 fops、kprobe、KMI 和用户缓冲区路径仍必须由 DDK 构建与真机日志验证。

## 真机前检查

项目不自动执行以下操作。使用者应在刷写前自行确认：

1. 镜像来自当前设备与当前槽位；
2. 设备允许加载该 KO，且 vermagic/KMI/模块签名匹配；
3. 已保留可恢复的原镜像和可用的 bootloader/recovery 路径；
4. bootloader 已报告 `verifiedbootstate=orange`，并且未创建 `/metadata/gsi/dsu/avb_enforce`；
5. 外部启动链已经允许当前 `init_boot` 启动。

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

`vfs_read` 依赖运行时 kprobe 符号解析，且厂商内核的 vermagic、BTF、符号版本与模块签名策略可能不同。即使 DDK 构建成功，也不能据此声称已完成真机兼容验证。
