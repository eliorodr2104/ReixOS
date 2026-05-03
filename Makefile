# --- Percorsi e Strumenti ---
LLVM_BIN    = /opt/homebrew/opt/llvm/bin
LLD_BIN     = /opt/homebrew/opt/lld@20/bin
CLANG       = $(LLVM_BIN)/clang
LD          = $(LLD_BIN)/ld.lld
OBJCOPY     = $(LLVM_BIN)/llvm-objcopy
SWIFTC      = /Users/eliorodr2104/.swiftly/bin/swiftc

TARGET      = aarch64-none-none-elf
USER_DIR    = Sources/Userland

USER_STUBS_SRC := $(USER_DIR)/user_stubs.c
USER_STUBS_OBJ := $(USER_DIR)/user_stubs.o

# --- Flag ---
C_FLAGS     = -target $(TARGET) -ffreestanding -O2 -nostdlib -fno-stack-protector -ISources/ReixKernel/Platform/DeviceTree -g
SWIFT_FLAGS = -target $(TARGET) -enable-experimental-feature Embedded -enable-experimental-feature Extern -I ./Sources/ReixKernel/Platform/ElfParser -wmo -Osize -parse-as-library -g

# --- Sorgenti Kernel (Escludiamo Userland) ---
SWIFT_SOURCES := $(shell find Sources -name "*.swift" -not -path "$(USER_DIR)/*")
C_SOURCES     := $(shell find Sources -name "*.c" -not -path "$(USER_DIR)/*")
ASM_SOURCES   := $(shell find Sources -name "*.S" -not -path "$(USER_DIR)/*")

C_OBJS   := $(C_SOURCES:.c=.o)
ASM_OBJS := $(ASM_SOURCES:.S=.o)
SWIFT_OBJ := swift_kernel.o

# --- Sorgenti Userland (Ogni file un ELF) ---
USER_SRCS  := $(wildcard $(USER_DIR)/*.swift)
USER_ELFS  := $(patsubst $(USER_DIR)/%.swift, $(USER_DIR)/%.elf, $(USER_SRCS))

.PHONY: all clean run userland

all: initrd.tar kernel.bin

# --- Compilazione Userland ---
# Compiliamo ogni .swift in Userland come un ELF indipendente
$(USER_STUBS_OBJ): $(USER_STUBS_SRC)
	$(CLANG) $(C_FLAGS) -c $< -o $@

$(USER_DIR)/%.elf: $(USER_DIR)/%.swift $(USER_STUBS_OBJ)
	$(SWIFTC) $(SWIFT_FLAGS) -c $< -o $(@:.elf=.o)
	$(LD) -T user.ld -o $@ $(@:.elf=.o) $(USER_STUBS_OBJ)
	rm $(@:.elf=.o)

userland: $(USER_ELFS)

# --- Creazione Initrd ---
initrd.tar: $(USER_ELFS)
	tar -cf $@ -C $(USER_DIR) $(notdir $(USER_ELFS))

# --- Compilazione Kernel ---
%.o: %.S
	$(CLANG) -target $(TARGET) -c $< -o $@

%.o: %.c
	$(CLANG) $(C_FLAGS) -c $< -o $@

$(SWIFT_OBJ): $(SWIFT_SOURCES)
	$(SWIFTC) $(SWIFT_FLAGS) -c $(SWIFT_SOURCES) -o $@

kernel.elf: $(ASM_OBJS) $(C_OBJS) $(SWIFT_OBJ)
	$(LD) -T linker.ld --nmagic -o $@ $^

kernel.bin: kernel.elf
	$(OBJCOPY) -O binary $< $@

clean:
	rm -f kernel.elf kernel.bin initrd.tar $(SWIFT_OBJ)
	find Sources -name "*.o" -delete
	find Sources -name "*.elf" -delete

run: all
	qemu-system-aarch64 \
    -machine virt,gic-version=2 \
    -cpu cortex-a53 \
    -nographic \
    -kernel kernel.bin \
    -initrd ./initrd.tar
