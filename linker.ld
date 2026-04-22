ENTRY(_start)
SECTIONS
{
    . = 0x40080000;
    _kernel_start = .;
    
    .text : ALIGN(16) {
        KEEP(*(.text.boot))
        *(.text)
        *(.text.*)
    }
    
    .rodata : ALIGN(16) {
        *(.rodata)
        *(.rodata.*)
    }
    
    .data : ALIGN(16) {
        *(.data) 
        *(.data.*) 
    }
    
    .bss : ALIGN(16) {
        __bss_start = .;
        *(.bss) 
        *(.bss.*) 
        . = ALIGN(16);
        __bss_end = .;
    }
    
    _kernel_end = .;
    
    .vectors : ALIGN(2048) {
        _evt_start = .;
        *(.vectors)
        *(.vectors.*) 
        _evt_end = .;
    }
}
