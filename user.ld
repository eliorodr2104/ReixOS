ENTRY(_start)

/* User image base = 512 GiB + 4 MiB (L0 entry 1)
 * L0[0] (< 512 GiB) is reserved for the kernel mapping shared by all user address space
 * code must live at or above 512 GiB
 */

/* W^X for userland images
 *
 * ElfParser.loadSegments maps one 4 KiB page at a time and gives each page the
 * *union* of the p_flags of every PT_LOAD that covers it. Left to itself the
 * linker packs the segments byte-adjacent (they only have to be congruent
 * modulo p_align inside the *file*), so the tail of the executable segment and
 * the head of the writable segment share a page — and that page comes out RWX.
 * The only fix available to the loader would be to let one segment win the
 * whole page, which silently drops either X from the .text tail or W from the
 * .data head; the fix belongs here, in the layout.
 *
 * So every segment boundary below is pushed to a 4 KiB boundary. `-z
 * separate-code` cannot do this for us: lld only honours it from
 * fixSectionAlignments(), which runs solely when there is no SECTIONS command,
 * and GNU ld implements it by swapping in a different built-in script — which
 * -T replaces. With a script, the flag is a silent no-op.
 *
 * The alignment is the literal 4096 and NOT CONSTANT(MAXPAGESIZE): lld's
 * maxPageSize on AArch64 is 65536, while this kernel's page granule (and the
 * loader's own page loop) is 4 KiB. Aligning to 64 KiB would pad every image by
 * up to 192 KiB of memory for no gain.
 *
 * The explicit PHDRS is what makes the read-only middle segment possible at
 * all. Segment flags are otherwise derived from the section flags, and .got
 * carries SHF_WRITE; declaring FLAGS here overrides that. FLAGS bits are the
 * ELF p_flags: 1 = X, 2 = W, 4 = R. */
PHDRS
{
    text   PT_LOAD FLAGS(4 | 1); /* r-x  .text                         */
    rodata PT_LOAD FLAGS(4);     /* r--  .rodata, .swift_modhash, .got */
    data   PT_LOAD FLAGS(4 | 2); /* rw-  .data, .bss                   */
}

SECTIONS
{
    . = 0x8000400000;

    .text : ALIGN(4096) {
        *(.text*)
    } :text


    /* Read-only, non-executable. Before this split .rodata shared the .text
     * tail page in every image.
     */
    .rodata : ALIGN(4096) {
        *(.rodata)
        *(.rodata.*)
        *(.swift_modhash)
    } :rodata


    /* .got is placed in READ-ONLY memory here.
     *
     * Binary features: ET_EXEC without relocations. The 1-entry .got (__stack_chk_guard)
     * is never written at runtime (PT_GNU_RELRO). SHF_WRITE is ignored via PHDRS FLAGS.
     *
     * Boundary effect: Explicitly placing .got (and GOT family / .data.rel.ro*) here
     * prevents orphan placement and pushes the RW boundary AFTER them.
     *
     * NOTE: New writable sections MUST be explicitly added to .data below,
     * or orphan placement will wrongfully put them in this read-only segment.
     */
    .got : ALIGN(8) {
        *(.got)
        *(.got.plt)
        *(.igot*)
        *(.data.rel.ro)
        *(.data.rel.ro.*)
    } :rodata


    .data : ALIGN(4096) {
        *(.data)
        *(.data.*)
    } :data

    /* .bss shares the writable segment with .data, so page-aligning it would
     * buy no permission separation and only round up p_memsz
     */
    .bss : ALIGN(8) {
        *(.bss)
        *(.bss.*)
        *(COMMON)
    } :data
}
