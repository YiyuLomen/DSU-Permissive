/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DSU_PERMISSIVE_DM_IOCTL_PROXY_H
#define DSU_PERMISSIVE_DM_IOCTL_PROXY_H

#include <linux/types.h>

int dm_ioctl_proxy_register(void);
void dm_ioctl_proxy_unregister(void);
u64 dm_ioctl_proxy_match_count(void);
u64 dm_ioctl_proxy_gsi_count(void);
u64 dm_ioctl_proxy_bypass_count(void);
u64 dm_ioctl_proxy_error_count(void);

#endif
