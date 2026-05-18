# Paths and tools
LLVM_BIN    = /opt/homebrew/opt/llvm/bin
LLD_BIN     = /opt/homebrew/opt/lld@20/bin
CLANG       = $(LLVM_BIN)/clang
LD          = $(LLD_BIN)/ld.lld
OBJCOPY     = $(LLVM_BIN)/llvm-objcopy
SWIFTC      = /Users/eliorodr2104/.swiftly/bin/swiftc

TARGET      = aarch64-none-none-elf
USER_DIR    = Sources/Userland
USER_MOD_DIR = $(USER_DIR)/Modules


# Syscall Dir
SYSCALL_DIR      = Sources/ReixKernel/Syscall
SYSCALL_ARCH_DIR = Sources/ReixKernel/Arch/aarch64/Syscall


# Flag
C_FLAGS     = -target $(TARGET) -ffreestanding -O2 -nostdlib -fno-stack-protector -ISources/ReixKernel/Platform/DeviceTree -g
SWIFT_FLAGS = -target $(TARGET) -enable-experimental-feature Embedded -enable-experimental-feature Extern -I ./Sources/ReixKernel/Platform/ElfParser -wmo -Osize -parse-as-library -g

# Find all kernel sources
# This not add a Userland sources for the kernel bin.
KERNEL_SWIFT_SRCS := $(shell find Sources -name "*.swift" -not -path "$(USER_DIR)/*" -not -path "$(SYSCALL_DIR)/*" -not -path "$(SYSCALL_ARCH_DIR)/*")
KERNEL_C_SRCS     := $(shell find Sources -name "*.c" -not -path "$(USER_DIR)/*" -not -path "$(SYSCALL_DIR)/*" -not -path "$(SYSCALL_ARCH_DIR)/*")
KERNEL_ASM_SRCS   := $(shell find Sources -name "*.S" -not -path "$(USER_DIR)/*" -not -path "$(SYSCALL_DIR)/*" -not -path "$(SYSCALL_ARCH_DIR)/*")

KERNEL_OBJS := $(KERNEL_C_SRCS:.c=.o) $(KERNEL_ASM_SRCS:.S=.o)
SWIFT_KERNEL_OBJ := swift_kernel.o


# Dynamic Discovery for Userland Modules
# Finds files inside specific subfolders or matching the module names pattern
# 1. Trova prima i sorgenti dei moduli Userland (lascia invariato questo blocco)
RX_CORE_SRCS := $(wildcard $(SYSCALL_ARCH_DIR)/*.swift)
RX_IO_SRCS   := $(shell find $(SYSCALL_DIR) -type f -name "*.swift" \( -name "*IO*" -o -path "*/IO/*" -o -path "*/RXIO/*" \))
RX_TASK_SRCS := $(shell find $(SYSCALL_DIR) -type f -name "*.swift" \( -name "*Task*" -o -path "*/Task/*" -o -path "*/RXTask/*" \))

# 2. Trova tutti i file di base escludendo SOLO la cartella Userland principale
KERNEL_SWIFT_SRCS_ALL := $(shell find Sources -name "*.swift" -not -path "$(USER_DIR)/*")
KERNEL_C_SRCS_ALL     := $(shell find Sources -name "*.c" -not -path "$(USER_DIR)/*")
KERNEL_ASM_SRCS_ALL   := $(shell find Sources -name "*.S" -not -path "$(USER_DIR)/*")

# 3. Filtra via CHIRURGICAMENTE solo i file che appartengono ai moduli Userland ad alto livello (IO e Task)
# Nota: I file in RX_CORE_SRCS (come SyscallNumber) RIMANGONO nel kernel perché servono a entrambi!
KERNEL_SWIFT_SRCS := $(filter-out $(RX_IO_SRCS) $(RX_TASK_SRCS), $(KERNEL_SWIFT_SRCS_ALL))
KERNEL_C_SRCS     := $(KERNEL_C_SRCS_ALL)
KERNEL_ASM_SRCS   := $(KERNEL_ASM_SRCS_ALL)

KERNEL_OBJS := $(KERNEL_C_SRCS:.c=.o) $(KERNEL_ASM_SRCS:.S=.o)
SWIFT_KERNEL_OBJ := swift_kernel.o

# All `.S` files os Syscall/Arch
USER_LIB_ASM   := $(wildcard $(SYSCALL_ARCH_DIR)/*.S)
USER_LIB_OBJS  := $(USER_LIB_ASM:.S=.o)


# Module Outputs
MOD_CORE_MOD := $(USER_MOD_DIR)/RXSyscallCore.swiftmodule
MOD_CORE_OBJ := $(USER_MOD_DIR)/RXSyscallCore.o

MOD_IO_MOD   := $(USER_MOD_DIR)/RXIO.swiftmodule
MOD_IO_OBJ   := $(USER_MOD_DIR)/RXIO.o

MOD_TASK_MOD := $(USER_MOD_DIR)/RXTask.swiftmodule
MOD_TASK_OBJ := $(USER_MOD_DIR)/RXTask.o

ALL_USER_MODS := $(MOD_CORE_MOD) $(MOD_IO_MOD) $(MOD_TASK_MOD)
ALL_USER_OBJS := $(MOD_CORE_OBJ) $(MOD_IO_OBJ) $(MOD_TASK_OBJ)


# App sources Userland, all `.swift` is maked in ELF file
USER_APPS_SRCS := $(wildcard $(USER_DIR)/*.swift)
USER_APPS_ELFS := $(patsubst $(USER_DIR)/%.swift, $(USER_DIR)/%.elf, $(USER_APPS_SRCS))
USER_STUBS_OBJ := $(USER_DIR)/user_stubs.o


# Principal Rules
.PHONY: all clean run userland

all: initrd.tar kernel.bin

# Kernel Compilation
%.o: %.S
	$(CLANG) -target $(TARGET) -c $< -o $@

%.o: %.c
	$(CLANG) $(C_FLAGS) -c $< -o $@

$(SWIFT_KERNEL_OBJ): $(KERNEL_SWIFT_SRCS)
	$(SWIFTC) $(SWIFT_FLAGS) -c $(KERNEL_SWIFT_SRCS) -o $@

kernel.elf: $(KERNEL_OBJS) $(SWIFT_KERNEL_OBJ)
	$(LD) -T linker.ld --nmagic -o $@ $^

kernel.bin: kernel.elf
	$(OBJCOPY) -O binary $< $@


# Userland Modules Generation
$(USER_MOD_DIR):
	@mkdir -p $(USER_MOD_DIR)

$(MOD_CORE_MOD): $(RX_CORE_SRCS) | $(USER_MOD_DIR)
	@echo "Compile Module: RXSyscallCore"
	$(SWIFTC) $(SWIFT_FLAGS) -emit-module -module-name RXSyscallCore -emit-module-path $@ -c $(RX_CORE_SRCS) -o $(MOD_CORE_OBJ)

$(MOD_IO_MOD): $(RX_IO_SRCS) $(MOD_CORE_MOD) | $(USER_MOD_DIR)
	@echo "Compile Module: RXIO"
	$(SWIFTC) $(SWIFT_FLAGS) -I $(USER_MOD_DIR) -emit-module -module-name RXIO -emit-module-path $@ -c $(RX_IO_SRCS) -o $(MOD_IO_OBJ)

$(MOD_TASK_MOD): $(RX_TASK_SRCS) $(MOD_CORE_MOD) | $(USER_MOD_DIR)
	@echo "Compile Module: RXTask (With Process)"
	$(SWIFTC) $(SWIFT_FLAGS) -I $(USER_MOD_DIR) -emit-module -module-name RXTask -emit-module-path $@ -c $(RX_TASK_SRCS) -o $(MOD_TASK_OBJ)


# Userland apps compile
$(USER_STUBS_OBJ): $(USER_DIR)/user_stubs.c
	$(CLANG) $(C_FLAGS) -c $< -o $@

$(USER_DIR)/%.elf: $(USER_DIR)/%.swift $(ALL_USER_MODS) $(USER_STUBS_OBJ) $(USER_LIB_OBJS)
	@echo "Compilazione Userland ELF: $@"
	$(SWIFTC) $(SWIFT_FLAGS) -I $(USER_MOD_DIR) -c $< -o $(@:.elf=.o)
	$(LD) -T user.ld -o $@ $(@:.elf=.o) $(USER_STUBS_OBJ) $(USER_LIB_OBJS) $(ALL_USER_OBJS)
	rm $(@:.elf=.o)

userland: $(USER_APPS_ELFS)


# Initrd Source
initrd.tar: $(USER_APPS_ELFS)
	tar -cf $@ -C $(USER_DIR) $(notdir $(USER_APPS_ELFS))

# Utility Commands
clean:
	rm -f kernel.elf kernel.bin initrd.tar $(SWIFT_KERNEL_OBJ)
	rm -rf $(USER_MOD_DIR)
	find Sources -name "*.o" -delete
	find Sources -name "*.elf" -delete

run: all
	qemu-system-aarch64 \
		-machine virt,gic-version=2 \
		-cpu cortex-a53 \
		-nographic \
		-kernel kernel.bin \
		-initrd ./initrd.tar
	$(MAKE) clean
