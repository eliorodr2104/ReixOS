#
#  Makefile
#  ReixOS
#
#  Created by Eliomar Alejandro Rodriguez Ferrer on 19/04/2026.
#

# --- Percorsi Strumenti ---
LLVM_BIN    = /opt/homebrew/opt/llvm/bin
LLD_BIN     = /opt/homebrew/opt/lld@20/bin

CLANG       = $(LLVM_BIN)/clang
LD          = $(LLD_BIN)/ld.lld
OBJCOPY     = $(LLVM_BIN)/llvm-objcopy

# Punta direttamente al binario gestito da swiftly
SWIFTC      = /Users/eliorodr2104/.swiftly/bin/swiftc

# --- Configurazioni Target ---
# Per il C e l'Assembly usiamo il target ELF standard
C_TARGET     = aarch64-unknown-none-elf
# Per Swift usiamo il target bare-metal di Apple per "sbloccare" la StdLib embedded
SWIFT_TARGET = aarch64-none-none-elf

KERNEL_ADDR = 0x40080000

# --- Flag di Compilazione ---
C_FLAGS = -target $(C_TARGET) -ffreestanding -O2 -nostdlib -fno-stack-protector \
          -ISources/Support/LibFDT

# Flag Swift: Fondamentale l'uso del target Mach-O bare-metal
SWIFT_FLAGS = -target $(SWIFT_TARGET) \
              -enable-experimental-feature Embedded \
              -enable-experimental-feature Extern \
              -Xcc -ffreestanding \
              -wmo -Osize \
              -parse-as-library

LD_FLAGS = -T linker.ld --nmagic --build-id=none

# --- Sorgenti ---
SWIFT_SOURCES := $(shell find Sources -name "*.swift")
C_SOURCES     := $(shell find Sources -name "*.c")
ASM_SOURCES   := Sources/Boot/boot.S Sources/Arch/aarch64/mem.S

C_OBJS        := $(C_SOURCES:.c=.o)
ASM_OBJS      := boot.o mem.o

.PHONY: all build clean run

all: build

build: clean
	@echo "--- Compiling Assembly ---"
	$(CLANG) -target $(C_TARGET) -c Sources/Boot/boot.S -o boot.o
	$(CLANG) -target $(C_TARGET) -c Sources/Arch/aarch64/mem.S -o mem.o

	@echo "--- Compiling C Files ---"
	$(foreach file, $(C_SOURCES), $(CLANG) $(C_FLAGS) -c $(file) -o $(file:.c=.o);)

	@echo "--- Compiling Swift (Embedded) ---"
	# Nota: Generiamo il file oggetto main.o
	$(SWIFTC) $(SWIFT_FLAGS) -c $(SWIFT_SOURCES) -o main.o

	@echo "--- Linking ---"
	# ld.lld è intelligente: unisce oggetti ELF (C/ASM) e Mach-O (Swift) convertendoli
	$(LD) $(LD_FLAGS) -o kernel.elf $(ASM_OBJS) main.o $(C_OBJS)
	
	$(OBJCOPY) -O binary kernel.elf kernel.bin
	@echo "--- Build Complete ---"

clean:
	rm -f *.o kernel.elf kernel.bin
	find Sources -name "*.o" -delete

run: build
	qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a53 \
    -nographic \
    -d int \
    -kernel kernel.bin
