library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity fifo_receive is
    port (
        clock : in std_logic;
        data  : in std_logic_vector (14 downto 0);
        rdreq : in std_logic;
        wrreq : in std_logic;
        empty : out std_logic;
        full  : out std_logic;
        q     : out std_logic_vector (14 downto 0);
        usedw : out std_logic_vector (7 downto 0)
    );
end fifo_receive;

architecture behavioral of fifo_receive is
    type ram_type is array (0 to 255) of std_logic_vector(14 downto 0);
    signal ram : ram_type := (others => (others => '0'));
    
    signal wr_ptr : unsigned(7 downto 0) := (others => '0');
    signal rd_ptr : unsigned(7 downto 0) := (others => '0');
    signal count  : unsigned(8 downto 0) := (others => '0');
    
    signal is_empty : std_logic := '1';
    signal is_full  : std_logic := '0';
begin
    process(clock)
    begin
        if rising_edge(clock) then
            if wrreq = '1' and is_full = '0' then
                ram(to_integer(wr_ptr)) <= data;
                wr_ptr <= wr_ptr + 1;
            end if;
            
            if rdreq = '1' and is_empty = '0' then
                rd_ptr <= rd_ptr + 1;
            end if;
            
            -- Count update
            if (wrreq = '1' and is_full = '0') and (rdreq = '0' or is_empty = '1') then
                count <= count + 1;
            elsif (rdreq = '1' and is_empty = '0') and (wrreq = '0' or is_full = '1') then
                count <= count - 1;
            end if;
        end if;
    end process;
    
    is_empty <= '1' when count = 0 else '0';
    is_full  <= '1' when count = 256 else '0';
    
    empty <= is_empty;
    full  <= is_full;
    
    -- First Word Fall Through
    q <= ram(to_integer(rd_ptr));
    
    usedw <= std_logic_vector(count(7 downto 0));
end behavioral;
