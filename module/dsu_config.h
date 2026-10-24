/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef DSU_PERMISSIVE_CONFIG_H
#define DSU_PERMISSIVE_CONFIG_H

#include <linux/types.h>

#define DSU_CONFIG_PATH "/dsu_permissive.conf"

bool dsu_config_selinux_intercept(void);
bool dsu_config_avb_intercept(void);
bool dsu_config_verity_table_spoof(void);

#endif
