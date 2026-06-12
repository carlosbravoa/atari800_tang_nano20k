#
# The xPack GNU RISC-V Embedded GCC
# https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack
#
TARGET_ELF = firmware.elf
TARGET_BIN = firmware.bin
RISCV = riscv64-unknown-elf
CC = $(RISCV)-gcc
OBJCOPY = $(RISCV)-objcopy
OBJDUMP = $(RISCV)-objdump
CFLAGS  = -Wall -Os -g -ffunction-sections -fdata-sections -mabi=ilp32 -march=rv32i -ffreestanding -I.
LFLAGS = -mabi=ilp32 -march=rv32i -Wl,--build-id=none,-Bstatic,-T,baremetal.ld,--gc-sections -nostdlib
LIBS = -lgcc

SRCS := start.S firmware.c picorv32.c spi_sd.c spiflash.c \
	fatfs/diskio.c fatfs/ff.c
OBJS := $(SRCS:.c=.o)
OBJS := $(OBJS:.S=.o)
HDRS := $(wildcard *.h)

ifeq ($(VERBOSE),1)
  Q =
else
  Q = @
endif

# BSRAM boot-RAM depth in 32-bit words (48 KB = 12288 words = 24 BSRAM blocks).
BRAM_DEPTH = 12288
BRAM_DIR   = ../src
BRAM_HEX   = $(BRAM_DIR)/fw_lane0.hex

default: $(TARGET_BIN) $(BRAM_HEX)
all: default

%.o: %.c $(HDRS)
ifneq ($(VERBOSE),1)
	@echo CC $@
endif
	$(Q)$(CC) $(CFLAGS) -c $< -o $@

%.o: %.S $(HDRS)
ifneq ($(VERBOSE),1)
	@echo CC $@
endif
	$(Q)$(CC) $(CFLAGS) -c $< -o $@

.PRECIOUS: $(TARGET_BIN) $(TARGET_ELF) $(OBJS)

$(TARGET_ELF): $(OBJS)
ifneq ($(VERBOSE),1)
	@echo CC $@
endif
	$(Q)$(CC) $(LFLAGS) $(OBJS) $(LIBS) -o $@

$(TARGET_BIN): $(TARGET_ELF)
ifneq ($(VERBOSE),1)
	@echo OBJCOPY $@
endif
	$(Q)$(OBJCOPY) $(TARGET_ELF) $(TARGET_BIN) -O binary
	$(Q)$(OBJDUMP) -d $(TARGET_ELF) > disasm.txt

# Generate BSRAM init hex (4 byte lanes + word-wide) from the firmware binary.
$(BRAM_HEX): $(TARGET_BIN) bin2bram.py
ifneq ($(VERBOSE),1)
	@echo BIN2BRAM "->" $(BRAM_DIR)/fw_lane{0..3}.hex
endif
	$(Q)python3 bin2bram.py $(TARGET_BIN) $(BRAM_DIR) $(BRAM_DEPTH)

clean:
	$(Q)rm -f $(OBJS) $(TARGET_ELF) $(TARGET_BIN) \
		$(BRAM_DIR)/fw_lane0.hex $(BRAM_DIR)/fw_lane1.hex \
		$(BRAM_DIR)/fw_lane2.hex $(BRAM_DIR)/fw_lane3.hex $(BRAM_DIR)/fw_words.hex

.PHONY: default all clean
