//
//  fdt_parser.h
//  ReixOS
//

#ifndef platform_info_h
#define platform_info_h

#include <stdint.h>
#include <stddef.h>

typedef enum {
    UART_UNKNOWN = 0,
    UART_ARM_PL011,       // "arm,pl011" - Classic ARM (Raspberry Pi main UART, QEMU virt)
    UART_NS16550A,        // "ns16550a" o "8250" - Standard PC & another SoC
    UART_SNPS_DW_APB,     // "snps,dw-apb-uart" - DesignWare (ARM & RISC-V)
    UART_BCM2835_AUX,     // "brcm,bcm2835-aux-uart" - Mini UART for Raspberry Pi
    UART_SIFIVE,          // "sifive,uart0" - RISC-V SiFive
    UART_XILINX_UARTLITE  // "xlnx,xps-uartlite" - FPGA Xilinx
} UartType;

typedef struct {
    uint64_t base;
    uint64_t size;
} MemRegion;

typedef struct {
    uint64_t base_addr;
    UartType type;
    uint32_t irq;
    uint32_t clock_freq;
} UartInfo;

typedef struct {
    uint64_t gicd_base; // GIC Distributor
    uint64_t gicc_base; // GIC CPU Interface
} GicInfo;

typedef struct {
    uint64_t dtb_base;
    uint64_t initrd_start;
    uint64_t initrd_end;
    
    const char* bootargs;
    const char* stdout_path;
    
    uint32_t dtb_size;
    uint32_t cpu_count;
    
    MemRegion ram;
        
    UartInfo uart;
    GicInfo gic;
    
} PlatformInfo;

int parse_platform_info(const void* fdt_ptr, PlatformInfo* out);

#endif
