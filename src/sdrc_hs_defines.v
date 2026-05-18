// SDRC_HS IP configuration macros for GW2AR-18C embedded SDRAM
// 64 Mbit (8 MB): 32-bit × 2 M words, 4 banks, 2048 rows, 256 columns
// System clock: 27 MHz → 1 cycle ≈ 37 ns

`define SDRAM_DATA_WIDTH       32   // data bus width
`define SDRAM_BANK_WIDTH        2   // number of bank address bits
`define SDRAM_ADDR_ROW_WIDTH   13   // physical row address bus (A[12:0])
`define SDRAM_ADDR_COLUMN_WIDTH 8   // column address bits A[7:0]

// Timing parameters (clock cycles at 27 MHz).
// Macro names must match what sdrc_hs_top.vp expects (SDRAM_ prefix).
`define SDRAM_CL   2   // CAS latency
`define SDRAM_tRP  2   // precharge period    (≥37.5 ns → 2 cycles)
`define SDRAM_tRFC 7   // auto-refresh period (≥63 ns   → 7 cycles for margin)
`define SDRAM_tWR  2   // write recovery time
`define SDRAM_tRCD 2   // active to read/write (≥37.5 ns → 2 cycles)
`define SDRAM_tMRD 2   // mode-register-set delay
