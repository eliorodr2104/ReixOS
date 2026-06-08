# Paths and tools
LLVM_BIN    = /opt/homebrew/opt/llvm/bin
LLD_BIN     = /opt/homebrew/opt/lld@20/bin
CLANG       = $(LLVM_BIN)/clang
LD          = $(LLD_BIN)/ld.lld
OBJCOPY     = $(LLVM_BIN)/llvm-objcopy
SWIFTC      = /Users/mac/.swiftly/bin/swiftc

TARGET      = aarch64-none-none-elf
USER_DIR    = Sources/Userland
USER_MOD_DIR = $(USER_DIR)/Modules

# Syscall Dir
SYSCALL_DIR      = Sources/ReixKernel/Syscall
SYSCALL_ARCH_DIR = Sources/ReixKernel/Arch/aarch64/Syscall

# Flags
C_FLAGS     = -target $(TARGET) -ffreestanding -O2 -nostdlib -fno-stack-protector -ISources/ReixKernel/Platform/DeviceTree -g
SWIFT_FLAGS = -target $(TARGET) -enable-experimental-feature Embedded -enable-experimental-feature Extern -I ./Sources/ReixKernel/Platform/ElfParser -wmo -Osize -parse-as-library -g

# =============================================================================
# DYNAMIC DISCOVERY
# =============================================================================

REIX_MOD_SRCS := $(shell find $(SYSCALL_DIR) -type f -name "*.swift")

RX_CORE_SRCS  := $(wildcard $(SYSCALL_ARCH_DIR)/*.swift)

# Shared IPC data structures: compiled into BOTH the kernel (picked up by the
# KERNEL_SWIFT_SRCS find below, since it lives under Sources/ReixKernel) and the
# Reix module, so userland and kernel agree on the same Message/MessageTag ABI.
IPC_SHARED_SRCS := Sources/ReixKernel/InterProcessControl/RXIPCShared.swift

KERNEL_SWIFT_SRCS_ALL := $(shell find Sources -name "*.swift" -not -path "$(USER_DIR)/*")
KERNEL_C_SRCS_ALL     := $(shell find Sources -name "*.c" -not -path "$(USER_DIR)/*")
KERNEL_ASM_SRCS_ALL   := $(shell find Sources -name "*.S" -not -path "$(USER_DIR)/*")

KERNEL_SWIFT_SRCS := $(filter-out $(REIX_MOD_SRCS), $(KERNEL_SWIFT_SRCS_ALL))
KERNEL_C_SRCS     := $(KERNEL_C_SRCS_ALL)
KERNEL_ASM_SRCS   := $(KERNEL_ASM_SRCS_ALL)

KERNEL_OBJS      := $(KERNEL_C_SRCS:.c=.o) $(KERNEL_ASM_SRCS:.S=.o)
SWIFT_KERNEL_OBJ := swift_kernel.o

USER_LIB_ASM   := $(wildcard $(SYSCALL_ARCH_DIR)/*.S)
USER_LIB_OBJS  := $(USER_LIB_ASM:.S=.o)

# =============================================================================
# MODULE OUTPUTS
# =============================================================================
MOD_REIX_MOD  := $(USER_MOD_DIR)/Reix.swiftmodule
MOD_REIX_OBJ  := $(USER_MOD_DIR)/Reix.o

ALL_USER_MODS := $(MOD_REIX_MOD)
ALL_USER_OBJS := $(MOD_REIX_OBJ)

# App sources Userland
#
# Due tipi di app, entrambi producono un singolo <nome>.elf:
#   * single-file : un *.swift direttamente sotto Sources/Userland (es. Child, Init)
#   * directory   : una sottocartella con uno o piu *.swift (es. NameServer,
#                   ProcessServer); tutti i suoi sorgenti compilano insieme (-wmo).
USER_SINGLE_SRCS := $(wildcard $(USER_DIR)/*.swift)
USER_SINGLE_ELFS := $(patsubst $(USER_DIR)/%.swift, $(USER_DIR)/%.elf, $(USER_SINGLE_SRCS))

USER_APP_DIRS    := $(filter-out Modules, $(notdir $(shell find $(USER_DIR) -mindepth 1 -maxdepth 1 -type d)))
USER_DIR_ELFS    := $(patsubst %, $(USER_DIR)/%.elf, $(USER_APP_DIRS))

USER_APPS_ELFS   := $(USER_SINGLE_ELFS) $(USER_DIR_ELFS)
USER_STUBS_OBJ   := $(USER_DIR)/user_stubs.o


# =============================================================================
# PRINCIPAL RULES
# =============================================================================
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

# Userland Module Generation
$(USER_MOD_DIR):
	@mkdir -p $(USER_MOD_DIR)

$(MOD_REIX_MOD): $(REIX_MOD_SRCS) $(RX_CORE_SRCS) $(IPC_SHARED_SRCS) | $(USER_MOD_DIR)
	@echo "Compilazione Modulo Unificato: Reix"
	$(SWIFTC) $(SWIFT_FLAGS) -emit-module -module-name Reix -emit-module-path $@ -c $(REIX_MOD_SRCS) $(RX_CORE_SRCS) $(IPC_SHARED_SRCS) -o $(MOD_REIX_OBJ)

# Userland apps compile
$(USER_STUBS_OBJ): $(USER_DIR)/user_stubs.c
	$(CLANG) $(C_FLAGS) -c $< -o $@

$(USER_DIR)/%.elf: $(USER_DIR)/%.swift $(ALL_USER_MODS) $(USER_STUBS_OBJ) $(USER_LIB_OBJS)
	@echo "Compilazione Userland ELF: $@"
	$(SWIFTC) $(SWIFT_FLAGS) -I $(USER_MOD_DIR) -c $< -o $(@:.elf=.o)
	$(LD) -T user.ld -o $@ $(@:.elf=.o) $(USER_STUBS_OBJ) $(USER_LIB_OBJS) $(ALL_USER_OBJS)
	rm $(@:.elf=.o)

# Directory apps: tutti i *.swift della cartella compilano insieme in un solo elf.
# Una regola esplicita per ogni cartella (override del pattern single-file sopra).
define USER_DIR_APP_RULE
$(USER_DIR)/$(1).elf: $$(wildcard $(USER_DIR)/$(1)/*.swift) $$(ALL_USER_MODS) $$(USER_STUBS_OBJ) $$(USER_LIB_OBJS)
	@echo "Compilazione Userland ELF (dir): $$@"
	$$(SWIFTC) $$(SWIFT_FLAGS) -I $$(USER_MOD_DIR) -c $$(wildcard $(USER_DIR)/$(1)/*.swift) -o $$(@:.elf=.o)
	$$(LD) -T user.ld -o $$@ $$(@:.elf=.o) $$(USER_STUBS_OBJ) $$(USER_LIB_OBJS) $$(ALL_USER_OBJS)
	rm $$(@:.elf=.o)
endef
$(foreach app,$(USER_APP_DIRS),$(eval $(call USER_DIR_APP_RULE,$(app))))

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
