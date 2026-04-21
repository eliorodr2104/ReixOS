//
//  fdt_wrapper.c
//  ReixOS
//
//  Created by Eliomar Alejandro Rodriguez Ferrer on 20/04/2026.
//

#include <stdint.h>
#include <stddef.h>

#define FDT_BEGIN_NODE 0x00000001
#define FDT_END_NODE   0x00000002
#define FDT_PROP       0x00000003
#define FDT_END        0x00000009

typedef struct {
    uint64_t base;
    uint64_t size;
    uint64_t dtbSize;
} RamInfo;

static inline uint32_t fdt32_to_cpu(uint32_t val) {
    return __builtin_bswap32(val);
}

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

static inline uint64_t read_be_cells(const uint32_t *cells, uint32_t n)
{
    uint64_t v = 0;
    for (uint32_t i = 0; i < n; i++) {
        v = (v << 32) | fdt32_to_cpu(cells[i]);
    }
    return v;
}

uint8_t get_ram_info(const void* fdt_ptr, RamInfo* out) {
    out->base = 0;
    out->size = 0;
    
    if (!fdt_ptr || !out) {
        if (out) return -10;
    }
    
    const uint8_t *fdt = (const uint8_t*)fdt_ptr;
    const struct fdt_header* h = (const struct fdt_header*)fdt;
    
    // Header checks
    if (fdt32_to_cpu(h->magic) != 0xd00dfeed) {
        return -1;
    }
    
    uint32_t totalsize      = fdt32_to_cpu(h->totalsize);
    uint32_t off_dt_struct  = fdt32_to_cpu(h->off_dt_struct);
    uint32_t off_dt_strings = fdt32_to_cpu(h->off_dt_strings);
    uint32_t size_dt_struct = fdt32_to_cpu(h->size_dt_struct);
    uint32_t size_dt_strings= fdt32_to_cpu(h->size_dt_strings);
    
    if (totalsize < sizeof(struct fdt_header)) {
        return -11;
    }
    if (off_dt_struct >= totalsize || off_dt_strings >= totalsize) {
        return -12;
    }
    if ((uint64_t)off_dt_struct + size_dt_struct > totalsize) {
        return -13;
    }
    if ((uint64_t)off_dt_strings + size_dt_strings > totalsize) {
        return -14;
    }
    
    const uint8_t *struct_start = fdt + off_dt_struct;
    const uint8_t *struct_end   = struct_start + size_dt_struct;
    const char *str_table       = (const char*)(fdt + off_dt_strings);
    
    const uint32_t *p = (const uint32_t*)struct_start;
    
    // Defaults from DT spec (if not present in parent): #address-cells=2, #size-cells=1
    uint32_t root_addr_cells = 2;
    uint32_t root_size_cells = 1;
    uint32_t mem_addr_cells  = 2;
    uint32_t mem_size_cells  = 1;
    
    int depth = 0;
    int in_root = 0;
    int in_memory_node = 0;
    
    while ((const uint8_t*)p + 4 <= struct_end) {
        uint32_t tag = fdt32_to_cpu(*p++);
        
        if (tag == FDT_BEGIN_NODE) {
            const char *name = (const char*)p;
            
            // string must terminate before struct_end
            const uint8_t *scan = (const uint8_t*)p;
            while (scan < struct_end && *scan != '\0') scan++;
            if (scan >= struct_end) {
                return -20;
            }
            
            if (depth == 0) {
                in_root = 1;
                in_memory_node = 0;
                mem_addr_cells = root_addr_cells;
                mem_size_cells = root_size_cells;
                
            } else {
                in_root = 0;
                if (starts_with(name, "memory")) {
                    in_memory_node = 1;
                    // memory node inherits parent (root) cells
                    mem_addr_cells = root_addr_cells;
                    mem_size_cells = root_size_cells;
                    
                } else {
                    in_memory_node = 0;
                }
            }
            
            size_t len = (size_t)(scan - (const uint8_t*)p) + 1; // includes '\0'
            p += (len + 3) / 4;
            depth++;
            
        } else if (tag == FDT_END_NODE) {
            if (depth <= 0) {
                return -21;
            }
            
            depth--;
            in_memory_node = 0;
            in_root = (depth == 0);
            
        } else if (tag == FDT_PROP) {
            if ((const uint8_t*)p + 8 > struct_end) {
                return -22;
            }
            
            uint32_t len = fdt32_to_cpu(*p++);
            uint32_t nameoff = fdt32_to_cpu(*p++);
            
            if (nameoff >= size_dt_strings) {
                return -23;
            }
            
            const char* prop_name = str_table + nameoff;
            
            if ((const uint8_t*)p + ((len + 3) & ~3u) > struct_end) {
                return -24;
            }
            
            // Parse root cell sizes
            if (in_root && streq(prop_name, "#address-cells")) {
                if (len >= 4) root_addr_cells = fdt32_to_cpu(*(const uint32_t*)p);
                
            } else if (in_root && streq(prop_name, "#size-cells")) {
                if (len >= 4) root_size_cells = fdt32_to_cpu(*(const uint32_t*)p);
            }
            
            // Parse memory reg
            if (in_memory_node && streq(prop_name, "reg")) {
                uint32_t need_cells = mem_addr_cells + mem_size_cells;
                uint32_t need_bytes = need_cells * 4;
                
                if (mem_addr_cells == 0 || mem_addr_cells > 2 ||
                    mem_size_cells > 2 || len < need_bytes) {
                    return -3;
                }
                
                const uint32_t *prop_data = p;
                out->base    = read_be_cells(prop_data, mem_addr_cells);
                out->size    = read_be_cells(prop_data + mem_addr_cells, mem_size_cells);
                out->dtbSize = totalsize;
                return 1;
            }
            
            p += (len + 3) / 4;
            
        } else if (tag == FDT_END) {
            break;
            
        } else {
            return -25;
        }
    }
    
    return -2; // memory node/reg not found
}
