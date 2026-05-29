# Atari SIO Disk Emulation and Mounting Pipeline

This document provides a highly technical, end-to-end trace of how ATR floppy disk image mounting and SIO (Serial Input/Output) sector read/write emulation are implemented on the **Tang Nano 20K FPGA** platform running the Atari 800 core.

---

## 1. System Architecture Overview

The disk mounting system operates as a hybrid hardware/software subsystem. The PicoRV32 RISC-V softcore acts as an intelligent peripheral controller (equivalent to a smart floppy drive), managing the SD card filesystem and serial SIO protocol parsing, while a hardware serializer/deserializer bridge (`sio_handler.vhdl`) links it to the Atari's virtual serial port.

```mermaid
graph TD
    %% Hardware layer
    subgraph SD_HW [SD Card Hardware Layer]
        SD_Card[SD Card] -->|SPI Mode Pins| SPI_Pins[sd_clk, sd_cmd, sd_dat0, sd_cs]
        SPI_Pins --> SPI_Ctrl[simplespimaster IP]
    end

    %% Software layer
    subgraph PicoRV_SW [PicoRV32 Software Domain: firmware.c]
        SPI_Ctrl -->|SPI Send/Recv Registers| SPI_Driver[spi_sd.c Driver]
        SPI_Driver --> FatFs[FatFs Directory & File API]
        FatFs --> ATR_Mount[mount_atr()]
        ATR_Mount --> Sector_IO[atr_read_sector / atr_write_sector]
    end

    %% SIO Hardware bridge
    subgraph SIO_Bridge [SIO Hardware Bridge: sio_handler.vhdl]
        PicoRV_SW -->|Register Map 0x0200_0080| SIO_Regs[SIO Register Interface]
        SIO_Regs --> Tx_FIFO[fifo_transmit: TX FIFO]
        SIO_Regs --> Rx_FIFO[fifo_receive: RX FIFO]
        
        %% Serialization
        Tx_FIFO --> P2S[Parallel to Serial State Machine]
        P2S -->|sio_data_in| SIO_DATA_IN_Pin[Atari Core SIO RX]
        
        %% Deserialization
        SIO_DATA_OUT_Pin[Atari Core SIO TX] -->|sio_data_out| S2P[Serial to Parallel State Machine]
        SIO_COMMAND_Pin[Atari Core SIO Command] -->|sio_command| S2P
        S2P --> Rx_FIFO
    end

    %% Atari Core
    subgraph AtariCore [Atari 800 Core]
        SIO_DATA_IN_Pin --> Pokey[POKEY Serial UART]
        Pokey --> SIO_DATA_OUT_Pin
        PIA[PIA Chip / Address Decoder] --> SIO_COMMAND_Pin
    end
```

---

## 2. SD Card Hardware and SPI Driver

The SD card is interfaced in **SPI mode**, which allows simple byte-oriented reads and writes through four lines: SCK (`sd_clk`), MOSI (`sd_cmd`), MISO (`sd_dat0`), and CS (`sd_dat3`).

### 2.1 SPI Hardware Master (`simplespimaster.sv`)
- Instantiated in [iosys_picorv32.v](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/src/iosys_picorv32.v).
- Exposes two memory-mapped registers to the PicoRV32:
  - `reg_spimaster_byte` (`0x0200_0020`): Triggers an 8-bit shift operation.
  - `reg_spimaster_word` (`0x0200_0024`): Triggers a 32-bit shift operation (for faster 4-byte aligned block reads).

### 2.2 SPI SD Card Driver (`spi_sd.c`)
The driver in [spi_sd.c](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/spi_sd.c) implements standard SD/MMC commands:
- **Initialization**: Resets the card using `CMD0` (GO_IDLE_STATE) with Chip Select low, queries card operating voltage with `CMD8` (SEND_IF_COND), sets host support configuration using `ACMD41`, and reads the Operation Conditions Register with `CMD58` to determine if the card is Standard Capacity (SDSC) or High Capacity (SDHC).
- **Block Read (`CMD17`)**: Fetches a 512-byte physical sector from the card.
- **Block Write (`CMD24`)**: Writes a 512-byte physical sector, waiting for the data token response (`0x05`) to confirm writing completion.

---

## 3. Filesystem and ATR Image Mounting

The **FatFs** library abstracts the FAT16/FAT32 structures on the SD card into file interfaces.

### 3.1 ATR File Structure
An ATR file represents a raw sector-by-sector copy of an Atari floppy disk prepended with a 16-byte header:
1. **Magic Number**: Bytes `0–1` are always `0x0296` in little-endian.
2. **Sector Size**: Bytes `4–5` specify the size of a floppy sector. Common values are `128` (Single Density or Medium Density) or `256` (Double Density).
3. **Data Area**: Follows immediately after the 16-byte header.

### 3.2 Mounting Algorithm (`mount_atr`)
Implemented in [firmware.c](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/firmware/firmware.c):
1. Closes any previously mounted ATR file.
2. Opens the file target using FatFs `f_open` (defaults to Read/Write, falls back to Read-Only if the SD card write-protect tab is active or file lock fails).
3. Reads the 16-byte header.
4. Verifies the magic signature `0x0296`.
5. Extracts and stores `atr_sector_size` (128 or 256), setting `atr_mounted = true`.

### 3.3 Sector Offset Translation (`atr_read_sector` / `atr_write_sector`)
Atari disk controllers maintain a hardware quirk: **sectors 1, 2, and 3 are always 128 bytes**, even on double-density disks (256 bytes per sector). This preserves compatibility with the standard OS ROM bootloader. The sector translation logic must account for this offset discrepancy:

- **If `atr_sector_size` is 128 bytes**:
  $$\text{Offset} = 16 + (\text{Sector} - 1) \times 128$$
- **If `atr_sector_size` is 256 bytes**:
  - For $\text{Sector} \le 3$:
    $$\text{Offset} = 16 + (\text{Sector} - 1) \times 128$$
  - For $\text{Sector} \ge 4$:
    $$\text{Offset} = 16 + (3 \times 128) + (\text{Sector} - 4) \times 256 = 400 + (\text{Sector} - 4) \times 256$$

The file pointer is moved via `f_lseek` to the computed offset, and the sector data is read/written via `f_read` / `f_write`.

---

## 4. Hardware SIO Capture and Serialization

The Atari core communicates with external drives using the SIO protocol: asynchronous serial frame transfer operating at 19200 bps (standard) or up to 125000 bps (turbo modes). The bridge [sio_handler.vhdl](file:///home/carlos/devel/fpga/atari800_tang_nano20k_parallel/rtl/common/sioemu/sio_handler.vhdl) handles the hardware timing.

### 4.1 Deserializer: Atari Core $\rightarrow$ RX FIFO
1. **SIO Lines**:
   - `SIO_DATA_OUT`: Serial output from the computer (Atari TX line).
   - `SIO_COMMAND`: Active-low command frame indicator (controlled by the computer).
2. **Serial-to-Parallel (S2P)**:
   - Evaluates serial bits on the falling edge of `sio_clk_out` (when the computer clocks the bus) or samples using divisor counters under `POKEY_ENABLE`.
   - Starts when `SIO_DATA_OUT` drops to `0` (Start Bit).
   - Shifts in 8 data bits LSB-first into the shift register `s2p_shift_reg`.
   - Verifies the stop bit (`sio_data_out_reg = '1'`) and sets a framing error on failure.
3. **Command Index Tracking**:
   - When `SIO_COMMAND` is asserted low, SIO packets represent 5-byte command frames (Device ID, Command Byte, Aux 1, Aux 2, Checksum).
   - The hardware counts these incoming command bytes: `sio_command_count_reg` increments from 1 to 5.
4. **RX FIFO Storage**:
   - When a byte is successfully received, the deserializer writes a 15-bit word to `fifo_receive`:
     - Bits `14:8`: `sio_command_count_reg` (metadata: 1..5 for command frame bytes, 0 for standard data).
     - Bits `7:0`: The received byte.

### 4.2 Serializer: TX FIFO $\rightarrow$ Atari Core
1. **Parallel-to-Serial (P2S)**:
   - Checks if `fifo_transmit` is not empty.
   - Grabs the byte and outputs a Start Bit (`0`) on `SIO_DATA_IN` (Atari RX line).
   - Shifts out the 8 data bits at the baud rate controlled by `divisor_reg`.
   - Outputs a Stop Bit (`1`) and returns to the wait state.

---

## 5. Firmware SIO Polling and Command Loop

The PicoRV32 MCU monitors and services the SIO subsystem through memory-mapped SIO registers located in the peripheral address space:
- `reg_sio_rx` (`0x0200_0088`): Returns the current 15-bit word from the RX FIFO. Reading advances the FIFO.
- `reg_sio_rx_stat` (`0x0200_008C`): Returns RX FIFO status flags (bit 8 is `empty`).
- `reg_sio_tx` (`0x0200_0080`): Writes a byte to the TX FIFO.
- `reg_sio_tx_stat` (`0x0200_0084`): Returns TX FIFO status flags (bit 9 is `full`).

### 5.1 SIO Command Capture Loop (`sio_poll`)
1. The firmware loop calls `sio_poll` continuously.
2. It checks if `reg_sio_rx_stat` reports new data available.
3. If `cmd_count` (bits 14:8 of `reg_sio_rx`) is non-zero, it indicates a command packet byte:
   - `cmd_count == 1`: Marks the start of a command frame. The firmware stores the byte at index 0 of `sio_cmd_buf` and records the start timestamp `sio_cmd_timeout`.
   - `cmd_count == 2..5`: Appends the byte to the buffer.
4. If a partial frame sits in the buffer for more than 200 ms without completing, the index is reset to recover from line glitches.
5. When index reaches 5, `sio_process_command()` is called.

```
SIO Command Frame Structure:
+-----------------+-----------------+-----------------+-----------------+-----------------+
|   Device ID     |  Command Byte   |      Aux 1      |      Aux 2      |    Checksum     |
|     (0x31)      |  (0x52 / 0x53)  |   (Sector LSB)  |   (Sector MSB)  |   (Sum & 0xFF)  |
+-----------------+-----------------+-----------------+-----------------+-----------------+
```

---

## 6. SIO Command Processing

Once a 5-byte command is buffered, the firmware verifies the checksum:
$$\text{Calculated Checksum} = (\text{Device} + \text{Command} + \text{Aux 1} + \text{Aux 2}) \ \& \ \text{0xFF}$$
If valid, and the Device ID is `0x31` (representing virtual drive `D1:`), the firmware decodes the command byte:

### 6.1 Status Command (`0x53`)
Atari requests drive status to detect density and online status:
1. Transmits `0x41` (ASCII 'A' - ACK) back to the Atari core.
2. Forms a 4-byte status block:
   - `byte 0`: Mount flag (`0x08`) ORed with Double Density flag (`0x04`) if `atr_sector_size == 256`.
   - `byte 1`: Hardware status (`0xFF`).
   - `byte 2`: Timeout parameter (`0xE0`).
   - `byte 3`: Reserved (`0x00`).
3. Delays 1 ms, then transmits `0x43` (ASCII 'C' - Complete).
4. Transmits the 4 status bytes followed by their cumulative checksum.

### 6.2 Read Sector Command (`0x52`)
Atari requests a sector payload:
1. Calls `atr_read_sector(sector, sector_buf, &sector_len)`.
2. If successful, transmits `0x41` (ACK).
3. Calculates the checksum of the sector buffer.
4. Delays 1 ms, then transmits `0x43` (Complete).
5. Transmits the sector bytes (128 or 256 bytes depending on sector number and disk density) through the TX FIFO.
6. Transmits the calculated checksum.
7. If reading fails, transmits `0x4E` (ASCII 'N' - NAK).

### 6.3 Write Sector Commands (`0x50` / `0x57`)
Atari writes a sector payload:
1. Transmits `0x41` (ACK) to indicate the drive is ready to receive data.
2. Receives the data frame (128 or 256 bytes) plus checksum from the computer using `sio_rx_data_frame()`.
3. Verifies the incoming frame checksum.
4. Calls `atr_write_sector(sector, sector_buf, sector_len)`.
5. If successful, transmits `0x41` (ACK for the data frame), delays 1 ms, and transmits `0x43` (Complete).
6. On failure at any point, transmits `0x4E` (NAK).
