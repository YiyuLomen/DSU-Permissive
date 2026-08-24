// SPDX-License-Identifier: GPL-2.0-only
#include <linux/atomic.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/ioctl.h>
#include <linux/kdev_t.h>
#include <linux/kprobes.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/overflow.h>
#include <linux/sched.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/stddef.h>
#include <linux/uaccess.h>

#include <asm/ptrace.h>

#include <uapi/linux/dm-ioctl.h>

#include "dm_ioctl_proxy.h"
#include "dsu_config.h"
#include "dsu_detect.h"
#include "dsu_permissive.h"

#define DM_IOCTL_SLOT_COUNT 2
#define DSU_GSI_DEVICE_COUNT 8
#define DM_PARAMS_COPY_SIZE DM_NAME_LEN
#define DM_IOCTL_HEADER_SIZE offsetof(struct dm_ioctl, data)

struct dm_ioctl_slot {
	struct file *file;
	const struct file_operations *original_ops;
	struct file_operations proxy_ops;
	struct mutex io_lock;
	bool ops_initialized;
};

struct dsu_gsi_device {
	bool valid;
	char name[DM_NAME_LEN];
	u64 dev;
	u64 sectors;
};

static struct dm_ioctl_slot slots[DM_IOCTL_SLOT_COUNT];
static struct dsu_gsi_device gsi_devices[DSU_GSI_DEVICE_COUNT];
static DEFINE_SPINLOCK(slots_lock);
static DEFINE_SPINLOCK(gsi_devices_lock);
static atomic64_t matched_files = ATOMIC64_INIT(0);
static atomic64_t tracked_gsi_devices = ATOMIC64_INIT(0);
static atomic64_t bypassed_verity_tables = ATOMIC64_INIT(0);
static atomic64_t proxy_errors = ATOMIC64_INIT(0);
static atomic_t bypass_logged = ATOMIC_INIT(0);
static atomic_t verity_miss_logged = ATOMIC_INIT(0);
static atomic_t verity_error_logged = ATOMIC_INIT(0);
static atomic_t table_prepare_armed = ATOMIC_INIT(0);
static atomic_t table_bypass_armed = ATOMIC_INIT(0);
static bool dm_ctl_kprobe_registered;
static bool vfs_kprobe_registered;
static bool table_load_kprobe_registered;

static long proxy_ioctl(struct file *file, unsigned int command,
			unsigned long argument);
static int proxy_release(struct inode *inode, struct file *file);

static struct dm_ioctl_slot *slot_from_file(struct file *file)
{
	struct dm_ioctl_slot *slot;

	slot = container_of(file->f_op, struct dm_ioctl_slot, proxy_ops);
	if (READ_ONCE(slot->file) != file)
		return NULL;
	return slot;
}

/*
 * dentry 名称会受 /dev/mapper 链接与厂商 devtmpfs 命名影响；DM ioctl
 * magic 则是稳定 UAPI。仅对该 magic 代理 f_op，不会碰到 PID 1 的其他
 * ioctl 文件。
 */
static bool is_device_mapper_ioctl(unsigned int command)
{
	return _IOC_TYPE(command) == DM_IOCTL;
}

static bool is_dsu_image_name(const char *name)
{
	size_t length;

	if (!name)
		return false;
	length = strnlen(name, DM_NAME_LEN);
	if (length <= sizeof("_gsi") - 1 || length == DM_NAME_LEN)
		return false;
	if (strcmp(name, "userdata_gsi") == 0)
		return false;
	return !strcmp(name + length - (sizeof("_gsi") - 1), "_gsi");
}

static bool should_prepare_gsi_map(void)
{
	return current->pid == 1 &&
	       dsu_permissive_phase_get() == DSU_PHASE_WAIT_SYSTEM_INIT &&
	       dsu_config_avb_intercept() && !dsu_detect_avb_enforced();
}

static bool should_bypass_verity(void)
{
	return should_prepare_gsi_map() && dsu_detect_active();
}

static bool copy_dm_ioctl_header(void __user *argument, struct dm_ioctl *header)
{
	/* dm core itself copies only through offsetof(dm_ioctl, data). */
	memset(header, 0, sizeof(*header));
	return !copy_from_user(header, argument, DM_IOCTL_HEADER_SIZE);
}

static bool dm_ioctl_name_is_valid(const struct dm_ioctl *header)
{
	return memchr(header->name, '\0', sizeof(header->name)) != NULL;
}

static int find_gsi_device_locked(const char *name)
{
	unsigned int index;

	for (index = 0; index < ARRAY_SIZE(gsi_devices); ++index) {
		if (gsi_devices[index].valid &&
		    !strncmp(gsi_devices[index].name, name,
			     sizeof(gsi_devices[index].name)))
			return index;
	}
	return -1;
}

static int find_empty_gsi_device_locked(void)
{
	unsigned int index;

	for (index = 0; index < ARRAY_SIZE(gsi_devices); ++index) {
		if (!gsi_devices[index].valid)
			return index;
	}
	return -1;
}

static int find_gsi_device_by_encoded_dev_locked(u64 dev)
{
	unsigned int index;

	if (!dev)
		return -1;
	for (index = 0; index < ARRAY_SIZE(gsi_devices); ++index) {
		if (gsi_devices[index].valid && gsi_devices[index].dev == dev)
			return index;
	}
	return -1;
}

/* DM_TABLE_LOAD may select the map by header.dev instead of header.name. */
static int find_gsi_device_for_ioctl_locked(const struct dm_ioctl *header)
{
	int index = -1;

	if (dm_ioctl_name_is_valid(header) && is_dsu_image_name(header->name))
		index = find_gsi_device_locked(header->name);
	if (index < 0)
		index = find_gsi_device_by_encoded_dev_locked(header->dev);
	return index;
}

static void record_gsi_device(const struct dm_ioctl *header)
{
	unsigned long flags;
	dev_t decoded;
	int index;
	bool recorded = false;

	if (!header->dev || !dm_ioctl_name_is_valid(header) ||
	    !is_dsu_image_name(header->name))
		return;

	spin_lock_irqsave(&gsi_devices_lock, flags);
	index = find_gsi_device_locked(header->name);
	if (index < 0)
		index = find_empty_gsi_device_locked();
	if (index >= 0) {
		if (!gsi_devices[index].valid)
			atomic64_inc(&tracked_gsi_devices);
		memset(&gsi_devices[index], 0, sizeof(gsi_devices[index]));
		gsi_devices[index].valid = true;
		strscpy(gsi_devices[index].name, header->name,
			sizeof(gsi_devices[index].name));
		gsi_devices[index].dev = header->dev;
		recorded = true;
	}
	spin_unlock_irqrestore(&gsi_devices_lock, flags);

	if (!recorded)
		return;
	/* dm_ioctl.dev is huge_encode_dev(disk_devt()), not a native dev_t. */
	decoded = huge_decode_dev(header->dev);
	pr_info("dsu-permissive：已记录 DSU %s 的 device-mapper 设备 %u:%u（encoded 0x%llx）\n",
		header->name, MAJOR(decoded), MINOR(decoded), header->dev);
}

static bool table_bounds_valid(const struct dm_ioctl *header,
			       size_t table_size, size_t offset, size_t length)
{
	if (table_size < DM_IOCTL_HEADER_SIZE ||
	    header->data_start < DM_IOCTL_HEADER_SIZE ||
	    header->data_start > table_size)
		return false;
	return offset <= table_size && length <= table_size - offset;
}

static int gsi_table_size(const struct dm_ioctl *header, size_t table_size,
			  u64 *sectors)
{
	size_t offset;
	u64 maximum = 0;
	size_t available;
	unsigned int index;

	if (!table_bounds_valid(header, table_size, header->data_start,
				       sizeof(struct dm_target_spec)))
		return -EINVAL;
	available = table_size - header->data_start;
	if (!header->target_count ||
	    header->target_count > available / sizeof(struct dm_target_spec))
		return -EINVAL;
	offset = header->data_start;
	for (index = 0; index < header->target_count; ++index) {
		const struct dm_target_spec *target;
		u64 end;

		if (!table_bounds_valid(header, table_size, offset,
				       sizeof(*target)))
			return -EINVAL;
		target = (const struct dm_target_spec *)((const char *)header + offset);
		if (check_add_overflow(target->sector_start, target->length, &end) ||
		    !target->length)
			return -EINVAL;
		if (end > maximum)
			maximum = end;
		if (index + 1 == header->target_count)
			break;
		if (target->next < sizeof(*target) ||
		    !table_bounds_valid(header, table_size, offset, target->next))
			return -EINVAL;
		offset += target->next;
	}
	*sectors = maximum;
	return 0;
}

static void record_gsi_table_size(const struct dm_ioctl *header,
				  size_t table_size)
{
	unsigned long flags;
	u64 sectors;
	int index;
	int error;
	bool updated = false;

	spin_lock_irqsave(&gsi_devices_lock, flags);
	index = find_gsi_device_for_ioctl_locked(header);
	spin_unlock_irqrestore(&gsi_devices_lock, flags);
	if (index < 0)
		return;

	error = gsi_table_size(header, table_size, &sectors);
	if (error) {
		atomic64_inc(&proxy_errors);
		pr_warn("dsu-permissive：读取 DSU table 容量失败：%d（name=%.127s，dev=0x%llx，data=%u/%zu，targets=%u）\n",
			error, header->name, header->dev, header->data_start,
			table_size, header->target_count);
		return;
	}

	spin_lock_irqsave(&gsi_devices_lock, flags);
	/* The slot may only be removed at module teardown, but resolve again. */
	index = find_gsi_device_for_ioctl_locked(header);
	if (index >= 0 && gsi_devices[index].sectors != sectors) {
		gsi_devices[index].sectors = sectors;
		updated = true;
	}
	spin_unlock_irqrestore(&gsi_devices_lock, flags);

	if (updated)
		pr_info("dsu-permissive：已记录 DSU table 的实际容量 %llu sectors（name=%.127s，dev=0x%llx，targets=%u）\n",
			sectors, header->name, header->dev, header->target_count);
}

static int first_parameter_token(const char *parameters, size_t available,
				 char *token, size_t token_size,
				 const char **after)
{
	size_t length = 0;

	while (available && (*parameters == ' ' || *parameters == '\t')) {
		++parameters;
		--available;
	}
	while (available && *parameters != ' ' && *parameters != '\t' &&
	       *parameters != '\0') {
		if (length + 1 >= token_size)
			return -ENAMETOOLONG;
		token[length++] = *parameters++;
		--available;
	}
	if (!length)
		return -EINVAL;
	token[length] = '\0';
	if (after)
		*after = parameters;
	return 0;
}

static int parse_verity_data_device(const char *parameters, size_t available,
				    char *device, size_t device_size)
{
	char version[16];
	const char *after;
	int error;

	error = first_parameter_token(parameters, available, version,
				      sizeof(version), &after);
	if (error)
		return error;
	return first_parameter_token(after, available - (after - parameters),
				     device, device_size, NULL);
}

static bool device_token_matches(const char *token,
				 const struct dsu_gsi_device *device)
{
	char expected[DM_NAME_LEN];
	dev_t decoded = huge_decode_dev(device->dev);
	unsigned int major = MAJOR(decoded);
	unsigned int minor = MINOR(decoded);

	if (scnprintf(expected, sizeof(expected), "/dev/block/dm-%u", minor) > 0 &&
	    !strcmp(token, expected))
		return true;
	if (scnprintf(expected, sizeof(expected), "/dev/mapper/%s", device->name) > 0 &&
	    !strcmp(token, expected))
		return true;
	if (scnprintf(expected, sizeof(expected), "/dev/block/mapper/%s",
		      device->name) > 0 && !strcmp(token, expected))
		return true;
	if (scnprintf(expected, sizeof(expected), "%u:%u", major, minor) > 0 &&
	    !strcmp(token, expected))
		return true;
	return false;
}

static bool find_gsi_device_for_token(const char *token,
				      struct dsu_gsi_device *result)
{
	unsigned long flags;
	unsigned int index;
	bool found = false;

	spin_lock_irqsave(&gsi_devices_lock, flags);
	for (index = 0; index < ARRAY_SIZE(gsi_devices); ++index) {
		if (!gsi_devices[index].valid || !gsi_devices[index].sectors ||
		    !device_token_matches(token, &gsi_devices[index]))
			continue;
		*result = gsi_devices[index];
		found = true;
		break;
	}
	spin_unlock_irqrestore(&gsi_devices_lock, flags);
	return found;
}

static int rewrite_verity_table(struct dm_ioctl *header, size_t table_size)
{
	struct dm_target_spec *target;
	struct dsu_gsi_device device;
	char parameters[DM_PARAMS_COPY_SIZE];
	char data_device[DM_NAME_LEN];
	char linear_parameters[DM_NAME_LEN + 3];
	char linear_type[DM_MAX_TYPE_NAME] = "linear";
	size_t target_offset;
	size_t parameter_offset;
	size_t parameter_capacity;
	size_t parameter_length;
	int error;

	if (header->target_count != 1)
		return 0;
	target_offset = header->data_start;
	if (!table_bounds_valid(header, table_size, target_offset, sizeof(*target)))
		return -EINVAL;
	target = (struct dm_target_spec *)((char *)header + target_offset);
	if (strncmp(target->target_type, "verity", sizeof(target->target_type)) ||
	    target->sector_start != 0)
		return 0;

	parameter_offset = target_offset + sizeof(*target);
	if (!table_bounds_valid(header, table_size, parameter_offset, 1))
		return -EINVAL;
	/* The final target's next field is not needed to parse this table. */
	parameter_capacity = table_size - parameter_offset;
	parameter_length = min(parameter_capacity, sizeof(parameters));
	memcpy(parameters, (char *)header + parameter_offset, parameter_length);
	parameters[sizeof(parameters) - 1] = '\0';
	error = parse_verity_data_device(parameters, parameter_length, data_device,
					 sizeof(data_device));
	if (error)
		return error == -EINVAL ? 0 : error;
	if (!find_gsi_device_for_token(data_device, &device)) {
		if (atomic_cmpxchg(&verity_miss_logged, 0, 1) == 0)
			pr_warn("dsu-permissive：检测到 first-stage verity 表，但 data device %s 未匹配已记录的 DSU GSI 映射（GSI %lld）\n",
				data_device, atomic64_read(&tracked_gsi_devices));
		return 0;
	}
	if (scnprintf(linear_parameters, sizeof(linear_parameters), "%s 0",
		      data_device) + 1 > parameter_capacity)
		return -ENOSPC;

	memcpy((char *)header + parameter_offset, linear_parameters,
	       strlen(linear_parameters) + 1);
	target->length = device.sectors;
	memcpy(target->target_type, linear_type, sizeof(linear_type));

	atomic64_inc(&bypassed_verity_tables);
	if (atomic_cmpxchg(&bypass_logged, 0, 1) == 0)
		pr_info("dsu-permissive：已将 DSU %s 的 first-stage verity 表替换为 linear（%s，%llu sectors）\n",
			device.name, data_device, device.sectors);
	return 1;
}

static long proxy_ioctl(struct file *file, unsigned int command,
			unsigned long argument)
{
	struct dm_ioctl_slot *slot = slot_from_file(file);
	long (*original_ioctl)(struct file *file, unsigned int command,
				unsigned long argument);
	struct dm_ioctl header;
	long result;

	if (!slot)
		return -EIO;

	mutex_lock(&slot->io_lock);
	if (slot->file != file || !slot->original_ops ||
	    !slot->original_ops->unlocked_ioctl) {
		result = -EIO;
		goto out;
	}
	original_ioctl = slot->original_ops->unlocked_ioctl;

	/*
	 * dm_ctl_ioctl() copies the complete request into a kernel buffer before
	 * it calls table_load().  Some vivo first-stage requests reject even a
	 * header-sized second copy_from_user() here, although dm core can process
	 * the original request.  Latch the policy in this process context and let
	 * the table_load kprobe consume its already-copied kernel parameters.
	 */
	if (command == DM_TABLE_LOAD && should_prepare_gsi_map())
		atomic_set(&table_prepare_armed, 1);
	if (command == DM_TABLE_LOAD && should_bypass_verity())
		atomic_set(&table_bypass_armed, 1);

	result = original_ioctl(file, command, argument);
	if (result == 0 && command == DM_DEV_CREATE &&
	    should_prepare_gsi_map() &&
	    copy_dm_ioctl_header((void __user *)argument, &header))
		record_gsi_device(&header);
out:
	mutex_unlock(&slot->io_lock);
	return result;
}

static int proxy_release(struct inode *inode, struct file *file)
{
	struct dm_ioctl_slot *slot = slot_from_file(file);
	int (*original_release)(struct inode *inode, struct file *released_file);
	unsigned long flags;
	int result = 0;

	if (!slot)
		return 0;

	mutex_lock(&slot->io_lock);
	original_release = slot->original_ops ? slot->original_ops->release : NULL;
	if (original_release)
		result = original_release(inode, file);

	spin_lock_irqsave(&slots_lock, flags);
	WRITE_ONCE(slot->file, NULL);
	spin_unlock_irqrestore(&slots_lock, flags);
	mutex_unlock(&slot->io_lock);
	return result;
}

static void attach_proxy(struct file *file)
{
	const struct file_operations *original_ops;
	struct dm_ioctl_slot *slot = NULL;
	unsigned long flags;
	unsigned int index;
	bool release_module = false;
	bool attached = false;

	/* on_vfs_ioctl() has already filtered the request by DM_IOCTL magic. */
	if (!file)
		return;

	spin_lock_irqsave(&slots_lock, flags);
	for (index = 0; index < ARRAY_SIZE(slots); ++index) {
		if (READ_ONCE(slots[index].file) == file)
			goto out;
		if (!slot && !READ_ONCE(slots[index].file))
			slot = &slots[index];
	}
	if (!slot)
		goto out;

	original_ops = READ_ONCE(file->f_op);
	if (!original_ops || !original_ops->unlocked_ioctl ||
	    !try_module_get(THIS_MODULE))
		goto out;
	if (!slot->ops_initialized) {
		slot->original_ops = original_ops;
		memcpy(&slot->proxy_ops, original_ops, sizeof(slot->proxy_ops));
		slot->proxy_ops.owner = THIS_MODULE;
		slot->proxy_ops.unlocked_ioctl = proxy_ioctl;
		slot->proxy_ops.release = proxy_release;
		slot->ops_initialized = true;
	}
	WRITE_ONCE(slot->file, file);
	/* f_op 发布前保证 proxy 回调能读取完整 slot 状态。 */
	smp_wmb();
	if (cmpxchg(&file->f_op, original_ops, &slot->proxy_ops) != original_ops) {
		WRITE_ONCE(slot->file, NULL);
		release_module = true;
		goto out;
	}
	atomic64_inc(&matched_files);
	attached = true;
out:
	spin_unlock_irqrestore(&slots_lock, flags);
	if (release_module)
		module_put(THIS_MODULE);
	if (attached)
		pr_info("dsu-permissive：已代理 PID 1 的 device-mapper ioctl\n");
}

static int on_vfs_ioctl(struct kprobe *probe, struct pt_regs *registers)
{
	struct file *file;
	unsigned int command;

	(void)probe;
	if (current->pid != 1 ||
	    dsu_permissive_phase_get() != DSU_PHASE_WAIT_SYSTEM_INIT)
		return 0;

	file = (struct file *)registers->regs[0];
	command = (unsigned int)registers->regs[1];
	if (is_device_mapper_ioctl(command))
		attach_proxy(file);
	return 0;
}

NOKPROBE_SYMBOL(on_vfs_ioctl);

static struct kprobe vfs_ioctl_probe = {
	.symbol_name = "vfs_ioctl",
	.pre_handler = on_vfs_ioctl,
};

/*
 * 在 Android 6.6 上，dm_ctl_ioctl 是 device-mapper control fops 的实际
 * unlocked_ioctl 入口。这里只替换 file->f_op；DM_DEV_CREATE 的用户态
 * 返回头处理和 table-load 策略 latch 均留在 proxy_ioctl() 的正常进程
 * 上下文，完整 table payload 只在 table_load() 的内核缓冲区中处理。
 */
static int on_dm_ctl_ioctl(struct kprobe *probe, struct pt_regs *registers)
{
	struct file *file;

	(void)probe;
	if (current->pid != 1 ||
	    dsu_permissive_phase_get() != DSU_PHASE_WAIT_SYSTEM_INIT)
		return 0;

	file = (struct file *)registers->regs[0];
	attach_proxy(file);
	return 0;
}

NOKPROBE_SYMBOL(on_dm_ctl_ioctl);

static struct kprobe dm_ctl_ioctl_probe = {
	.symbol_name = "dm_ctl_ioctl",
	.pre_handler = on_dm_ctl_ioctl,
};

/*
 * Android 6.6 dm_ctl_ioctl() calls table_load(file, param, param_size)
 * after copy_params() has copied the complete ioctl payload.  param_size is
 * the original payload length; param->data_size has already been reset to
 * offsetof(struct dm_ioctl, data), so never use it for table bounds here.
 */
static int on_table_load(struct kprobe *probe, struct pt_regs *registers)
{
	struct dm_ioctl *header;
	size_t table_size;
	int rewrite_result;

	(void)probe;
	if (current->pid != 1 ||
	    dsu_permissive_phase_get() != DSU_PHASE_WAIT_SYSTEM_INIT)
		return 0;

	header = (struct dm_ioctl *)registers->regs[1];
	table_size = (size_t)registers->regs[2];
	if (!header || table_size < DM_IOCTL_HEADER_SIZE)
		return 0;

	if (atomic_read(&table_prepare_armed))
		record_gsi_table_size(header, table_size);
	if (!atomic_read(&table_bypass_armed))
		return 0;

	rewrite_result = rewrite_verity_table(header, table_size);
	if (rewrite_result < 0) {
		atomic64_inc(&proxy_errors);
		if (atomic_cmpxchg(&verity_error_logged, 0, 1) == 0)
			pr_warn("dsu-permissive：跳过 first-stage verity 改写：%d（name=%.127s，dev=0x%llx，data=%u/%zu，targets=%u）\n",
				rewrite_result, header->name, header->dev,
				header->data_start, table_size, header->target_count);
	}
	return 0;
}

NOKPROBE_SYMBOL(on_table_load);

static struct kprobe table_load_probe = {
	.symbol_name = "table_load",
	.pre_handler = on_table_load,
};

int dm_ioctl_proxy_register(void)
{
	unsigned long flags;
	unsigned int index;
	int error;

	if (dm_ctl_kprobe_registered || vfs_kprobe_registered ||
	    table_load_kprobe_registered)
		return 0;

	for (index = 0; index < ARRAY_SIZE(slots); ++index)
		mutex_init(&slots[index].io_lock);
	spin_lock_irqsave(&gsi_devices_lock, flags);
	memset(gsi_devices, 0, sizeof(gsi_devices));
	spin_unlock_irqrestore(&gsi_devices_lock, flags);
	atomic64_set(&matched_files, 0);
	atomic64_set(&tracked_gsi_devices, 0);
	atomic64_set(&bypassed_verity_tables, 0);
	atomic64_set(&proxy_errors, 0);
	atomic_set(&bypass_logged, 0);
	atomic_set(&verity_miss_logged, 0);
	atomic_set(&verity_error_logged, 0);
	atomic_set(&table_prepare_armed, 0);
	atomic_set(&table_bypass_armed, 0);

	error = register_kprobe(&dm_ctl_ioctl_probe);
	if (!error) {
		dm_ctl_kprobe_registered = true;
		pr_info("dsu-permissive：已注册 first-stage device-mapper dm_ctl_ioctl kprobe\n");
	} else {
		/* 部分内核不导出静态 dm_ctl_ioctl 符号时保留 VFS 入口兜底。 */
		pr_warn("dsu-permissive：dm_ctl_ioctl kprobe 不可用：%d，回退到 vfs_ioctl\n",
			error);
		error = register_kprobe(&vfs_ioctl_probe);
		if (error)
			return error;

		vfs_kprobe_registered = true;
		pr_info("dsu-permissive：已注册 first-stage device-mapper vfs_ioctl fallback kprobe\n");
	}

	error = register_kprobe(&table_load_probe);
	if (error) {
		/* AVB/SELinux hooks remain useful; leave the no-footer fallback fail-open. */
		pr_warn("dsu-permissive：table_load kprobe 不可用：%d；无 footer GSI 的 verity fallback 将原样透传\n",
			error);
		return 0;
	}
	table_load_kprobe_registered = true;
	pr_info("dsu-permissive：已注册 first-stage device-mapper table_load kprobe\n");
	return 0;
}

void dm_ioctl_proxy_unregister(void)
{
	if (table_load_kprobe_registered) {
		unregister_kprobe(&table_load_probe);
		table_load_kprobe_registered = false;
	}
	if (dm_ctl_kprobe_registered) {
		unregister_kprobe(&dm_ctl_ioctl_probe);
		dm_ctl_kprobe_registered = false;
	}
	if (vfs_kprobe_registered) {
		unregister_kprobe(&vfs_ioctl_probe);
		vfs_kprobe_registered = false;
	}
}

u64 dm_ioctl_proxy_match_count(void)
{
	return atomic64_read(&matched_files);
}

u64 dm_ioctl_proxy_gsi_count(void)
{
	return atomic64_read(&tracked_gsi_devices);
}

u64 dm_ioctl_proxy_bypass_count(void)
{
	return atomic64_read(&bypassed_verity_tables);
}

u64 dm_ioctl_proxy_error_count(void)
{
	return atomic64_read(&proxy_errors);
}
