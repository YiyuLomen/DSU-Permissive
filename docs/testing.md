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
- AOSP bootconfig 首项优先契约；
- `user` / `userdebug` init 的 enforce fallback 状态矩阵；
- KO 不得导入目标设备拒绝的 `kernel_write` / `vfs_fsync` 系列符号；
- 最小 boot header v4 镜像的 patch、verify、unpatch 往返；
- KernelSU 的 `/init.real` 与 `/kernelsu.ko` 在往返后哈希不变。

完整 DDK 构建：

```bash
tools/build.sh
```

`tools/verify-artifacts.sh` 会检查 loader/KO 的 ELF 架构、类型、动态依赖、GPL modinfo 与 vermagic。

## 真机前检查

项目不自动执行以下操作。使用者应在刷写前自行确认：

1. 镜像来自当前设备与当前槽位；
2. 设备允许加载该 KO，且 vermagic/KMI/模块签名匹配；
3. 已保留可恢复的原镜像和可用的 bootloader/recovery 路径；
4. 已按设备要求完成 AVB 或启动镜像签名。

## 预期真机结果

正常系统：

```text
dsu-permissive：已进入 selinux_setup 观察窗口
dsu-permissive：Hook 已注销（...，注入 0；...，切换 0，...）
getenforce → Enforcing
```

DSU：

```text
dsu-permissive：DSU booted 标记有效，已为 PID 1 注入 permissive bootconfig
dsu-permissive：已通过 SELinux 原始 enforce 接口执行一次启动期 permissive
dsu-permissive：Hook 已注销（PID 1 已进入 second_stage，...，切换 1，错误 0）
getenforce → Permissive
```

DSU 开机完成后还必须验证代理已经退出且允许手动恢复：

```bash
adb shell su -c 'setenforce 1'
adb shell getenforce
```

结果必须为 `Enforcing`。还应验证正常系统与 DSU 各自至少冷启动一次，并确认 KernelSU 仍可用。只有主机端构建和镜像往返通过，不能代替以上真机验证。
