// SPDX-License-Identifier: GPL-2.0-only
#include <linux/atomic.h>
#include <linux/dcache.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/kprobes.h>
#include <linux/magic.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/overflow.h>
#include <linux/sched.h>
#include <linux/spinlock.h>
#include <linux/string.h>
#include <linux/uaccess.h>
#include <linux/uio.h>

#include <asm/ptrace.h>

#include "bootconfig_proxy.h"
#include "dsu_detect.h"
#include "dsu_permissive.h"

#define BOOTCONFIG_NAME "bootconfig"
#define BOOTCONFIG_SLOT_COUNT 2

static const char permissive_prefix[] =
	"androidboot.selinux = \"permissive\"\n";

enum injection_decision {
	INJECTION_UNCHECKED = 0,
	INJECTION_DISABLED,
	INJECTION_ENABLED,
};

struct bootconfig_slot {
	struct file *file;
	const struct file_operations *original_ops;
	/* 每个 file 需要保留原操作集，所以代理 fops 不能声明为 const。 */
	struct file_operations proxy_ops;
	/* 序列化同一 file 的位置转换、DSU 判断和 release。 */
	struct mutex io_lock;
	bool ops_initialized;
	enum injection_decision decision;
};

static struct bootconfig_slot slots[BOOTCONFIG_SLOT_COUNT];
static DEFINE_SPINLOCK(slots_lock);
static atomic64_t matched_files = ATOMIC64_INIT(0);
static atomic64_t injected_files = ATOMIC64_INIT(0);
static atomic_t injection_logged = ATOMIC_INIT(0);
static bool kprobe_registered;

static ssize_t proxy_read(struct file *file, char __user *buffer,
			  size_t count, loff_t *position);
static ssize_t proxy_read_iter(struct kiocb *iocb, struct iov_iter *to);
static loff_t proxy_llseek(struct file *file, loff_t offset, int whence);
static int proxy_release(struct inode *inode, struct file *file);

static struct bootconfig_slot *slot_from_file(struct file *file)
{
	struct bootconfig_slot *slot;

	slot = container_of(file->f_op, struct bootconfig_slot, proxy_ops);
	if (READ_ONCE(slot->file) != file)
		return NULL;
	return slot;
}

static bool is_proc_bootconfig(struct file *file)
{
	struct dentry *dentry;
	struct super_block *super;

	if (!file)
		return false;

	dentry = file->f_path.dentry;
	super = file_inode(file)->i_sb;
	if (!dentry || !super || super->s_magic != PROC_SUPER_MAGIC)
		return false;
	if (dentry->d_parent != super->s_root)
		return false;
	if (dentry->d_name.len != sizeof(BOOTCONFIG_NAME) - 1)
		return false;

	return !memcmp(dentry->d_name.name, BOOTCONFIG_NAME,
		       sizeof(BOOTCONFIG_NAME) - 1);
}

static bool decide_injection(struct bootconfig_slot *slot)
{
	if (slot->decision == INJECTION_UNCHECKED) {
		if (dsu_detect_active()) {
			slot->decision = INJECTION_ENABLED;
			atomic64_inc(&injected_files);
			if (atomic_cmpxchg(&injection_logged, 0, 1) == 0)
				pr_info("dsu-permissive：DSU booted 标记有效，已为 PID 1 注入 permissive bootconfig\n");
		} else {
			slot->decision = INJECTION_DISABLED;
		}
	}

	return slot->decision == INJECTION_ENABLED;
}

static ssize_t emit_prefix_to_user(char __user *buffer, size_t count,
				   loff_t *position)
{
	size_t available;
	size_t copied;
	size_t not_copied;

	if (!position || *position < 0)
		return -EINVAL;
	if (*position >= sizeof(permissive_prefix) - 1)
		return 0;

	available = sizeof(permissive_prefix) - 1 - (size_t)*position;
	copied = min(count, available);
	not_copied = copy_to_user(buffer, permissive_prefix + *position, copied);
	copied -= not_copied;
	if (!copied)
		return -EFAULT;

	*position += copied;
	return copied;
}

static ssize_t proxy_read(struct file *file, char __user *buffer,
			  size_t count, loff_t *position)
{
	struct bootconfig_slot *slot = slot_from_file(file);
	loff_t original_position;
	ssize_t result;

	if (!slot)
		return -EIO;

	mutex_lock(&slot->io_lock);
	if (slot->file != file || !slot->original_ops ||
	    !slot->original_ops->read) {
		result = -EIO;
		goto out;
	}
	if (!count) {
		result = 0;
		goto out;
	}

	if (!decide_injection(slot)) {
		result = slot->original_ops->read(file, buffer, count, position);
		goto out;
	}

	result = emit_prefix_to_user(buffer, count, position);
	if (result)
		goto out;

	original_position = *position - (sizeof(permissive_prefix) - 1);
	result = slot->original_ops->read(file, buffer, count,
					  &original_position);
	if (original_position >= 0)
		*position = original_position + sizeof(permissive_prefix) - 1;
out:
	mutex_unlock(&slot->io_lock);
	return result;
}

static ssize_t emit_prefix_to_iter(struct kiocb *iocb, struct iov_iter *to)
{
	size_t available;
	size_t copied;
	size_t requested;

	if (iocb->ki_pos < 0)
		return -EINVAL;
	if (iocb->ki_pos >= sizeof(permissive_prefix) - 1)
		return 0;

	available = sizeof(permissive_prefix) - 1 - (size_t)iocb->ki_pos;
	requested = min(iov_iter_count(to), available);
	copied = copy_to_iter(permissive_prefix + iocb->ki_pos, requested, to);
	if (!copied)
		return -EFAULT;

	iocb->ki_pos += copied;
	return copied;
}

static ssize_t proxy_read_iter(struct kiocb *iocb, struct iov_iter *to)
{
	struct file *file = iocb->ki_filp;
	struct bootconfig_slot *slot = slot_from_file(file);
	ssize_t result;

	if (!slot)
		return -EIO;

	mutex_lock(&slot->io_lock);
	if (slot->file != file || !slot->original_ops ||
	    !slot->original_ops->read_iter) {
		result = -EIO;
		goto out;
	}
	if (!iov_iter_count(to)) {
		result = 0;
		goto out;
	}

	if (!decide_injection(slot)) {
		result = slot->original_ops->read_iter(iocb, to);
		goto out;
	}

	result = emit_prefix_to_iter(iocb, to);
	if (result)
		goto out;

	iocb->ki_pos -= sizeof(permissive_prefix) - 1;
	result = slot->original_ops->read_iter(iocb, to);
	if (iocb->ki_pos >= 0)
		iocb->ki_pos += sizeof(permissive_prefix) - 1;
out:
	mutex_unlock(&slot->io_lock);
	return result;
}

static loff_t proxy_llseek(struct file *file, loff_t offset, int whence)
{
	struct bootconfig_slot *slot = slot_from_file(file);
	loff_t logical_position;
	loff_t original_result;
	loff_t result;

	if (!slot)
		return -EIO;

	mutex_lock(&slot->io_lock);
	if (slot->file != file || !slot->original_ops ||
	    !slot->original_ops->llseek) {
		result = -EIO;
		goto out;
	}

	if (!decide_injection(slot)) {
		result = slot->original_ops->llseek(file, offset, whence);
		goto out;
	}

	if (whence == SEEK_END) {
		original_result = slot->original_ops->llseek(file, offset,
							    SEEK_END);
		if (original_result < 0) {
			result = original_result;
			goto out;
		}
		if (check_add_overflow(original_result,
				       (loff_t)(sizeof(permissive_prefix) - 1),
				       &logical_position)) {
			result = -EOVERFLOW;
			goto out;
		}
		file->f_pos = logical_position;
		result = logical_position;
		goto out;
	}

	if (whence == SEEK_SET) {
		logical_position = offset;
	} else if (whence == SEEK_CUR) {
		if (check_add_overflow(file->f_pos, offset, &logical_position)) {
			result = -EOVERFLOW;
			goto out;
		}
	} else {
		result = -EINVAL;
		goto out;
	}

	if (logical_position < 0) {
		result = -EINVAL;
		goto out;
	}

	if (logical_position <= sizeof(permissive_prefix) - 1) {
		original_result = slot->original_ops->llseek(file, 0, SEEK_SET);
		if (original_result < 0) {
			result = original_result;
			goto out;
		}
		file->f_pos = logical_position;
		result = logical_position;
		goto out;
	}

	original_result = slot->original_ops->llseek(file,
		logical_position - (sizeof(permissive_prefix) - 1), SEEK_SET);
	if (original_result < 0) {
		result = original_result;
		goto out;
	}
	result = original_result + sizeof(permissive_prefix) - 1;
	file->f_pos = result;
out:
	mutex_unlock(&slot->io_lock);
	return result;
}

static int proxy_release(struct inode *inode, struct file *file)
{
	struct bootconfig_slot *slot = slot_from_file(file);
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
	slot->decision = INJECTION_UNCHECKED;
	spin_unlock_irqrestore(&slots_lock, flags);
	mutex_unlock(&slot->io_lock);

	/* __fput() 随后通过 proxy_ops.owner 释放附加时取得的模块引用。 */
	return result;
}

static void attach_proxy(struct file *file)
{
	const struct file_operations *original_ops;
	struct bootconfig_slot *slot = NULL;
	unsigned long flags;
	bool release_module = false;
	int index;

	original_ops = READ_ONCE(file->f_op);
	if (!original_ops || original_ops->owner ||
	    (!original_ops->read && !original_ops->read_iter))
		return;

	spin_lock_irqsave(&slots_lock, flags);
	for (index = 0; index < BOOTCONFIG_SLOT_COUNT; ++index) {
		if (slots[index].file == file)
			goto out;
		if (!slot && !slots[index].file &&
		    (!slots[index].ops_initialized ||
		     slots[index].original_ops == original_ops))
			slot = &slots[index];
	}

	if (!slot || !try_module_get(THIS_MODULE))
		goto out;

	if (!slot->ops_initialized) {
		slot->original_ops = original_ops;
		memcpy(&slot->proxy_ops, original_ops,
		       sizeof(slot->proxy_ops));
		slot->proxy_ops.owner = THIS_MODULE;
		if (original_ops->read)
			slot->proxy_ops.read = proxy_read;
		if (original_ops->read_iter)
			slot->proxy_ops.read_iter = proxy_read_iter;
		if (original_ops->llseek)
			slot->proxy_ops.llseek = proxy_llseek;
		slot->proxy_ops.release = proxy_release;
		slot->ops_initialized = true;
	}
	slot->decision = INJECTION_UNCHECKED;
	WRITE_ONCE(slot->file, file);
	/* f_op 发布后，代理回调必须能看到上面的完整槽位状态。 */
	smp_wmb();
	if (cmpxchg(&file->f_op, original_ops, &slot->proxy_ops) !=
	    original_ops) {
		WRITE_ONCE(slot->file, NULL);
		slot->decision = INJECTION_UNCHECKED;
		release_module = true;
		goto out;
	}
	atomic64_inc(&matched_files);
out:
	spin_unlock_irqrestore(&slots_lock, flags);
	if (release_module)
		module_put(THIS_MODULE);
}

static int on_vfs_read(struct kprobe *probe, struct pt_regs *registers)
{
	struct file *file;

	(void)probe;

	if (dsu_permissive_phase_get() != DSU_PHASE_SELINUX_SETUP_ARMED ||
	    current->pid != 1)
		return 0;

	file = (struct file *)registers->regs[0];
	if (is_proc_bootconfig(file))
		attach_proxy(file);

	return 0;
}

NOKPROBE_SYMBOL(on_vfs_read);

static struct kprobe vfs_read_probe = {
	.symbol_name = "vfs_read",
	.pre_handler = on_vfs_read,
};

int bootconfig_proxy_register(void)
{
	int index;
	int error;

	if (kprobe_registered)
		return 0;

	for (index = 0; index < BOOTCONFIG_SLOT_COUNT; ++index)
		mutex_init(&slots[index].io_lock);

	error = register_kprobe(&vfs_read_probe);
	if (error)
		return error;

	kprobe_registered = true;
	return 0;
}

void bootconfig_proxy_unregister(void)
{
	if (!kprobe_registered)
		return;

	unregister_kprobe(&vfs_read_probe);
	kprobe_registered = false;
}

u64 bootconfig_proxy_match_count(void)
{
	return atomic64_read(&matched_files);
}

u64 bootconfig_proxy_injection_count(void)
{
	return atomic64_read(&injected_files);
}
