# --- Percorsi Strumenti ---
LLVM_BIN    = /opt/homebrew/opt/llvm/bin
LLD_BIN     = /opt/homebrew/opt/lld@20/bin

CLANG       = $(LLVM_BIN)/clang
LD          = $(LLD_BIN)/ld.lld
OBJCOPY     = $(LLVM_BIN)/llvm-objcopy
SWIFTC      = /Users/eliorodr2104/.swiftly/bin/swiftc

# --- Configurazioni Target ---
TARGET      = aarch64-none-none-elf
KERNEL_ADDR = 0x40080000

# --- Flag ---
C_FLAGS     = -target $(TARGET) -ffreestanding -O2 -nostdlib -fno-stack-protector -ISources/Support/LibFDT
# Usiamo lo stesso target ELF per Swift per garantire compatibilità
SWIFT_FLAGS = -target $(TARGET) \
              -enable-experimental-feature Embedded \
              -enable-experimental-feature Extern \
              -Xcc -ffreestanding \
              -wmo -Osize \
              -parse-as-library

LD_FLAGS    = -T linker.ld --nmagic --build-id=none

# --- Sorgenti ---
SWIFT_SOURCES := $(shell find Sources -name "*.swift")
C_SOURCES     := $(shell find Sources -name "*.c")
ASM_SOURCES   := $(shell find Sources -name "*.S")

# Trasformiamo i nomi dei file sorgente in nomi di file oggetto
C_OBJS   := $(C_SOURCES:.c=.o)
ASM_OBJS := $(ASM_SOURCES:.S=.o)
# Swift lo compiliamo in un unico blocco per l'Embedded mode
SWIFT_OBJ := swift_kernel.o

.PHONY: all clean run

all: kernel.bin

# Regola per i file Assembly
%.o: %.S
	$(CLANG) -target $(TARGET) -c $< -o $@

# Regola per i file C
%.o: %.c
	$(CLANG) $(C_FLAGS) -c $< -o $@

# Regola speciale per Swift (Embedded Swift lavora meglio con WMO)
$(SWIFT_OBJ): $(SWIFT_SOURCES)
	$(SWIFTC) $(SWIFT_FLAGS) -c $(SWIFT_SOURCES) -o $@

# Linking finale
kernel.elf: $(ASM_OBJS) $(C_OBJS) $(SWIFT_OBJ)
	$(LD) $(LD_FLAGS) -o $@ $^

kernel.bin: kernel.elf
	$(OBJCOPY) -O binary $< $@

clean:
	rm -f kernel.elf kernel.bin $(SWIFT_OBJ)
	find Sources -name "*.o" -delete

run: kernel.bin
	qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a53 \
    -nographic \
    -d int \
    -kernel kernel.bin
