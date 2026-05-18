-- VBXE stub for Tang Nano port: same entity interface as vbxe.vhdl,
-- trivial architecture that drives safe defaults.  VBXE_SWITCH is always '0'
-- so this code is never exercised; it only needs to compile cleanly.

library ieee;
use ieee.std_logic_1164.all;

entity VBXE is
generic (
    cycle_length : integer := 16
);
port (
    clk                      : in  std_logic;
    enable                   : in  std_logic;
    ntsc_fix                 : in  std_logic := '0';
    soft_reset               : in  std_logic;
    enable_179               : in  std_logic;
    reset_n                  : in  std_logic;
    pal                      : in  std_logic := '1';
    addr                     : in  std_logic_vector(4 downto 0);
    data_in                  : in  std_logic_vector(7 downto 0);
    wr_en                    : in  std_logic;
    data_out                 : out std_logic_vector(7 downto 0);

    palette_get_color        : in  std_logic_vector(7 downto 0);
    palette_get_index        : in  std_logic_vector(1 downto 0);
    r_out                    : out std_logic_vector(7 downto 0);
    g_out                    : out std_logic_vector(7 downto 0);
    b_out                    : out std_logic_vector(7 downto 0);

    VBXE_UPLOAD_PALETTE_RGB  : in  std_logic_vector(2 downto 0);
    VBXE_UPLOAD_PALETTE_INDEX: in  std_logic_vector(7 downto 0);
    VBXE_UPLOAD_PALETTE_COLOR: in  std_logic_vector(6 downto 0);

    memac_address            : in  std_logic_vector(15 downto 0);
    memac_write_enable       : in  std_logic;
    memac_cpu_access         : in  std_logic;
    memac_antic_access       : in  std_logic;
    memac_check              : out std_logic;
    memac_data_in            : in  std_logic_vector(7 downto 0);
    memac_data_out           : out std_logic_vector(7 downto 0);
    memac_request            : in  std_logic;
    memac_request_complete   : out std_logic;
    memac_dma_enable         : out std_logic;
    memac_dma_address        : in  std_logic_vector(25 downto 0);
    irq_n                    : out std_logic;

    gtia_highres             : in  std_logic;
    gtia_highres_mod         : out std_logic;
    gtia_active_hr           : in  std_logic_vector(1 downto 0);
    gtia_active_hr_mod       : out std_logic_vector(1 downto 0);
    gtia_prior               : in  std_logic_vector(7 downto 0);
    gtia_prior_raw           : in  std_logic_vector(7 downto 0);
    gtia_pf0                 : in  std_logic_vector(7 downto 0);
    gtia_pf1                 : in  std_logic_vector(7 downto 0);
    gtia_pf2                 : in  std_logic_vector(7 downto 0);
    gtia_pf3                 : in  std_logic_vector(7 downto 0);
    map_pf0                  : out std_logic_vector(7 downto 0);
    map_pf1                  : out std_logic_vector(7 downto 0);
    map_pf2                  : out std_logic_vector(7 downto 0);
    pf_palette               : out std_logic_vector(1 downto 0);
    ov_palette               : out std_logic_vector(1 downto 0);
    ov_pixel                 : out std_logic_vector(7 downto 0);
    ov_pixel_active          : out std_logic;
    xcolor                   : out std_logic;

    video_clock_antic_highres: in  std_logic;
    video_clock_antic_lowres : in  std_logic;
    video_clock_vbxe         : in  std_logic;
    gtia_hpos                : in  std_logic_vector(7 downto 0);
    vsync                    : in  std_logic
);
end VBXE;

architecture stub of VBXE is
begin
    data_out               <= (others => '0');
    r_out                  <= (others => '0');
    g_out                  <= (others => '0');
    b_out                  <= (others => '0');
    memac_check            <= '0';
    memac_data_out         <= (others => '0');
    memac_request_complete <= '0';
    memac_dma_enable       <= '0';
    irq_n                  <= '1';
    gtia_highres_mod       <= gtia_highres;
    gtia_active_hr_mod     <= gtia_active_hr;
    map_pf0                <= gtia_pf0;
    map_pf1                <= gtia_pf1;
    map_pf2                <= gtia_pf2;
    pf_palette             <= "00";
    ov_palette             <= "00";
    ov_pixel               <= (others => '0');
    ov_pixel_active        <= '0';
    xcolor                 <= '0';
end stub;
