ENTRY(_start)
SECTIONS
{
    . = 0x40080000;
    _kernel_start = .;
    
    .text : ALIGN(4096) {
        _text_start = .;
        KEEP(*(.text.boot))
        *(.text)
        *(.text.*)
        _text_end = .;
    }
    
    .rodata : ALIGN(4096) {
        _rodata_start = .;
        *(.rodata)
        *(.rodata.*)
        _rodata_end = .;
    }
    
    .data : ALIGN(4096) {
        _data_start = .;
        *(.data)
        *(.data.*)
        _data_end = .;
    }
    
    .bss : ALIGN(4096) {
        _bss_start = .;
        *(.bss) 
        *(.bss.*) 
        . = ALIGN(16);
        _bss_end = .;
    }
    
    _kernel_end = .;
    
    .vectors : ALIGN(4096) {
        _evt_start = .;
        *(.vectors)
        *(.vectors.*) 
        _evt_end = .;
    }
    
    .stack (NOLOAD) : ALIGN(4096) {
        __stack_bottom = .;
        . += 0x10000; /* 64KB */
        stack_top = .;
    }
    _kernel_total_end = .;
}
