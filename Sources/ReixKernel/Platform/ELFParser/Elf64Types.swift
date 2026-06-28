//
//  Elf64Types.swift
//  ReixOS
//
//  ELF64 header layouts, mirroring the ELF spec field-for-field so a raw image
//  can be read straight into them. Replaces the former header-only `CElf` C
//  module; Swift lays out stored properties in declaration order with natural
//  alignment, which matches the (naturally aligned) ELF64 on-disk format.
//

struct Elf64_Ehdr_t {
    var e_ident: InlineArray<16, UInt8>
    var e_type     : UInt16
    var e_machine  : UInt16
    var e_version  : UInt32
    var e_entry    : UInt64
    var e_phoff    : UInt64
    var e_shoff    : UInt64
    var e_flags    : UInt32
    var e_ehsize   : UInt16
    var e_phentsize: UInt16
    var e_phnum    : UInt16
    var e_shentsize: UInt16
    var e_shnum    : UInt16
    var e_shstrndx : UInt16

    init() {
        e_ident     = InlineArray<16, UInt8>(repeating: 0)
        e_type      = 0
        e_machine   = 0
        e_version   = 0
        e_entry     = 0
        e_phoff     = 0
        e_shoff     = 0
        e_flags     = 0
        e_ehsize    = 0
        e_phentsize = 0
        e_phnum     = 0
        e_shentsize = 0
        e_shnum     = 0
        e_shstrndx  = 0
    }
}

struct Elf64_Phdr_t {
    var p_type  : UInt32
    var p_flags : UInt32
    var p_offset: UInt64
    var p_vaddr : UInt64
    var p_paddr : UInt64
    var p_filesz: UInt64
    var p_memsz : UInt64
    var p_align : UInt64

    init() {
        p_type   = 0
        p_flags  = 0
        p_offset = 0
        p_vaddr  = 0
        p_paddr  = 0
        p_filesz = 0
        p_memsz  = 0
        p_align  = 0
    }
}
