# Hook 设计

## 目标与边界

目标是在 DSU 已经完成映射、但 SELinux enforcement 尚未由 init 最终确定的窗口内，优先复用原厂 `androidboot.selinux=permissive` 路径，并兼容以 `ALLOW_PERMISSIVE_SELINUX=0` 编译的 `user` init。模块不定位或直接写 `selinux_state`，也不 Hook `security_setenforce()` 或持续拦截 enforce 写入。

模块只支持 arm64 `android16-6.12`。Android 16 release 与当前 Android 主线中的 init 均在加载 policy 后调用 `SelinuxSetEnforcement()`，并通过 fs_mgr 读取 cmdline/bootconfig；fs_mgr 对重复 bootconfig 键采用第一项。

## 状态机

```text
WAIT_SYSTEM_INIT
  │ PID 1 第一次 exec /system/bin/init
  ▼
SELINUX_SETUP_ARMED
  │ PID 1 读取 procfs 根目录的 bootconfig
  │ DSU booted 标记存在时，仅对该 file 注入前缀
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

在整个 `selinux_setup` 窗口内处理 PID 1 的每次 bootconfig 打开，而不是假设第一次读取一定来自 `StatusFromProperty()`。这样可容纳 init 或其库在 enforcement 决策前新增其他 bootconfig 查询。作用域仍限定为 PID 1、指定阶段和单个 `/proc/bootconfig` file。

## exec 门控

`exec_gate.c` 通过 `for_each_kernel_tracepoint()` 查找 `sched_process_exec`，再用通用 tracepoint 注册接口挂载回调。回调只检查：

- `task->pid == 1`
- `bprm->filename` 精确等于 `/system/bin/init`

第一次命中对应 `selinux_setup`，第二次命中对应 `second_stage`。不读取用户态 argv，也不替换原厂 init 函数。

## bootconfig fops 代理

`bootconfig_proxy.c` 在 `vfs_read` 入口安装 kprobe。pre-handler 不执行路径查找或其他可睡眠操作，只完成：

- 状态与 PID 检查；
- `PROC_SUPER_MAGIC`、根 dentry 和 `bootconfig` 文件名检查；
- 从预分配槽位复制原 `file_operations`；
- 将当前 `struct file` 的 `f_op` 切到代理。

Android 6.12 的 `/proc/bootconfig` 由 procfs `read_iter` 路径提供，因此代理同时兼容原 fops 的 `read_iter` 和旧式 `read`，并代理 `llseek` 与 `release`。代理槽位在模块初始化时静态分配，kprobe 上下文不分配内存。

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

注入视图为：

```text
androidboot.selinux = "permissive"\n
<原始 /proc/bootconfig 内容>
```

代理把外部位置解释为“前缀长度 + 原文件位置”。读取前缀时不推进原 procfs 的位置；读取原内容前临时减去前缀长度，返回后再恢复逻辑位置。其他进程和其他文件对象始终使用原 fops。

代理 fops 的 owner 指向本模块。附加时取得模块引用，`__fput()` 在代理 `release` 返回后释放该引用，避免 file 尚未关闭时卸载模块代码。原 procfs fops 必须属于内核本体（owner 为空），否则拒绝附加。

## selinuxfs enforce 启动期 fallback

AOSP Android 16/17 的 `user` init 默认以 `ALLOW_PERMISSIVE_SELINUX=0`
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
`vfs_write`；PID 1 第二次 exec `/system/bin/init` 后注销两个
`vfs_read` kprobe，后续 `setenforce 1` 及厂商主动切回 Enforcing 均走
原厂路径。

## 为什么等价于 boot 参数路径

fs_mgr 的 `GetBootconfigFromString()` 在首次找到目标 key 后不再覆盖结果。前缀因此优先于原 bootconfig 中可能存在的 `androidboot.selinux=enforcing`。允许 permissive 的 init 随后仍执行 `security_setenforce(false)`；`user` init 则由启动期 fallback 调用同一个内核 `sel_write_enforce()` 路径。SELinux 状态页、通知和审计仍由原始实现维护。

模块不负责在 second stage 后持续拦截 enforcing，也不会锁定 permissive。开机完成后手动 `setenforce 1` 必须可以恢复 Enforcing。

## 失败策略

- KO 打开或加载失败：`dsuinit`记录错误并继续原 init 链。
- `/init.next` 执行失败：依次尝试 `/init.real` 与 `/system/bin/init`，所有失败均记录。
- tracepoint 或 kprobe 注册失败：KO 加载失败并保留明确内核日志，系统启动仍由 loader 继续。
- DSU booted 标记不存在：读取原 bootconfig，不注入。
- 原始 enforce write fop 不存在或调用失败：保留原始 enforce 读值并记录错误，系统继续以原状态启动。
- 120 秒内未完成阶段切换：注销 Hook。
