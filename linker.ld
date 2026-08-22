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
    
    /* The initrd, carried inside the kernel image instead of being handed to
       QEMU with -initrd. QEMU drops an -initrd halfway up RAM and then
       2 MiB-aligns the generated DTB after it, which on a 4 MiB machine lands
       past the top of RAM and kills the boot before the kernel starts; linked
       here it is contiguous with the kernel and nothing has to be placed.

       Between .rodata and .data so no kernel mapping covers it: the VMM maps
       .rodata, then .data.._kernel_end, then the initrd read-only on its own.
       Empty when the plugin links no .initrd input, and the two symbols then
       coincide and DeviceTreeBridge keeps what the device tree reported. */
    .initrd : ALIGN(4096) {
        _initrd_start = .;
        KEEP(*(.initrd))
        _initrd_end = .;
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

    /* Sized on measurement, not on a guess: boot.S poisons this section and
       StackUsage reports the deepest byte ever written, which the trace dump
       prints and scripts/scenarios.sh holds to a ceiling on every `make test`.

       The peak is ~12KB, reached by one path only: spawn plus ELF load. It
       was ~17KB until that chain was flattened, and what was removed was not
       code but copies the compiler makes of whole aggregates (see
       ImageSharing.shareablePageCount, TarFileSystem.open and
       ProcessManager.makeMetadata for the three shapes of it). Probed per
       phase, the path is no deeper at boot than from the spawn syscall at
       runtime, so a separate boot stack reclaimed after handoff would buy
       about a kilobyte and was dropped. Nothing recurses, and the segment
       loops iterate rather than nest, so the figure is bounded by the call
       chain and not by the input: 24KB is twice a peak that input cannot
       inflate, with the guard page under it and the matrix ceiling firing 8KB
       before the wall. */
    .stack (NOLOAD) : ALIGN(4096) {
        __stack_bottom = .;
        . += 0x6000; /* 24KB */
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
