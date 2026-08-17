// SPDX-License-Identifier: GPL-2.0-only
#include <linux/err.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/mutex.h>
#include <linux/printk.h>
#include <linux/types.h>

#include "dsu_config.h"

#define CONFIG_CAPACITY 256U

static DEFINE_MUTEX(config_lock);
static bool config_loaded;
static bool selinux_intercept = true;
static bool avb_intercept = true;

static bool is_space(char character)
{
	return character == ' ' || character == '\t' || character == '\n' ||
	       character == '\r';
}

static bool token_equals(const char *token, size_t length,
			 const char *expected)
{
	size_t cursor = 0;

	while (cursor < length && expected[cursor] &&
	       token[cursor] == expected[cursor])
		++cursor;
	return cursor == length && !expected[cursor];
}

static int parse_config(const char *buffer, size_t length,
			bool *selinux_enabled, bool *avb_enabled)
{
	size_t cursor = 0;
	bool selinux_seen = false;
	bool avb_seen = false;

	while (cursor < length) {
		size_t start;
		size_t token_length;

		while (cursor < length && is_space(buffer[cursor]))
			++cursor;
		if (cursor == length)
			break;

		start = cursor;
		while (cursor < length && !is_space(buffer[cursor]))
			++cursor;
		token_length = cursor - start;

		if (token_equals(buffer + start, token_length,
				 "selinux_intercept=0")) {
			if (selinux_seen)
				return -EINVAL;
			*selinux_enabled = false;
			selinux_seen = true;
		} else if (token_equals(buffer + start, token_length,
					"selinux_intercept=1")) {
			if (selinux_seen)
				return -EINVAL;
			*selinux_enabled = true;
			selinux_seen = true;
		} else if (token_equals(buffer + start, token_length,
					"avb_intercept=0")) {
			if (avb_seen)
				return -EINVAL;
			*avb_enabled = false;
			avb_seen = true;
		} else if (token_equals(buffer + start, token_length,
					"avb_intercept=1")) {
			if (avb_seen)
				return -EINVAL;
			*avb_enabled = true;
			avb_seen = true;
		} else {
			return -EINVAL;
		}
	}

	return selinux_seen && avb_seen ? 0 : -EINVAL;
}

static int read_config(char *buffer, size_t *length)
{
	struct file *file;
	loff_t position = 0;
	size_t used = 0;
	ssize_t result;
	int error = 0;

	file = filp_open(DSU_CONFIG_PATH, O_RDONLY, 0);
	if (IS_ERR(file))
		return PTR_ERR(file);

	while (used < CONFIG_CAPACITY) {
		result = kernel_read(file, buffer + used, CONFIG_CAPACITY - used,
				     &position);
		if (result < 0) {
			error = (int)result;
			goto out;
		}
		if (!result)
			break;
		used += (size_t)result;
	}

	if (used == CONFIG_CAPACITY) {
		char extra;

		result = kernel_read(file, &extra, 1, &position);
		if (result < 0)
			error = (int)result;
		else if (result > 0)
			error = -E2BIG;
	}
out:
	filp_close(file, NULL);
	if (error)
		return error;
	*length = used;
	return 0;
}

static void load_config_locked(void)
{
	char buffer[CONFIG_CAPACITY];
	size_t length = 0;
	bool configured_selinux = true;
	bool configured_avb = true;
	int error;

	if (config_loaded)
		return;

	error = read_config(buffer, &length);
	if (error == -ENOENT) {
		selinux_intercept = true;
		avb_intercept = true;
		pr_info("dsu-permissive：metadata 统一配置不存在，SELinux/AVB 拦截按默认开启\n");
	} else if (error) {
		selinux_intercept = false;
		avb_intercept = false;
		pr_err("dsu-permissive：读取 metadata 统一配置失败：%d，本次启动关闭全部拦截\n",
		       error);
	} else if (parse_config(buffer, length, &configured_selinux,
				&configured_avb)) {
		selinux_intercept = false;
		avb_intercept = false;
		pr_err("dsu-permissive：metadata 统一配置无效，本次启动关闭全部拦截\n");
	} else {
		selinux_intercept = configured_selinux;
		avb_intercept = configured_avb;
		pr_info("dsu-permissive：metadata 统一配置已加载，SELinux 拦截=%s，AVB 拦截=%s\n",
			selinux_intercept ? "开启" : "关闭",
			avb_intercept ? "开启" : "关闭");
	}

	config_loaded = true;
}

bool dsu_config_selinux_intercept(void)
{
	bool enabled;

	mutex_lock(&config_lock);
	load_config_locked();
	enabled = selinux_intercept;
	mutex_unlock(&config_lock);
	return enabled;
}

bool dsu_config_avb_intercept(void)
{
	bool enabled;

	mutex_lock(&config_lock);
	load_config_locked();
	enabled = avb_intercept;
	mutex_unlock(&config_lock);
	return enabled;
}
