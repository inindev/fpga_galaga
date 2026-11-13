#!/usr/bin/env python3
"""Copy the unmodified Galaga core's sources for V1, with the changes V1 needs.

Usage: ref_patch.py <upstream> <outdir> [--dsw-a HEX] [--dsw-b HEX]

upstream is the Arcade_Galaga repository; its rtl_dar/ files galaga.vhd,
gen_video.vhd, gen_ram.vhd, sound_machine.vhd, stars.vhd, stars_machine.vhd and
mb88.vhd are copied to outdir with these changes, each applied exactly once:

- The DIP switch read indexes the switches with mux_addr(2 downto 0) instead of
  mux_addr(3 downto 0) (port_plan.md decision 17). The 4-bit index is out of
  range of the 8-bit vectors whenever it is 8-15, which stops GHDL with a bound
  check failure. The port makes the same change.
- cs51XX_non_switch_mode_do's last choice "11" is written "others" (the same
  logic; GHDL requires every value of std_logic_vector to be covered and
  stops with "missing choice(s)"). The port makes the same change.
- dip_switch_a and dip_switch_b get the values given (default F7 and 97, the
  values upstream has), for the cocktail run.
- The registers the port starts at 0 (they are loaded only on some cycles and
  have no reset or initial value; in a simulator they would start undefined
  and some never leave it, e.g. the 51XX credit count and the star machines)
  get the same initial value 0, as FPGA registers power up. So do the
  contents of gen_ram (the FPGA's memories power up as zero).

The T80 files and stars.vhd are used unchanged from upstream (rtl_T80/, rtl_dar/).
"""
import argparse
import os
import sys

V0 = " := (others => '0')"
B0 = " := '0'"


def init(decls, kind=V0):
    """Changes adding an initial value to the declarations given as written."""
    return [(d + ';', d + kind + ';') for d in decls]


def changes(dsw_a, dsw_b):
    return {
        'galaga.vhd': [
            ('dip_switch_a <= "11110111";', 'dip_switch_a <= "%s";' % format(dsw_a, '08b')),
            ('dip_switch_b <= "10010111";', 'dip_switch_b <= "%s";' % format(dsw_b, '08b')),
            ('X"00" when "11"; -- N.U.', 'X"00" when others; -- "11" N.U.'),
            ('dip_switch_do <= \tdip_switch_a(to_integer(unsigned(mux_addr(3 downto 0)))) & \n'
             '\t\t\t\t\t\t\t\t\tdip_switch_b(to_integer(unsigned(mux_addr(3 downto 0))));',
             'dip_switch_do <= \tdip_switch_a(to_integer(unsigned(mux_addr(2 downto 0)))) & \n'
             '\t\t\t\t\t\t\t\t\tdip_switch_b(to_integer(unsigned(mux_addr(2 downto 0))));'),
        ] + init([
            ' signal cpu1_nmi_n  : std_logic',
            ' signal cpu3_nmi_n  : std_logic',
            ' signal fire1_mem : std_logic',
            ' signal fire2_mem : std_logic',
        ], B0) + init([
            ' signal cs06XX_control : std_logic_vector( 7 downto 0)',
            ' signal credit_bcd_0              : std_logic_vector( 3 downto 0)',
            ' signal credit_bcd_1              : std_logic_vector( 3 downto 0)',
            ' signal bgtile_num     : std_logic_vector( 7 downto 0)',
            ' signal bgtile_num_r   : std_logic_vector( 7 downto 0)',
            ' signal bgtile_color   : std_logic_vector( 7 downto 0)',
            ' signal bgtile_color_r : std_logic_vector( 7 downto 0)',
            ' signal sprite_num     : std_logic_vector(5 downto 0)',
            ' signal sptile_num     : std_logic_vector(7 downto 0)',
            ' signal sptile_color   : std_logic_vector(7 downto 0)',
            ' signal spdata         : std_logic_vector(3 downto 0)',
            ' signal spvcnt         : std_logic_vector(4 downto 0)',
            ' signal sphcnt         : std_logic_vector(4 downto 0)',
            ' signal spram_wr_addr  : std_logic_vector(8 downto 0)',
            ' signal spram_rd_addr  : std_logic_vector(8 downto 0)',
            ' signal spbits_rd      : std_logic_vector(3 downto 0)',
            ' signal stars_hcnt      : std_logic_vector( 8 downto 0)',
            ' signal stars_vcnt      : std_logic_vector( 8 downto 0)',
        ]) + [
            (' signal sprite_state   : std_logic_vector(2 downto 0); ',
             ' signal sprite_state   : std_logic_vector(2 downto 0)' + V0 + '; '),
            (' signal stars_offset    : std_logic_vector( 7 downto 0); ',
             ' signal stars_offset    : std_logic_vector( 7 downto 0)' + V0 + '; '),
            (' signal cs54xx_k_port_in  : std_logic_vector( 3 downto 0); ',
             ' signal cs54xx_k_port_in  : std_logic_vector( 3 downto 0)' + V0 + '; '),
            (' signal cs54xx_r0_port_in : std_logic_vector( 3 downto 0); ',
             ' signal cs54xx_r0_port_in : std_logic_vector( 3 downto 0)' + V0 + '; '),
        ],
        'gen_video.vhd': [
            ('vsync   : out std_logic;', 'vsync   : out std_logic' + B0 + ';'),
            ('csync   : out std_logic; -- composite', 'csync   : out std_logic' + B0 + '; -- composite'),
            ('signal hblank  : std_logic; ', 'signal hblank  : std_logic' + B0 + '; '),
            ('signal vblank  : std_logic; ', 'signal vblank  : std_logic' + B0 + '; '),
            ('signal hsync0       : std_logic;', 'signal hsync0       : std_logic' + B0 + ';'),
            ('signal hsync1       : std_logic; ', 'signal hsync1       : std_logic' + B0 + '; '),
            ('signal hsync2       : std_logic; ', 'signal hsync2       : std_logic' + B0 + '; '),
        ],
        'gen_ram.vhd': [
            ('\tsignal ram: ramDef;', '\tsignal ram: ramDef := (others => (others => \'0\'));'),
        ],
        'sound_machine.vhd': init([
            ' signal samples_ch0 : std_logic_vector(3 downto 0)',
            ' signal samples_ch1 : std_logic_vector(3 downto 0)',
            ' signal samples_ch2 : std_logic_vector(3 downto 0)',
            ' signal volume_ch0  : std_logic_vector(3 downto 0)',
            ' signal volume_ch1  : std_logic_vector(3 downto 0)',
            ' signal volume_ch2  : std_logic_vector(3 downto 0)',
        ]),
        'stars_machine.vhd': init([
            ' signal stars_set_addr : std_logic_vector( 6 downto 0)',
            ' signal stars_state    : std_logic_vector( 2 downto 0)',
            ' signal star_0         : std_logic_vector(13 downto 0)',
            ' signal star_1         : std_logic_vector(13 downto 0)',
            ' signal star_2         : std_logic_vector(13 downto 0)',
        ]),
        'mb88.vhd': init([
            ' r0_port_out : out std_logic_vector(3 downto 0)',
            ' r1_port_out : out std_logic_vector(3 downto 0)',
            ' r2_port_out : out std_logic_vector(3 downto 0)',
            ' r3_port_out : out std_logic_vector(3 downto 0)',
            ' ol_port_out : out std_logic_vector(3 downto 0)',
            ' oh_port_out : out std_logic_vector(3 downto 0)',
            ' p_port_out  : out std_logic_vector(3 downto 0)',
        ]),
        'stars.vhd': [],
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('upstream')
    ap.add_argument('outdir')
    ap.add_argument('--dsw-a', default='F7')
    ap.add_argument('--dsw-b', default='97')
    a = ap.parse_args()
    os.makedirs(a.outdir, exist_ok=True)
    for name, reps in changes(int(a.dsw_a, 16), int(a.dsw_b, 16)).items():
        with open(os.path.join(a.upstream, 'rtl_dar', name), newline='') as f:
            s = f.read().replace('\r\n', '\n')
        for old, new in reps:
            n = s.count(old)
            if n != 1:
                sys.exit('%s: %d matches for %r' % (name, n, old))
            s = s.replace(old, new)
        with open(os.path.join(a.outdir, name), 'w') as f:
            f.write(s)
    print('%s: reference sources (DSWA %s, DSWB %s)' % (a.outdir, a.dsw_a.upper(), a.dsw_b.upper()))


if __name__ == '__main__':
    main()
