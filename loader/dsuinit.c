// SPDX-License-Identifier: GPL-2.0-only
typedef unsigned long size_t;

#define AT_FDCWD (-100L)
#define O_RDONLY 0L
#define O_WRONLY 1L
#define O_CLOEXEC 02000000L

#define SYS_OPENAT 56L
#define SYS_CLOSE 57L
#define SYS_WRITE 64L
#define SYS_EXECVE 221L
#define SYS_FINIT_MODULE 273L

#define ERR_EEXIST (-17L)

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

static void load_module(void)
{
	long file;
	long result;

	file = raw_syscall4(SYS_OPENAT, AT_FDCWD,
			    (long)"/dsu_permissive.ko",
			    O_RDONLY | O_CLOEXEC, 0);
	if (file < 0) {
		write_error("打开 /dsu_permissive.ko ", file);
		return;
	}

	result = raw_syscall3(SYS_FINIT_MODULE, file, (long)"", 0);
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
