//
//  fdt_wrapper.c
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

#include "fdt_parser.h"

// ── Const FDT ─────────────────────────────────────────────────────────────
#define FDT_BEGIN_NODE 0x00000001
#define FDT_END_NODE   0x00000002
#define FDT_PROP       0x00000003
#define FDT_NOP        0x00000004
#define FDT_END        0x00000009

#define MAX_DEPTH 16

struct fdt_header {
    uint32_t magic;
    uint32_t totalsize;
    uint32_t off_dt_struct;
    uint32_t off_dt_strings;
    uint32_t off_mem_rsvmap;
    uint32_t version;
    uint32_t last_comp_version;
    uint32_t boot_cpuid_phys;
    uint32_t size_dt_strings;
    uint32_t size_dt_struct;
};

// ── Utility ──────────────────────────────────────────────────────────────────
// Usiamo target("general-regs-only") per evitare l'eccezione SIMD/NEON EL1
__attribute__((target("general-regs-only")))
static inline uint32_t fdt32_to_cpu(uint32_t val) {
    return __builtin_bswap32(val);
}

__attribute__((target("general-regs-only")))
static inline int streq(const char *a, const char *b) {
    if (!a || !b) return 0;
    while (*a && *b && (*a == *b)) { a++; b++; }
    return (*a == *b);
}

__attribute__((target("general-regs-only")))
static uint64_t read_be_cells(const uint32_t *cells, uint32_t n) {
    uint64_t v = 0;
    for (uint32_t i = 0; i < n; i++) {
        v = (v << 32) | fdt32_to_cpu(cells[i]);
    }
    return v;
}

// ── Principal Func ───────────────────────────────────────────────────────
__attribute__((target("general-regs-only")))
int parse_platform_info(const void *fdt_ptr, PlatformInfo *out) {
    if (!fdt_ptr || !out) return -10;
    
    // Inizializzazione output
    out->uart.type = 0;
    out->uart.base_addr = 0;
    out->cpu_count = 0;
    out->initrd_start = 0;
    out->initrd_end = 0;
    
    const uint8_t *fdt = (const uint8_t *)fdt_ptr;
    const struct fdt_header *h = (const struct fdt_header *)fdt;
    
    if (fdt32_to_cpu(h->magic) != 0xd00dfeedU) return -1;
    
    uint32_t totalsize   = fdt32_to_cpu(h->totalsize);
    uint32_t off_struct  = fdt32_to_cpu(h->off_dt_struct);
    uint32_t off_strings = fdt32_to_cpu(h->off_dt_strings);
    uint32_t size_struct = fdt32_to_cpu(h->size_dt_struct);
    
    out->dtb_base = (uint64_t)(uintptr_t)fdt_ptr;
    out->dtb_size = totalsize;
    
    const uint8_t *struct_end = fdt + off_struct + size_struct;
    const char *str_table     = (const char *)(fdt + off_strings);
    const uint32_t *p         = (const uint32_t *)(fdt + off_struct);
    
    // Stack per ereditare correttamente #address-cells dai genitori
    uint32_t ac[MAX_DEPTH];
    uint32_t sc[MAX_DEPTH];
    for (int i = 0; i < MAX_DEPTH; i++) { ac[i] = 2; sc[i] = 1; }
    
    int depth = 0;
    
    // Flag di stato del nodo corrente
    int is_uart_node   = 0;
    int is_gic_node    = 0;
    int is_mem_node    = 0;
    int is_chosen_node = 0;
    
    const uint32_t *cur_reg = 0;
    uint32_t cur_reg_len = 0;
    const uint32_t *cur_intr = 0;
    uint32_t cur_intr_len = 0;
    
    while ((const uint8_t *)p + 4 <= struct_end) {
        uint32_t tag = fdt32_to_cpu(*p++);
        
        if (tag == FDT_BEGIN_NODE) {
            const char *name = (const char *)p;
            size_t nlen = 0;
            while (((const char *)p)[nlen] != '\0') nlen++;
            p += (nlen + 1 + 3) / 4;
            
            depth++;
            
            // Ereditiamo il layout delle celle dal padre per il nuovo livello
            if (depth > 0 && depth < MAX_DEPTH) {
                ac[depth] = ac[depth - 1];
                sc[depth] = sc[depth - 1];
            }
            
            // Identificazione del nodo
            is_chosen_node = streq(name, "chosen");
            is_uart_node   = 0;
            is_gic_node    = 0;
            is_mem_node    = (depth == 2 && name[0] == 'm' && name[1] == 'e'); // nodo "memory"
            
            cur_reg = 0; cur_reg_len = 0;
            cur_intr = 0; cur_intr_len = 0;
            
            if (depth == 3 && name[0] == 'c' && name[1] == 'p' && name[2] == 'u' && name[3] == '@') {
                out->cpu_count++;
            }
            
        } else if (tag == FDT_END_NODE) {
            depth--;
            if (depth == 0) break;
            // Quando chiudiamo un nodo, resettiamo i flag di tipo
            is_chosen_node = 0;
            is_uart_node = 0;
            is_mem_node = 0;
            is_gic_node = 0;
            
        } else if (tag == FDT_PROP) {
            uint32_t len = fdt32_to_cpu(*p++);
            uint32_t nameoff = fdt32_to_cpu(*p++);
            const char *prop_name = str_table + nameoff;
            const uint32_t *prop_data = p;
            p += (len + 3) / 4;
            
            // --- CALCOLO CELLE GENITORE ---
            // IMPORTANTE: Le proprietà di questo nodo (reg, initrd) usano
            // le celle definite dal PADRE (depth - 1).
            uint32_t p_ac = (depth > 0 && depth < MAX_DEPTH) ? ac[depth - 1] : 2;
            uint32_t p_sc = (depth > 0 && depth < MAX_DEPTH) ? sc[depth - 1] : 1;
            
            // Aggiorna le celle per i FUTURI figli di questo nodo
            if (streq(prop_name, "#address-cells")) {
                if (depth < MAX_DEPTH) ac[depth] = fdt32_to_cpu(*prop_data);
            } else if (streq(prop_name, "#size-cells")) {
                if (depth < MAX_DEPTH) sc[depth] = fdt32_to_cpu(*prop_data);
            }
            
            // Estrazione dati generici
            else if (streq(prop_name, "reg")) {
                cur_reg = prop_data;
                cur_reg_len = len;
            } else if (streq(prop_name, "interrupts")) {
                cur_intr = prop_data;
                cur_intr_len = len;
            } else if (streq(prop_name, "bootargs")) {
                out->bootargs = (const char *)prop_data;
            }
            
            // --- GESTIONE CHOSEN (INITRD) ---
            if (is_chosen_node) {
                if (streq(prop_name, "linux,initrd-start")) {
                    out->initrd_start = read_be_cells(prop_data, p_ac);
                } else if (streq(prop_name, "linux,initrd-end")) {
                    out->initrd_end = read_be_cells(prop_data, p_ac);
                }
            }
            
            // Identificazione periferiche tramite 'compatible'
            if (streq(prop_name, "compatible")) {
                const char *compat = (const char *)prop_data;
                uint32_t left = len;
                
                while (left > 0) {
                    if (streq(compat, "arm,pl011") || streq(compat, "arm,primecell")) {
                        out->uart.type = UART_ARM_PL011;
                        is_uart_node = 1;
                    } else if (streq(compat, "ns16550a") || streq(compat, "snps,dw-apb-uart")) {
                        out->uart.type = UART_NS16550A;
                        is_uart_node = 1;
                    } else if (streq(compat, "arm,gic-400") || streq(compat, "arm,cortex-a15-gic")) {
                        is_gic_node = 1;
                    }
                    
                    size_t slen = 0;
                    while (slen < left && compat[slen] != '\0') slen++;
                    slen++; // include '\0'
                    if (slen > left) break;
                    compat += slen;
                    left -= (uint32_t)slen;
                }
            }
            
            // --- PROCESSAMENTO PERIFERICHE IDENTIFICATE ---
            if (is_uart_node) {
                if (cur_reg && cur_reg_len >= p_ac * 4) {
                    out->uart.base_addr = read_be_cells(cur_reg, p_ac);
                }
                if (cur_intr && cur_intr_len >= 8) {
                    out->uart.irq = fdt32_to_cpu(cur_intr[1]) + 32;
                }
            }
            else if (is_gic_node && cur_reg) {
                uint32_t stride = p_ac + p_sc;
                if (cur_reg_len >= stride * 4)
                    out->gic.gicd_base = read_be_cells(cur_reg, p_ac);
                if (cur_reg_len >= stride * 2 * 4)
                    out->gic.gicc_base = read_be_cells(cur_reg + stride, p_ac);
            }
            else if (is_mem_node && cur_reg && cur_reg_len >= (p_ac + p_sc) * 4) {
                out->ram.base = read_be_cells(cur_reg, p_ac);
                out->ram.size = read_be_cells(cur_reg + p_ac, p_sc);
            }
            
        } else if (tag == FDT_NOP) {
            continue;
        } else if (tag == FDT_END) {
            break;
        }
    }
    
    return 0;
}
