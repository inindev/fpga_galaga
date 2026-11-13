-- -----------------------------------------------------------------------
--
-- Syntiac's generic VHDL support files.
--
-- -----------------------------------------------------------------------
-- Copyright 2005-2008 by Peter Wendrich (pwsoft@syntiac.com)
-- http://www.syntiac.com/fpga64.html
--
-- Modified April 2016 by Dar (darfpga@aol.fr)
-- http://darfpga.blogspot.fr
--   Remove address register when writing
--
-- Changes for the TangCore port (Tang Nano 20K):
--   Single clock with a clock enable (ce: the cycle that was the rising edge
--   of the RAM clock). The read happens on ce; a write is registered on ce and
--   done on the next clock, so a read on ce returns the byte stored before the
--   write, as the original does, and the read and write ports never meet in
--   the same cycle (Gowin can map the RAM to block RAM; this device rejects
--   BSRAM read-before-write mode). The contents start as zero, as the FPGA's
--   memories power up.
--
-- -----------------------------------------------------------------------
--
-- gen_rwram.vhd
--
-- -----------------------------------------------------------------------
--
-- generic ram.
--
-- -----------------------------------------------------------------------

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.numeric_std.ALL;

-- -----------------------------------------------------------------------

entity gen_ram is
	generic (
		dWidth : integer := 8;
		aWidth : integer := 10
	);
	port (
		clk : in std_logic;
		ce : in std_logic;
		we : in std_logic;
		addr : in std_logic_vector((aWidth-1) downto 0);
		d : in std_logic_vector((dWidth-1) downto 0);
		q : out std_logic_vector((dWidth-1) downto 0)
	);
end entity;

-- -----------------------------------------------------------------------

architecture rtl of gen_ram is
	subtype addressRange is integer range 0 to ((2**aWidth)-1);
	type ramDef is array(addressRange) of std_logic_vector((dWidth-1) downto 0);
	signal ram: ramDef := (others => (others => '0'));

	signal wr_pend : std_logic := '0';
	signal wr_addr : std_logic_vector((aWidth-1) downto 0);
	signal wr_d    : std_logic_vector((dWidth-1) downto 0);
begin
-- -----------------------------------------------------------------------
-- Memory write (one clock after ce)
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			if wr_pend = '1' then
				ram(to_integer(unsigned(wr_addr))) <= wr_d;
			end if;
		end if;
	end process;

-- -----------------------------------------------------------------------
-- Memory read, write request
-- -----------------------------------------------------------------------
	process(clk)
	begin
		if rising_edge(clk) then
			wr_pend <= ce and we;
			if ce = '1' then
				q <= ram(to_integer(unsigned(addr)));
				wr_addr <= addr;
				wr_d <= d;
			end if;
		end if;
	end process;
end architecture;
