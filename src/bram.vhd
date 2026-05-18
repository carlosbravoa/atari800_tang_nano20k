-- Portable block-RAM inference replacing the Altera altsyncram version.
-- Works with Gowin GowinSynthesis and any IEEE-1993 compliant synthesiser.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

----------------------------------------------------------------------
-- spram_sz: single-port RAM (base implementation)
----------------------------------------------------------------------
entity spram_sz is
    generic (
        addr_width    : integer := 8;
        data_width    : integer := 8;
        numwords      : integer := 256;
        mem_init_file : string  := " ";
        mem_depth     : integer := 8192;
        mem_name      : string  := "MEM"
    );
    port (
        clock   : in  std_logic;
        address : in  std_logic_vector(addr_width-1 downto 0);
        data    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
        enable  : in  std_logic := '1';
        wren    : in  std_logic := '0';
        q       : out std_logic_vector(data_width-1 downto 0);
        cs      : in  std_logic := '1'
    );
end entity;

architecture rtl of spram_sz is
    type ram_t is array(0 to numwords-1) of std_logic_vector(data_width-1 downto 0);
    signal ram  : ram_t;
    signal dout : std_logic_vector(data_width-1 downto 0);
begin
    process(clock)
    begin
        if rising_edge(clock) then
            if enable = '1' then
                if wren = '1' and cs = '1' then
                    ram(to_integer(unsigned(address))) <= data;
                end if;
                dout <= ram(to_integer(unsigned(address)));
            end if;
        end if;
    end process;
    q <= dout when cs = '1' else (others => '1');
end rtl;

----------------------------------------------------------------------
-- spram: single-port RAM wrapper
----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity spram is
    generic (
        addr_width    : integer := 8;
        data_width    : integer := 8;
        mem_init_file : string  := " ";
        mem_depth     : integer := 8192;
        mem_name      : string  := "MEM"
    );
    port (
        clock   : in  std_logic;
        address : in  std_logic_vector(addr_width-1 downto 0);
        data    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
        enable  : in  std_logic := '1';
        wren    : in  std_logic := '0';
        q       : out std_logic_vector(data_width-1 downto 0);
        cs      : in  std_logic := '1'
    );
end entity;

architecture rtl of spram is
begin
    u0 : entity work.spram_sz
        generic map(addr_width, data_width, 2**addr_width, mem_init_file, mem_depth, mem_name)
        port map(clock, address, data, enable, wren, q, cs);
end rtl;

----------------------------------------------------------------------
-- dpram_dif: true dual-port RAM with independent port widths
----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram_dif is
    generic (
        addr_width_a  : integer := 8;
        data_width_a  : integer := 8;
        addr_width_b  : integer := 8;
        data_width_b  : integer := 8;
        mem_init_file : string  := " "
    );
    port (
        clock     : in  std_logic;

        address_a : in  std_logic_vector(addr_width_a-1 downto 0);
        data_a    : in  std_logic_vector(data_width_a-1 downto 0) := (others => '0');
        enable_a  : in  std_logic := '1';
        wren_a    : in  std_logic := '0';
        q_a       : out std_logic_vector(data_width_a-1 downto 0);
        cs_a      : in  std_logic := '1';

        address_b : in  std_logic_vector(addr_width_b-1 downto 0) := (others => '0');
        data_b    : in  std_logic_vector(data_width_b-1 downto 0) := (others => '0');
        enable_b  : in  std_logic := '1';
        wren_b    : in  std_logic := '0';
        q_b       : out std_logic_vector(data_width_b-1 downto 0);
        cs_b      : in  std_logic := '1'
    );
end entity;

architecture rtl of dpram_dif is
    -- Shared memory sized to the larger port
    constant MEM_WORDS : integer := 2**addr_width_a;
    type ram_t is array(0 to MEM_WORDS-1) of std_logic_vector(data_width_a-1 downto 0);
    signal ram  : ram_t;
    signal qa   : std_logic_vector(data_width_a-1 downto 0);
    signal qb   : std_logic_vector(data_width_b-1 downto 0);
begin
    process(clock)
    begin
        if rising_edge(clock) then
            if enable_a = '1' then
                if wren_a = '1' and cs_a = '1' then
                    ram(to_integer(unsigned(address_a))) <= data_a;
                end if;
                qa <= ram(to_integer(unsigned(address_a)));
            end if;
            if enable_b = '1' then
                if wren_b = '1' and cs_b = '1' then
                    ram(to_integer(unsigned(address_b(addr_width_a-1 downto 0)))) <=
                        data_b(data_width_a-1 downto 0);
                end if;
                qb <= ram(to_integer(unsigned(address_b(addr_width_a-1 downto 0))))(data_width_b-1 downto 0);
            end if;
        end if;
    end process;
    q_a <= qa when cs_a = '1' else (others => '1');
    q_b <= qb when cs_b = '1' else (others => '1');
end rtl;

----------------------------------------------------------------------
-- dpram: dual-port RAM with same parameters on both ports
----------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity dpram is
    generic (
        addr_width    : integer := 8;
        data_width    : integer := 8;
        mem_init_file : string  := " "
    );
    port (
        clock     : in  std_logic;

        address_a : in  std_logic_vector(addr_width-1 downto 0);
        data_a    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
        enable_a  : in  std_logic := '1';
        wren_a    : in  std_logic := '0';
        q_a       : out std_logic_vector(data_width-1 downto 0);
        cs_a      : in  std_logic := '1';

        address_b : in  std_logic_vector(addr_width-1 downto 0) := (others => '0');
        data_b    : in  std_logic_vector(data_width-1 downto 0) := (others => '0');
        enable_b  : in  std_logic := '1';
        wren_b    : in  std_logic := '0';
        q_b       : out std_logic_vector(data_width-1 downto 0);
        cs_b      : in  std_logic := '1'
    );
end entity;

architecture rtl of dpram is
begin
    u0 : entity work.dpram_dif
        generic map(addr_width, data_width, addr_width, data_width, mem_init_file)
        port map(clock,
                 address_a, data_a, enable_a, wren_a, q_a, cs_a,
                 address_b, data_b, enable_b, wren_b, q_b, cs_b);
end rtl;
