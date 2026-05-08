ENTRY(_start)

KERNEL_PHYS_BASE   = 0x40080000;
KERNEL_VIRT_OFFSET = 0xFFFF800000000000;
KERNEL_VIRT_BASE   = KERNEL_PHYS_BASE + KERNEL_VIRT_OFFSET;

SECTIONS
{
    /* Higher-half kernel: VMA = PHYS + KERNEL_VIRT_OFFSET, LMA stays physical. */
    . = KERNEL_VIRT_BASE;
    _kernel_start = .;
    
    .text : ALIGN(4096) AT(ADDR(.text) - KERNEL_VIRT_OFFSET) {
        _text_start = .;
        *(.text.boot)
        
        *(.text*)
        
        . = ALIGN(2048);
        _evt_start = .;
        *(.vectors)
        _evt_end = .;
        
        _text_end = .;
    }
    
    .rodata : ALIGN(4096) AT(ADDR(.rodata) - KERNEL_VIRT_OFFSET) {
        _rodata_start = .;
        *(.rodata)
        *(.rodata.*)
        _rodata_end = .;
    }
    
    .data : ALIGN(4096) AT(ADDR(.data) - KERNEL_VIRT_OFFSET) {
        _data_start = .;
        *(.data)
        *(.data.*)
        _data_end = .;
    }
    
    .bss (NOLOAD) : ALIGN(4096) AT(ADDR(.bss) - KERNEL_VIRT_OFFSET) {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        . = ALIGN(16);
        __bss_end = .;
    }
    
    _kernel_end = .;
    
    .stack (NOLOAD) : ALIGN(4096) AT(ADDR(.stack) - KERNEL_VIRT_OFFSET) {
        __stack_bottom = .;
        . += 0x10000; /* 64KB */
        stack_top = .;
    }
    
    _kernel_total_end = .;
}
