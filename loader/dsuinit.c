// SPDX-License-Identifier: GPL-2.0-only
typedef unsigned long size_t;

#define AT_FDCWD (-100L)
#define O_RDONLY 0L
#define O_WRONLY 1L
#define O_CLOEXEC 02000000L
#define O_NOFOLLOW 0400000L

#define SYS_OPENAT 56L
#define SYS_CLOSE 57L
#define SYS_UNLINKAT 35L
#define SYS_READ 63L
#define SYS_WRITE 64L
#define SYS_EXECVE 221L
#define SYS_FINIT_MODULE 273L

#define ERR_EEXIST (-17L)
#define ERR_ENOENT (-2L)

#define MODULE_CONFIG_CAPACITY 64U
#define MODULE_PARAMS_CAPACITY 64U

static int log_fd = 2;

static long raw_syscall1(long number, long argument0)
{
	register long x0 __asm__("x0") = argument0;
	register long x8 __asm__("x8") = number;

	__asm__ volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory", "cc");
	return x0;
}

static long raw_syscall3(long number, long argument0, long argument1,
			 long argument2)
{
	register long x0 __asm__("x0") = argument0;
	register long x1 __asm__("x1") = argument1;
	register long x2 __asm__("x2") = argument2;
	register long x8 __asm__("x8") = number;

	__asm__ volatile("svc #0" : "+r"(x0)
			 : "r"(x1), "r"(x2), "r"(x8) : "memory", "cc");
	return x0;
}

static long raw_syscall4(long number, long argument0, long argument1,
			 long argument2, long argument3)
{
	register long x0 __asm__("x0") = argument0;
	register long x1 __asm__("x1") = argument1;
	register long x2 __asm__("x2") = argument2;
	register long x3 __asm__("x3") = argument3;
	register long x8 __asm__("x8") = number;

	__asm__ volatile("svc #0" : "+r"(x0)
			 : "r"(x1), "r"(x2), "r"(x3), "r"(x8)
			 : "memory", "cc");
	return x0;
}

static size_t string_length(const char *text)
{
	size_t length = 0;

	while (text[length])
		++length;
	return length;
}

static void write_log(const char *text)
{
	raw_syscall3(SYS_WRITE, log_fd, (long)text, string_length(text));
}

static size_t append_text(char *buffer, size_t capacity, size_t cursor,
			  const char *text)
{
	while (*text && cursor < capacity)
		buffer[cursor++] = *text++;
	return cursor;
}

static size_t append_number(char *buffer, size_t capacity, size_t cursor,
			    long value)
{
	char digits[32];
	unsigned long magnitude;
	size_t digit_cursor = sizeof(digits);

	magnitude = value < 0 ? (unsigned long)(-(value + 1)) + 1 :
			       (unsigned long)value;
	do {
		digits[--digit_cursor] = '0' + magnitude % 10;
		magnitude /= 10;
	} while (magnitude);
	if (value < 0)
		digits[--digit_cursor] = '-';

	while (digit_cursor < sizeof(digits) && cursor < capacity)
		buffer[cursor++] = digits[digit_cursor++];
	return cursor;
}

static int consume_text(const char *buffer, size_t length, size_t *cursor,
			const char *expected)
{
	while (*expected) {
		if (*cursor == length || buffer[*cursor] != *expected)
			return 0;
		++*cursor;
		++expected;
	}
	return 1;
}

static int parse_module_config(const char *buffer, size_t length,
			       char *parameters, size_t capacity)
{
	size_t cursor = 0;
	size_t output = 0;
	char selinux_value;
	char avb_value;

	if (!consume_text(buffer, length, &cursor, "selinux_intercept=") ||
	    cursor == length)
		return 0;
	selinux_value = buffer[cursor++];
	if ((selinux_value != '0' && selinux_value != '1') ||
	    !consume_text(buffer, length, &cursor, "\navb_intercept=") ||
	    cursor == length)
		return 0;
	avb_value = buffer[cursor++];
	if ((avb_value != '0' && avb_value != '1') ||
	    (cursor != length &&
	     (cursor + 1 != length || buffer[cursor] != '\n')))
		return 0;

	output = append_text(parameters, capacity - 1, output,
			     "selinux_intercept=");
	if (output == capacity - 1)
		return 0;
	parameters[output++] = selinux_value;
	output = append_text(parameters, capacity - 1, output, " avb_intercept=");
	if (output == capacity - 1)
		return 0;
	parameters[output++] = avb_value;
	parameters[output] = '\0';
	return 1;
}

static void write_error(const char *operation, long error)
{
	char buffer[256];
	size_t cursor = 0;

	cursor = append_text(buffer, sizeof(buffer), cursor, "<3>dsuinit：");
	cursor = append_text(buffer, sizeof(buffer), cursor, operation);
	cursor = append_text(buffer, sizeof(buffer), cursor, "失败，错误码 ");
	cursor = append_number(buffer, sizeof(buffer), cursor, error);
	cursor = append_text(buffer, sizeof(buffer), cursor, "\n");
	raw_syscall3(SYS_WRITE, log_fd, (long)buffer, cursor);
}

static void setup_log(void)
{
	long result;

	result = raw_syscall4(SYS_OPENAT, AT_FDCWD, (long)"/dev/kmsg",
			      O_WRONLY | O_CLOEXEC, 0);
	if (result >= 0)
		log_fd = (int)result;
}

static void load_module_parameters(char *parameters, size_t capacity)
{
	char config[MODULE_CONFIG_CAPACITY];
	long file;
	long result;

	parameters[0] = '\0';
	file = raw_syscall4(SYS_OPENAT, AT_FDCWD,
			    (long)"/dsu_permissive.conf",
			    O_RDONLY | O_CLOEXEC | O_NOFOLLOW, 0);
	if (file == ERR_ENOENT) {
		write_log("<4>dsuinit：未找到内嵌配置，使用模块默认开关\n");
		return;
	}
	if (file < 0) {
		write_error("打开 /dsu_permissive.conf ", file);
		return;
	}
	result = raw_syscall3(SYS_UNLINKAT, AT_FDCWD,
			      (long)"/dsu_permissive.conf", 0);
	if (result < 0) {
		write_error("移除 /dsu_permissive.conf ", result);
		write_log("<3>dsuinit：配置仍有路径，拒绝读取并使用模块默认开关\n");
		raw_syscall1(SYS_CLOSE, file);
		return;
	}

	result = raw_syscall3(SYS_READ, file, (long)config,
			      MODULE_CONFIG_CAPACITY);
	raw_syscall1(SYS_CLOSE, file);
	if (result < 0) {
		write_error("读取 /dsu_permissive.conf ", result);
		return;
	}
	if ((size_t)result == MODULE_CONFIG_CAPACITY ||
	    !parse_module_config(config, (size_t)result, parameters, capacity)) {
		write_log("<3>dsuinit：内嵌配置无效，使用模块默认开关\n");
		parameters[0] = '\0';
		return;
	}
	write_log("<6>dsuinit：已加载并移除 init_boot 内嵌开关\n");
}

static void load_module(void)
{
	long file;
	long result;
	char parameters[MODULE_PARAMS_CAPACITY];

	file = raw_syscall4(SYS_OPENAT, AT_FDCWD,
			    (long)"/dsu_permissive.ko",
			    O_RDONLY | O_CLOEXEC, 0);
	if (file < 0) {
		write_error("打开 /dsu_permissive.ko ", file);
		return;
	}

	load_module_parameters(parameters, sizeof(parameters));
	result = raw_syscall3(SYS_FINIT_MODULE, file, (long)parameters, 0);
	raw_syscall1(SYS_CLOSE, file);
	if (result == 0) {
		write_log("<6>dsuinit：dsu_permissive.ko 已加载\n");
	} else if (result == ERR_EEXIST) {
		write_log("<4>dsuinit：模块已存在，继续执行原 init 链\n");
	} else {
		write_error("加载 dsu_permissive.ko ", result);
	}
}

static long execute(const char *path, char **arguments, char **environment)
{
	long result = raw_syscall3(SYS_EXECVE, (long)path, (long)arguments,
				   (long)environment);

	write_error(path, result);
	return result;
}

int dsuinit_main(long argument_count, char **arguments, char **environment)
{
	(void)argument_count;
	setup_log();
	write_log("<6>dsuinit：开始加载 DSU-Permissive\n");
	load_module();

	execute("/init.next", arguments, environment);
	execute("/init.real", arguments, environment);
	execute("/system/bin/init", arguments, environment);
	write_log("<0>dsuinit：所有 init 执行路径均失败，停止启动\n");
	return 127;
}
