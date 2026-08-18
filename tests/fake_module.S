/* 仅用于主机端镜像工具测试，不是可加载模块。 */
#ifndef TEST_VERMAGIC
#define TEST_VERMAGIC "vermagic=6.12.0-android16-test SMP preempt mod_unload aarch64"
#endif
#ifndef TEST_DDK_TARGET
#define TEST_DDK_TARGET "android16-6.12"
#endif
	.section .modinfo, "a", %progbits
	.asciz "license=GPL"
	.asciz TEST_VERMAGIC
	.asciz "dsu_config_path=/dsu_permissive.conf"
	.asciz "parm=selinux_intercept:bool"
	.asciz "parm=avb_intercept:bool"
	.ascii "dsu_ddk_target="
	.asciz TEST_DDK_TARGET
	.asciz "import_ns=ANDROID_GKI_VFS_EXPORT_ONLY"
#ifdef TEST_UNDEFINED_SYMBOL
	.section .text, "ax", %progbits
	.global test_undefined_symbol
test_undefined_symbol:
	b TEST_UNDEFINED_SYMBOL
#endif
	.section .note.GNU-stack, "", %progbits
