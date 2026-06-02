ENTRY(_start)
/* User image base = 512 GiB + 4 MiB (L0 entry 1). L0[0] (< 512 GiB) is
 * reserved for the kernel mapping shared by every address space, so user
 * code must live at or above 512 GiB. Keep in sync with
 * UserSpaceLayout.userMin / elfBaseTypical. */
SECTIONS {
    . = 0x8000400000;
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    .bss : { *(.bss*) }
}
