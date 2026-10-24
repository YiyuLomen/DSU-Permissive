ENTRY(_start)

PHDRS
{
	text PT_LOAD FLAGS(5);
	data PT_LOAD FLAGS(6);
	stack PT_GNU_STACK FLAGS(6);
}

SECTIONS
{
	. = 0x00400000;
	.text : ALIGN(16)
	{
		KEEP(*(.text.start))
		*(.text .text.*)
	} :text

	.rodata : ALIGN(16)
	{
		*(.rodata .rodata.*)
	} :text

	. = ALIGN(0x1000);
	.data : ALIGN(16)
	{
		*(.data .data.*)
	} :data

	.bss (NOLOAD) : ALIGN(16)
	{
		*(.bss .bss.* COMMON)
	} :data

	/DISCARD/ :
	{
		*(.comment)
		*(.eh_frame .eh_frame_hdr)
		*(.note .note.*)
	}
}

