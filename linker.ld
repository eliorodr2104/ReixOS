ENTRY(_start)
SECTIONS
{
    . = 0x40080000;
    _kernel_start = .;
    
    .text : ALIGN(4096) {
        _text_start = .;
        *(.text.boot)
        
        . = ALIGN(2048);
        _evt_start = .;
        *(.vectors)
        _evt_end = .;
        
        *(.text*)
        _text_end = .;
    }
    
    .rodata : ALIGN(4096) {
        _rodata_start = .;
        *(.rodata)
        *(.rodata.*)
        *(.swift_modhash)
        _rodata_end = .;
    }
    
    .data : ALIGN(4096) {
        _data_start = .;
        *(.data)
        *(.data.*)
        _data_end = .;
    }
    
    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.bss) 
        *(.bss.*) 
        . = ALIGN(16);
        __bss_end = .;
    }
    
    _kernel_end = .;

    /* Guard page for the kernel stack, which grows down from stack_top toward
       __stack_bottom. It sits below __stack_bottom so the first access past the
       end of the stack lands in it. VirtualMemoryManager starts its linear map
       at __stack_guard_top and therefore never maps this page, in either root:
       reserving the address alone would not fault, the hole in the page tables
       is what does. Without it an overflow walks straight into .bss. */
    .stack_guard (NOLOAD) : ALIGN(4096) {
        __stack_guard_bottom = .;
        . += 0x1000; /* 4KB, deliberately left unmapped */
        __stack_guard_top = .;
    }

    .stack (NOLOAD) : ALIGN(4096) {
        __stack_bottom = .;
        . += 0x10000; /* 64KB */
        stack_top = .;
    }

    /* Where an exception taken at EL1 builds its trap frame when SP has left
       the kernel stack. The guard page above turns a stack overflow into an
       abort, but the vector prologue's own store is then the next access into
       the guard, so without a second stack the report cannot be written and the
       kernel loops in the vector instead. check_kernel_stack in ContextSaving.S
       re-anchors SP here.

       Deliberately placed ABOVE .stack: the check tests SP against
       __stack_bottom, so an abort taken while already on this stack fails the
       test, nests one frame deeper here rather than re-entering the switch, and
       ends in the panic formatter's own depth guard.

       It carries the panic report only, which is a straight-line path, so 16KB
       is roughly four times the deepest stack a panic has been observed to use.
       It has no guard page of its own: that would need a second hole in
       VirtualMemoryManager's linear map, and an abort taken here is the end of
       the line anyway. */
    .exception_stack (NOLOAD) : ALIGN(4096) {
        __exception_stack_bottom = .;
        . += 0x4000; /* 16KB */
        __exception_stack_top = .;
    }
    _kernel_total_end = .;
}
