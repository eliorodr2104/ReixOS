//
//  elf_types.h
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 01/05/2026.
//

#include <stdint.h>

typedef struct {
    unsigned char e_ident[16]; // Magic number & system info
    uint16_t      e_type;      // File type (Exec, Dynamic, etc...)
    uint16_t      e_machine;   // Arch (AArch64 = 0xB7)
    uint32_t      e_version;   // ELF Version
    uint64_t      e_entry;     // Entry point: first instruction address
    uint64_t      e_phoff;     // Offset Program Header Table
    uint64_t      e_shoff;     // Offset Section Header Table
    uint32_t      e_flags;     // Flag CPU
    uint16_t      e_ehsize;    // Size self header
    uint16_t      e_phentsize; // Size Program Header
    uint16_t      e_phnum;     // Numbers Program Headers
    uint16_t      e_shentsize; // Size Section Header
    uint16_t      e_shnum;     // Numbers Section Headers
    uint16_t      e_shstrndx;  // Index name section
} Elf64_Ehdr_t;

// Program Header
typedef struct {
    uint32_t p_type;   // Segment type
    uint32_t p_flags;  // fLAGS (R, W, X)
    uint64_t p_offset; // Offset file init data section
    uint64_t p_vaddr;  // Virtual address where load segment
    uint64_t p_paddr;  // Physical Address
    uint64_t p_filesz; // Size data into file
    uint64_t p_memsz;  // Size data into memory (if this > p_filesz for BSS)
    uint64_t p_align;  // Padding
} Elf64_Phdr_t;

#define PT_LOAD 1
