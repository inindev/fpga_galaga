#!/usr/bin/env python3
"""Write the unmodified Galaga core's ROM entities (galaga_cpu1.vhd ... cs54xx_prog.vhd).

Usage: make_ref_proms.py <zipdir> <outdir>

The same files as upstream's tools/galaga_unzip/make_galaga_proms.sh, in the
same order, written in the form of its make_vhdl_prom tool (entity <name>,
ports clk, addr, data; a registered read). Each file is found by its CRC-32 in
galaga.zip, galagamw.zip or namco54.zip in zipdir (in any folder of the zip),
independently of the MRA, so V1 also checks the MRA's ROM image layout.
The output is game data: write it only to ignored paths (sim/out/).
"""
import math
import os
import sys
import zipfile

# entity: files (MAME name, CRC-32), as make_galaga_proms.sh
PROMS = [
    ('galaga_cpu1', [('3200a.bin', 0x3ef0b053), ('3300b.bin', 0x1b280831),
                     ('3400c.bin', 0x16233d33), ('3500d.bin', 0x0aaf5c23)]),
    ('galaga_cpu2', [('3600e.bin', 0xbc556e76)]),
    ('galaga_cpu3', [('3700g.bin', 0xb07f0aa4)]),
    ('bg_graphx', [('2600j.bin', 0x58b2f47c)]),
    ('sp_graphx', [('2800l.bin', 0xad447c80), ('2700k.bin', 0xdd6f1afc)]),
    ('rgb', [('prom-5.5n', 0x54603c6b)]),
    ('bg_palette', [('prom-4.2n', 0x59b6edab)]),
    ('sp_palette', [('prom-3.1c', 0x4a04bb6b)]),
    ('sound_seq', [('prom-2.5c', 0x77245b66)]),
    ('sound_samples', [('prom-1.1d', 0x7a2815b4)]),
    ('cs54xx_prog', [('54xx.bin', 0xee7357e0)]),
]
ZIPS = ['galaga.zip', 'galagamw.zip', 'namco54.zip']


def vhdl(name, data):
    aw = int(math.ceil(math.log2(len(data))))
    s = ['library ieee;', 'use ieee.std_logic_1164.all,ieee.numeric_std.all;', '',
         'entity %s is' % name, 'port (', '\tclk  : in  std_logic;',
         '\taddr : in  std_logic_vector(%d downto 0);' % (aw - 1),
         '\tdata : out std_logic_vector(7 downto 0)', ');', 'end entity;', '',
         'architecture prom of %s is' % name,
         '\ttype rom is array(0 to  %d) of std_logic_vector(7 downto 0);' % (len(data) - 1)]
    rows = [','.join('X"%02X"' % b for b in data[i:i + 16]) for i in range(0, len(data), 16)]
    s.append('\tsignal rom_data: rom := (\n\t\t' + ',\n\t\t'.join(rows) + ');')
    s += ['begin', 'process(clk)', 'begin', '\tif rising_edge(clk) then',
          '\t\tdata <= rom_data(to_integer(unsigned(addr)));', '\tend if;', 'end process;',
          'end architecture;', '']
    return '\n'.join(s)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    zipdir, outdir = sys.argv[1], sys.argv[2]
    zips = [zipfile.ZipFile(os.path.join(zipdir, z)) for z in ZIPS
            if os.path.isfile(os.path.join(zipdir, z))]
    by_crc = {}
    for z in zips:
        for info in z.infolist():
            by_crc.setdefault(info.CRC, (z, info))
    os.makedirs(outdir, exist_ok=True)
    for name, files in PROMS:
        data = b''
        for fname, crc in files:
            if crc not in by_crc:
                sys.exit('no file with crc %08x (%s) in %s' % (crc, fname, ', '.join(ZIPS)))
            z, info = by_crc[crc]
            data += z.read(info)
        with open(os.path.join(outdir, name + '.vhd'), 'w') as f:
            f.write(vhdl(name, data))
        print('%s.vhd: %d bytes' % (name, len(data)))


if __name__ == '__main__':
    main()
