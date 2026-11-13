-- -----------------------------------------------------------------------
--
-- dpram.vhd for the TangCore port of Dar's Galaga core.
--
-- Replaces the core's generated ROM entities (galaga_cpu1 ... cs54xx_prog,
-- written by make_galaga_proms.sh with the ROM contents inside): one write
-- port for the ROM download and one read port, both on the same clock. The
-- read port has a clock enable (the cycle that was the rising edge of the
-- original ROM's clock) and the same address width and registered output as
-- the entity it replaces. Written so Gowin maps it to block RAM
-- (semi-dual-port). Contents start as zero.
--
-- -----------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

entity dpram is
	generic (
		addr_width_g : integer := 8;
		data_width_g : integer := 8
	);
	port (
		clock     : in  std_logic;
		-- write port (ROM download)
		wren_a    : in  std_logic;
		address_a : in  std_logic_vector(addr_width_g-1 downto 0);
		data_a    : in  std_logic_vector(data_width_g-1 downto 0);
		-- read port
		enable_b  : in  std_logic;
		address_b : in  std_logic_vector(addr_width_g-1 downto 0);
		q_b       : out std_logic_vector(data_width_g-1 downto 0)
	);
end entity;

architecture rtl of dpram is
	type ramDef is array(0 to 2**addr_width_g-1) of std_logic_vector(data_width_g-1 downto 0);
	signal ram : ramDef := (others => (others => '0'));
begin
	process(clock)
	begin
		if rising_edge(clock) then
			if wren_a = '1' then
				ram(to_integer(unsigned(address_a))) <= data_a;
			end if;
			if enable_b = '1' then
				q_b <= ram(to_integer(unsigned(address_b)));
			end if;
		end if;
	end process;
end architecture;
