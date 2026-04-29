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

// ── Header FDT ───────────────────────────────────────────────────────────────
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
static inline uint32_t fdt32_to_cpu(uint32_t val) {
    return __builtin_bswap32(val);
}

static inline int streq(const char *a, const char *b) {
    while (*a && *b) {
        if (*a != *b) return 0;
        a++; b++;
    }
    return (*a == '\0' && *b == '\0');
}

static inline int starts_with(const char *s, const char *pfx) {
    while (*pfx) {
        if (*s++ != *pfx++) return 0;
    }
    return 1;
}

static inline uint64_t read_be_cells(const uint32_t *cells, uint32_t n) {
    uint64_t v = 0;
    for (uint32_t i = 0; i < n; i++) {
        v = (v << 32) | fdt32_to_cpu(cells[i]);
    }
    return v;
}

// ── Principal Func ───────────────────────────────────────────────────────
int parse_platform_info(const void *fdt_ptr, PlatformInfo *out) {
    if (!fdt_ptr || !out) return -10;
    
    const uint8_t *fdt = (const uint8_t *)fdt_ptr;
    const struct fdt_header *h = (const struct fdt_header *)fdt;
    
    // ── Header Control ────────────────────────────────────────────────────
    if (fdt32_to_cpu(h->magic) != 0xd00dfeedU) return -1;
    
    uint32_t totalsize       = fdt32_to_cpu(h->totalsize);
    uint32_t off_dt_struct   = fdt32_to_cpu(h->off_dt_struct);
    uint32_t off_dt_strings  = fdt32_to_cpu(h->off_dt_strings);
    uint32_t size_dt_struct  = fdt32_to_cpu(h->size_dt_struct);
    uint32_t size_dt_strings = fdt32_to_cpu(h->size_dt_strings);
    
    if (totalsize < sizeof(struct fdt_header))             return -11;
    if (off_dt_struct  >= totalsize)                       return -12;
    if (off_dt_strings >= totalsize)                       return -12;
    if ((uint64_t)off_dt_struct  + size_dt_struct  > totalsize) return -13;
    if ((uint64_t)off_dt_strings + size_dt_strings > totalsize) return -14;
    
    out->dtb_base = (uint64_t)(uintptr_t)fdt_ptr;
    out->dtb_size = totalsize;
    
    // ── Section ptr ────────────────────────────────────────────────
    const uint8_t  *struct_start = fdt + off_dt_struct;
    const uint8_t  *struct_end   = struct_start + size_dt_struct;
    const char     *str_table    = (const char *)(fdt + off_dt_strings);
    const uint32_t *p            = (const uint32_t *)struct_start;
    
    // Valori di default per addr/size cells (spec DTB: 2/1)
    uint32_t root_addr_cells = 2, root_size_cells = 1;
    uint32_t mem_addr_cells  = 2, mem_size_cells  = 1;
    
    int depth = 0;
    
    int in_root   = 0;
    int in_memory = 0;
    int in_chosen = 0;
    int in_cpus   = 0;
    
    int uart_depth = 0;
    int gic_depth  = 0;
    
    // ── Loop principale ───────────────────────────────────────────────────────
    while ((const uint8_t *)p + 4 <= struct_end) {
        uint32_t tag = fdt32_to_cpu(*p++);
        
        // ── FDT_NOP ───────────────────────────────────────────────────────────
        if (tag == FDT_NOP) {
            continue;
            
            // ── FDT_BEGIN_NODE ────────────────────────────────────────────────────
        } else if (tag == FDT_BEGIN_NODE) {
            const char    *name = (const char *)p;
            const uint8_t *scan = (const uint8_t *)p;
            
            while (scan < struct_end && *scan != '\0') scan++;
            if (scan >= struct_end) return -20;
            
            size_t name_len = (size_t)(scan - (const uint8_t *)p) + 1; // include '\0'
            p += (name_len + 3) / 4;
            
            depth++;
            
            if (depth == 1) {
                in_root   = 1;
                in_memory = 0;
                in_chosen = 0;
                in_cpus   = 0;
                
            } else if (depth == 2) {
                in_root   = 0;
                in_memory = starts_with(name, "memory");
                in_chosen = streq(name, "chosen");
                in_cpus   = streq(name, "cpus");
                
                if (starts_with(name, "serial") || starts_with(name, "uart"))
                    uart_depth = depth;
                else if (starts_with(name, "intc") || starts_with(name, "interrupt-controller"))
                    gic_depth = depth;
                
            } else {
                if (in_cpus && starts_with(name, "cpu@"))
                    out->cpu_count++;
                
                if (starts_with(name, "serial") || starts_with(name, "uart"))
                    uart_depth = depth;
                else if (starts_with(name, "intc") || starts_with(name, "interrupt-controller"))
                    gic_depth = depth;
            }
            
            // ── FDT_END_NODE ──────────────────────────────────────────────────────
        } else if (tag == FDT_END_NODE) {
            if (uart_depth == depth) uart_depth = 0;
            if (gic_depth  == depth) gic_depth  = 0;
            
            depth--;
            
            if (depth < 0)  return -21;
            if (depth == 0) {
                in_root = 0; in_memory = 0; in_chosen = 0; in_cpus = 0;
                
            } else if (depth == 1) {
                in_memory = 0;
                in_chosen = 0;
                in_cpus   = 0;
                in_root   = 1;
            }
            
            // ── FDT_PROP ──────────────────────────────────────────────────────────
        } else if (tag == FDT_PROP) {
            if ((const uint8_t *)p + 8 > struct_end) return -22;
            
            uint32_t len     = fdt32_to_cpu(*p++);
            uint32_t nameoff = fdt32_to_cpu(*p++);
            
            if (nameoff >= size_dt_strings) return -23;
            const char     *prop_name = str_table + nameoff;
            
            uint32_t aligned_len = (len + 3u) & ~3u;
            if (aligned_len < len) return -24;                          // overflow
            if ((const uint8_t *)p + aligned_len > struct_end) return -24;
            
            const uint32_t *prop_data = p;
            
            if (in_root && streq(prop_name, "#address-cells")) {
                if (len >= 4) {
                    root_addr_cells = fdt32_to_cpu(*prop_data);
                    mem_addr_cells  = root_addr_cells;
                }
                
            } else if (in_root && streq(prop_name, "#size-cells")) {
                if (len >= 4) {
                    root_size_cells = fdt32_to_cpu(*prop_data);
                    mem_size_cells  = root_size_cells;
                }
                
            } else if (in_memory && streq(prop_name, "reg")) {
                uint32_t cells_needed = mem_addr_cells + mem_size_cells;
                if (cells_needed >= 1 && len >= cells_needed * 4) {
                    out->ram.base = read_be_cells(prop_data, mem_addr_cells);
                    out->ram.size = read_be_cells(prop_data + mem_addr_cells, mem_size_cells);
                }
                
            } else if (in_chosen) {
                if (streq(prop_name, "bootargs"))
                    out->bootargs = (const char *)prop_data;
                
                else if (streq(prop_name, "stdout-path"))
                    out->stdout_path = (const char *)prop_data;
                
                // ── UART ──────────────────────────────────────────────────────────
            } else if (uart_depth > 0) {
                if (streq(prop_name, "compatible")) {
                    const char *compat     = (const char *)prop_data;
                    uint32_t    bytes_left = len;
                    
                    while (bytes_left > 0 && out->uart.type == UART_UNKNOWN) {
                        if (streq(compat, "arm,pl011") || streq(compat, "arm,primecell"))
                            out->uart.type = UART_ARM_PL011;
                        else if (streq(compat, "ns16550a") || streq(compat, "ns8250"))
                            out->uart.type = UART_NS16550A;
                        else if (streq(compat, "snps,dw-apb-uart"))
                            out->uart.type = UART_SNPS_DW_APB;
                        else if (streq(compat, "brcm,bcm2835-aux-uart"))
                            out->uart.type = UART_BCM2835_AUX;
                        else if (streq(compat, "sifive,uart0"))
                            out->uart.type = UART_SIFIVE;
                        else if (streq(compat, "xlnx,xps-uartlite"))
                            out->uart.type = UART_XILINX_UARTLITE;
                        
                        // Avanza alla prossima stringa nella lista
                        size_t slen = 0;
                        while (slen < bytes_left && compat[slen] != '\0') slen++;
                        slen++; // include '\0'
                        
                        if (slen > bytes_left) break;
                        bytes_left -= (uint32_t)slen;
                        compat     += slen;
                    }
                    
                } else if (streq(prop_name, "reg") && out->uart.base_addr == 0) {
                    if (len >= mem_addr_cells * 4)
                        out->uart.base_addr = read_be_cells(prop_data, mem_addr_cells);
                    
                } else if (streq(prop_name, "clock-frequency") && len == 4) {
                    out->uart.clock_freq = fdt32_to_cpu(*prop_data);
                    
                } else if (streq(prop_name, "interrupts") && len >= 8 && out->uart.irq == 0) {
                    uint32_t irq_type = fdt32_to_cpu(prop_data[0]);
                    uint32_t irq_num  = fdt32_to_cpu(prop_data[1]);
                    out->uart.irq = irq_num + (irq_type == 0 ? 32u : 16u);
                }
                
                // ── GIC / Interrupt Controller ────────────────────────────────────
            } else if (gic_depth > 0) {
                if (streq(prop_name, "reg") && out->gic.gicd_base == 0) {
                    // Layout atteso: [gicd_base, gicd_size, gicc_base, gicc_size]
                    uint32_t stride = mem_addr_cells + mem_size_cells;
                    if (len >= stride * 4)
                        out->gic.gicd_base = read_be_cells(prop_data, mem_addr_cells);
                    
                    if (len >= stride * 2 * 4)
                        out->gic.gicc_base = read_be_cells(prop_data + stride, mem_addr_cells);
                }
            }
            
            p += aligned_len / 4;
            
            // ── FDT_END ───────────────────────────────────────────────────────────
        } else if (tag == FDT_END) {
            break;
            
        } else {
            return -25; // tag sconosciuto
        }
    }
    
    return 0;
}
