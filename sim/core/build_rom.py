#!/usr/bin/env python3
"""Build the Galaga ROM image (0x9820 bytes) from MAME zips as an MRA describes it.

Usage: build_rom.py <zipdir> <out.rom> [--mra <file.mra>]

zipdir holds the zips the MRA's <rom index="0" zip="..."> lists (galaga.zip or
galagamw.zip, and namco54.zip); missing ones are skipped. The parts of the
<rom index="0"> are taken in order, as the TangCore firmware does: a part with a
crc is the member with that CRC-32 in the first zip of the list that has it (in
any folder of the zip), a part with repeat="N" is its hex bytes N times, any
other part is its hex bytes. The default MRA is releases/Galaga (Midway, Set 1).mra
in this repository. The image's MD5 is checked against the MRA's md5 attribute
(--print-md5 prints it without the check).
ROM images are game data: write them only to ignored paths (sim/out/).
"""
import argparse
import hashlib
import os
import sys
import xml.etree.ElementTree as ET
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MRA = os.path.join(HERE, '..', '..', 'releases', 'Galaga (Midway, Set 1).mra')


def hexbytes(text):
    return bytes(int(t, 16) for t in (text or '').replace(',', ' ').split())


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('zipdir')
    ap.add_argument('out')
    ap.add_argument('--mra', default=DEFAULT_MRA)
    ap.add_argument('--print-md5', action='store_true')
    a = ap.parse_args()

    rom = ET.parse(a.mra).getroot().find("rom[@index='0']")
    zips = []
    for name in rom.get('zip', '').split('|'):
        path = os.path.join(a.zipdir, name)
        if name and os.path.isfile(path):
            zips.append(zipfile.ZipFile(path))
    if not zips:
        sys.exit('none of the zips %s in %s' % (rom.get('zip'), a.zipdir))

    img = bytearray()
    for part in rom.findall('part'):
        crc = part.get('crc')
        if crc:
            for z in zips:
                info = next((i for i in z.infolist() if '%08x' % i.CRC == crc.lower()), None)
                if info:
                    img += z.read(info)
                    break
            else:
                sys.exit('no file with crc %s (%s) in %s' % (crc, part.get('name'), rom.get('zip')))
        elif part.get('repeat'):
            img += hexbytes(part.text) * int(part.get('repeat'), 0)
        else:
            img += hexbytes(part.text)

    md5 = hashlib.md5(img).hexdigest()
    want = rom.get('md5', 'none')
    if not a.print_md5 and want != 'none' and md5 != want:
        sys.exit('md5 %s does not match the MRA (%s)' % (md5, want))
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, 'wb') as f:
        f.write(img)
    print('%s: %d bytes (0x%x), md5 %s%s' % (a.out, len(img), len(img), md5,
          ' (matches the MRA)' if want == md5 else ''))


if __name__ == '__main__':
    main()
