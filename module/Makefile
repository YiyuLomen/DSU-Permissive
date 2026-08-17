obj-m += dsu_permissive.o
dsu_permissive-y := dsu_permissive_main.o exec_gate.o bootconfig_proxy.o \
	dsu_config.o dsu_detect.o selinux_enforce_proxy.o vbmeta_proxy.o

ifndef DSU_DDK_TARGET
DSU_DDK_TARGET := unknown
endif
ccflags-y += -DDSU_DDK_TARGET=\"$(DSU_DDK_TARGET)\"
