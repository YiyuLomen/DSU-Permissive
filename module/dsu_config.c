// SPDX-License-Identifier: GPL-2.0-only
#include <linux/moduleparam.h>
#include <linux/types.h>

#include "dsu_config.h"

static bool selinux_intercept = true;
static bool avb_intercept = true;

/* 参数仅在 finit_module() 时使用；不创建可被后续程序读取的 sysfs 节点。 */
module_param(selinux_intercept, bool, 0000);
MODULE_PARM_DESC(selinux_intercept,
		 "是否启用 DSU 启动期 SELinux 拦截");
module_param(avb_intercept, bool, 0000);
MODULE_PARM_DESC(avb_intercept, "是否启用 DSU first-stage AVB 拦截");

bool dsu_config_selinux_intercept(void)
{
	return selinux_intercept;
}

bool dsu_config_avb_intercept(void)
{
	return avb_intercept;
}
