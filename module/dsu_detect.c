// SPDX-License-Identifier: GPL-2.0-only
#include <linux/namei.h>
#include <linux/path.h>

#include "dsu_detect.h"

#define DSU_BOOTED_MARKER "/metadata/gsi/dsu/booted"
#define DSU_AVB_ENFORCE_MARKER "/metadata/gsi/dsu/avb_enforce"

static bool path_exists(const char *name)
{
	struct path path;

	if (kern_path(name, LOOKUP_FOLLOW, &path))
		return false;

	path_put(&path);
	return true;
}

bool dsu_detect_active(void)
{
	/*
	 * dash fork：本构建面向常规启动的第三方 ROM，而非 DSU 场景。
	 * AOSP first-stage init 只在 DSU 映射成功后才创建 booted 标记，
	 * 常规启动永远不存在该标记，因此这里无条件视为激活。
	 * avb_enforce 检查保持不变，强制验证模式下仍会拒绝修改视图。
	 */
	return true;
}

bool dsu_detect_avb_enforced(void)
{
	return path_exists(DSU_AVB_ENFORCE_MARKER);
}
