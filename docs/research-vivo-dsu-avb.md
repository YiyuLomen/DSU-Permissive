# vivo MT6991：无 AVB footer DSU GSI 启动研究报告

**结论：已验收。** 2026-08-24，用户已在 vivo MT6991 真机确认：带有效官方 AVB 信息的镜像与不含 AVB footer/metadata 的目标 GSI 均可完成 DSU 启动。本文记录已验证的故障链、修复边界和复现条件；它不构成对其他厂商 init、内核或 bootloader 的泛化保证。

## 研究范围

目标是让通过 DSU 映射的 GSI 映像分区能够经过 Android first-stage，而不是绕过 bootloader、TEE 或磁盘 vbmeta 的验证。改动范围限定为：

- first-stage PID 1 面向 DSU 的瞬时读取/DM table 视图；
- 仅 `*_gsi` 映射，且排除 `userdata_gsi`；
- 仅 DSU active、`avb_intercept=1`、不存在 `/metadata/gsi/dsu/avb_enforce`、`WAIT_SYSTEM_INIT` 阶段的请求。

项目不会修改 `boot`、`init_boot`、磁盘 vbmeta、system 映像或 bootloader 状态；也不宣称影响 KeyMint/TEE attestation。

## 设备与样本

| 项目 | 观测值 |
| --- | --- |
| 设备平台 | vivo MT6991（PD2415_A_15.0.33.7.W10） |
| 原厂 first-stage init 对应内核 | 6.6.57-android15-8 |
| 验证时 KernelSU 内核 | 6.6.127-4k-g46a034eca005-dirty |
| `system_gsi` 的映射 | `/dev/block/dm-16`，设备号 `254:16` |
| `dm_ioctl.dev` 原始值 | `0xfe10`，按 `huge_decode_dev()` 解码为 `254:16` |
| 初始 `system_gsi` table | 129 个 target，容量 3,632,608 sectors |

用于静态研究的原厂 init 与 ramoops 仅在调试阶段使用，最终工作树不保留设备镜像或日志副本。

## 根因

对原厂 init 的静态分析没有发现“AVB disabled 一律拒绝启动”的单一硬编码分支。`veritymode=eio` 的 vivo `vfcheck`/survival 路径发生在更晚的 `selinux_setup`；它不能解释 first-stage `/system` 挂载前的 panic。

不含 footer 的 GSI 失败链已由 ramoops 证实：

1. `userdata_gsi` 与 `system_gsi` 已成功创建。
2. 顶层 vbmeta 的临时 `HASHTREE_DISABLED` 视图已经生效；摘要失配在 orange 状态下是预期中间结果。
3. `libfs_avb` 无法从 `system_gsi` 读取 offline vbmeta/footer，转而执行 `Fallback to built-in hashtree for /system`。
4. 原厂 init 构建了 hash/FEC 布局假定不成立的 `verity` table；dm core 返回 `verity: Hash device is too small (-E2BIG)`。
5. `/system` 因而无法挂载，PID 1 退出并触发 kernel panic。

因此，扩大 system 映像或虚构 footer/hash/FEC 数据不是可靠修复。

## 最终实现

### AVB 与 vivo 后续检查

[`vbmeta_proxy.c`](../module/vbmeta_proxy.c) 仅向 first-stage PID 1 返回的顶层 vbmeta header 打开 bit 0：

```text
AVB_VBMETA_IMAGE_FLAGS_HASHTREE_DISABLED
offset 123: flags |= 0x01
```

这保留链式 vbmeta descriptor，同时使该 `AvbHandle` 跳过 hashtree。bootconfig 代理在相同窗口给 PID 1 呈现 `verifiedbootstate=orange`，使摘要失配能够进入这个允许路径；在 `selinux_setup` 再短暂呈现 `veritymode=disabled`，避免 vivo 走 `eio` 的 `vfcheck`/boot-survival 检查。上述内容均是返回视图，不会写入原始分区或持久 bootconfig。

### 无 footer 的 dm-verity fallback

[`dm_ioctl_proxy.c`](../module/dm_ioctl_proxy.c) 在 `DM_DEV_CREATE` 成功后记录符合条件的 `*_gsi` 映射及其编码设备号。初始 GSI table 的真实容量在 dm core 的 `table_load(file, param, param_size)` 中计算。

早期实现从 fops proxy 对同一用户缓冲区再次 `copy_from_user()`；vivo fallback 请求在这里返回 header read failure，虽然 dm core 可以正常处理原请求。最终实现改在 `table_load()` 的内核 `param` 副本中读写：

- `proxy_ioctl()` 仅在可睡眠的正常 ioctl 上下文中计算 DSU/AVB 条件并设置 latch；
- `table_load` kprobe 使用 arm64 第 2、3 个参数取得 `param` 与原始 `param_size`；
- 使用 `param_size` 作为完整 target payload 边界。Android 15 / Linux 6.6 在调用 `table_load()` 前已将 `param->data_size` 复位为固定的 305（`offsetof(struct dm_ioctl, data)`），不可拿它解析 payload；
- 仅将 data-device 指向已记录 GSI 的单 target、sector 0 `verity` 表改为 `linear <same-device> 0`，并把 length 设为记录的真实 sector 数；
- 不匹配、多个 target、非零 start、非 PID 1、非 first-stage、非 DSU 或 `avb_enforce` 路径全部 fail-open 原样透传。

匹配 data-device 时支持 `/dev/block/dm-N`、`/dev/mapper/<name>`、`/dev/block/mapper/<name>` 与 `major:minor`。

## 验收结果

真机最终启动已经通过，故障特征 `Hash device is too small (-E2BIG)` 不再阻断 `/system` 挂载。验收同时确认修复针对的是 vivo first-stage 的内置 verity fallback，而不是关闭外部启动链验证。

建议以后针对新机型保留以下最小验证证据：

1. `dm_ctl_ioctl` 与 `table_load` kprobe 均已注册；
2. 记录到目标 `*_gsi` 设备号和真实 sectors；
3. 出现“first-stage verity 表替换为 linear”日志；
4. 系统进入 `/system/bin/init` second stage，且没有 `Hash device is too small`、`boot-survival` 或 PID 1 panic；
5. 正常非 DSU 启动和 `avb_enforce` 启动均保持原始 table。

## 回归与清理

本次收尾移除了 dsuinit 中临时 fork 的 `/dev/kmsg` 采集器，因此运行时不会再创建或写入 `/metadata/gsi/dmesg.log`。保留原有向 `/dev/kmsg` 写入简短启动诊断的行为。

回归覆盖由 [`tests/static-check.sh`](../tests/static-check.sh) 执行，包括 loader 的 AArch64 freestanding 构建、AVB header 契约、bootconfig 状态矩阵、DM table 契约与脚本检查；另已完成隔离 host Kbuild 的 C 接口检查。真机通过是最终兼容性证据，host 检查不替代真机验收。

清理后的 `out/dsuinit` 与自动刷写 bundle 均不含 metadata 日志采集器。
