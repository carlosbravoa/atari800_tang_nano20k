-- SDRAM statemachine stub for Stage 1 synthesis feasibility.
-- The original rtl/common/components/sdram_statemachine.vhdl targets a
-- 16-bit external ISSI SDRAM and has hardcoded geometry that conflicts with
-- the GW2AR-18 embedded 32-bit SDRAM.  Stage 2 replaces this block entirely
-- with a proper GW2AR-18 controller; for now we just acknowledge every
-- request immediately so synthesis can proceed.

library ieee;
use ieee.std_logic_1164.all;

entity sdram_statemachine is
    generic (
        ADDRESS_WIDTH  : natural := 22;
        ROW_WIDTH      : natural := 12;
        AP_BIT         : natural := 10;
        COLUMN_WIDTH   : natural := 8
    );
    port (
        CLK_SYSTEM      : in    std_logic;
        CLK_SDRAM       : in    std_logic;
        RESET_N         : in    std_logic;
        DATA_IN         : in    std_logic_vector(31 downto 0);
        ADDRESS_IN      : in    std_logic_vector(ADDRESS_WIDTH downto 0);
        READ_EN         : in    std_logic;
        WRITE_EN        : in    std_logic;
        REQUEST         : in    std_logic;
        BYTE_ACCESS     : in    std_logic;
        WORD_ACCESS     : in    std_logic;
        LONGWORD_ACCESS : in    std_logic;
        REFRESH         : in    std_logic;
        COMPLETE        : out   std_logic;
        DATA_OUT        : out   std_logic_vector(31 downto 0);
        SDRAM_ADDR      : out   std_logic_vector(ROW_WIDTH-1 downto 0);
        SDRAM_DQ        : inout std_logic_vector(15 downto 0);
        SDRAM_BA0       : out   std_logic;
        SDRAM_BA1       : out   std_logic;
        SDRAM_CKE       : out   std_logic;
        SDRAM_CS_N      : out   std_logic;
        SDRAM_RAS_N     : out   std_logic;
        SDRAM_CAS_N     : out   std_logic;
        SDRAM_WE_N      : out   std_logic;
        SDRAM_ldqm      : out   std_logic;
        SDRAM_udqm      : out   std_logic;
        reset_client_n  : out   std_logic
    );
end sdram_statemachine;

architecture stub of sdram_statemachine is
begin
    -- Acknowledge every request in the same cycle; return zeros on reads.
    COMPLETE        <= REQUEST;
    DATA_OUT        <= (others => '0');

    -- Keep SDRAM pins deselected (CS_N=1, CKE=0).
    SDRAM_CKE       <= '0';
    SDRAM_CS_N      <= '1';
    SDRAM_RAS_N     <= '1';
    SDRAM_CAS_N     <= '1';
    SDRAM_WE_N      <= '1';
    SDRAM_ADDR      <= (others => '0');
    SDRAM_DQ        <= (others => 'Z');
    SDRAM_BA0       <= '0';
    SDRAM_BA1       <= '0';
    SDRAM_ldqm      <= '1';
    SDRAM_udqm      <= '1';
    reset_client_n  <= RESET_N;
end stub;
