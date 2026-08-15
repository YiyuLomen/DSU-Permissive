SECTIONS {
	__patchable_function_entries : { *(__patchable_function_entries) }
	.text : {
		init_module.cfi_jt = . + 0x3710;
		delayed_work_timer_fn.cfi_jt = . + 0x3718;
		cleanup_module.cfi_jt = . + 0x3720;
		find_sched_exec_tracepoint.cfi_jt = . + 0x3728;
		on_sched_process_exec.cfi_jt = . + 0x3730;
		proxy_read_iter.cfi_jt = . + 0x3738;
		proxy_llseek.cfi_jt = . + 0x3740;
		on_vfs_read.cfi_jt = . + 0x3748;
		on_vfs_read.32.cfi_jt = . + 0x3750;
		on_vfs_read.59.cfi_jt = . + 0x3758;
		proxy_read.cfi_jt = . + 0x3760;
		proxy_read.37.cfi_jt = . + 0x3768;
		proxy_read.63.cfi_jt = . + 0x3770;
		proxy_release.cfi_jt = . + 0x3778;
		proxy_release.38.cfi_jt = . + 0x3780;
		proxy_release.64.cfi_jt = . + 0x3788;
		stop_hooks.cfi_jt = . + 0x3790;
		on_timeout.cfi_jt = . + 0x3798;
		resolve_vbmeta_devices.cfi_jt = . + 0x37a0;
	}
}
