# --- Percorsi e Strumenti ---
LLVM_BIN    = /opt/homebrew/opt/llvm/bin
LLD_BIN     = /opt/homebrew/opt/lld@20/bin
CLANG       = $(LLVM_BIN)/clang
LD          = $(LLD_BIN)/ld.lld
OBJCOPY     = $(LLVM_BIN)/llvm-objcopy
SWIFTC      = /Users/eliorodr2104/.swiftly/bin/swiftc

TARGET      = aarch64-none-none-elf
USER_DIR    = Sources/Userland

# --- Directory Syscall (Tua struttura) ---
SYSCALL_DIR      = Sources/ReixKernel/Syscall
SYSCALL_ARCH_DIR = Sources/ReixKernel/Arch/aarch64/Syscall

# --- Flag ---
C_FLAGS     = -target $(TARGET) -ffreestanding -O2 -nostdlib -fno-stack-protector -ISources/ReixKernel/Platform/DeviceTree -g
SWIFT_FLAGS = -target $(TARGET) -enable-experimental-feature Embedded -enable-experimental-feature Extern -I ./Sources/ReixKernel/Platform/ElfParser -wmo -Osize -parse-as-library -g

# --- Individuazione Dinamica Sorgenti Kernel ---
# Escludiamo solo la Userland per il binario del Kernel
KERNEL_SWIFT_SRCS := $(shell find Sources -name "*.swift" -not -path "$(USER_DIR)/*")
KERNEL_C_SRCS     := $(shell find Sources -name "*.c" -not -path "$(USER_DIR)/*")
KERNEL_ASM_SRCS   := $(shell find Sources -name "*.S" -not -path "$(USER_DIR)/*")

KERNEL_OBJS := $(KERNEL_C_SRCS:.c=.o) $(KERNEL_ASM_SRCS:.S=.o)
SWIFT_KERNEL_OBJ := swift_kernel.o

# --- Individuazione Dinamica Sorgenti per Userland (Libreria di Sistema) ---
# Tutti i file .swift in Syscall e Syscall/Arch (esposti all'utente)
USER_LIB_SWIFT := $(wildcard $(SYSCALL_DIR)/*.swift) $(wildcard $(SYSCALL_ARCH_DIR)/*.swift)
# Tutti i file .S in Syscall/Arch (gli stub ASM con SVC)
USER_LIB_ASM   := $(wildcard $(SYSCALL_ARCH_DIR)/*.S)
USER_LIB_OBJS  := $(USER_LIB_ASM:.S=.o)

# Sorgenti delle App Userland (ogni .swift diventa un ELF)
USER_APPS_SRCS := $(wildcard $(USER_DIR)/*.swift)
USER_APPS_ELFS := $(patsubst $(USER_DIR)/%.swift, $(USER_DIR)/%.elf, $(USER_APPS_SRCS))
USER_STUBS_OBJ := $(USER_DIR)/user_stubs.o

# --- Regole Principali ---
.PHONY: all clean run userland

all: initrd.tar kernel.bin

# --- Compilazione Kernel ---
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

# --- Compilazione Userland (Dinamica) ---

# Compiliamo lo stub C della Userland
$(USER_STUBS_OBJ): $(USER_DIR)/user_stubs.c
	$(CLANG) $(C_FLAGS) -c $< -o $@

# Regola generica per ogni ELF in Userland
# Ogni app viene compilata insieme a TUTTI i file Swift di sistema e linkata agli oggetti ASM
$(USER_DIR)/%.elf: $(USER_DIR)/%.swift $(USER_STUBS_OBJ) $(USER_LIB_OBJS)
	@echo "Compilazione Userland ELF: $@"
	# Compila l'app + i file Swift della libreria Syscall
	$(SWIFTC) $(SWIFT_FLAGS) -c $< $(USER_LIB_SWIFT) -o $(@:.elf=.o)
	# Linka l'oggetto ottenuto con gli stub C e gli oggetti ASM (SVC)
	$(LD) -T user.ld -o $@ $(@:.elf=.o) $(USER_STUBS_OBJ) $(USER_LIB_OBJS)
	rm $(@:.elf=.o)

userland: $(USER_APPS_ELFS)

# --- Initrd ---
initrd.tar: $(USER_APPS_ELFS)
	tar -cf $@ -C $(USER_DIR) $(notdir $(USER_APPS_ELFS))

# --- Utility ---
clean:
	rm -f kernel.elf kernel.bin initrd.tar $(SWIFT_KERNEL_OBJ)
	find Sources -name "*.o" -delete
	find Sources -name "*.elf" -delete

run: all
	qemu-system-aarch64 \
    -machine virt,gic-version=2 \
    -cpu cortex-a53 \
    -nographic \
    -kernel kernel.bin \
    -initrd ./initrd.tar
