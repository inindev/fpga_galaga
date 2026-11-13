# Galaga on the Sipeed Tang Nano 20K

A port of Dar's Galaga core to the Sipeed Tang Nano 20K (GW2AR-LV18QN88C8/I7), as a
[TangCore](https://github.com/nand2mario/tangcore) core. The TangCore BL616 firmware loads the
core from the USB drive, shows the menu and sends the game's ROMs to the core over its UART.
Video and sound go out over the HDMI port at 1280x720, 60 Hz. The picture goes through a frame
buffer in the embedded SDRAM, which lets it be shown rotated, as on the original upright cabinet.

## Files

All under `tang/nano20k/` unless noted.

| File | Purpose |
|---|---|
| `build.tcl` (repository root) | `gw_sh` build script |
| `top.sv` | Top level: PLLs, iosys, ROM loading, core, gamepads, frame buffer, audio, HDMI, LEDs |
| `rom_stream.sv` | Writes the ROM image from the firmware into the core's block RAM (`dn_*` port) |
| `framebuffer.sv` | Frame buffer: `fb_writer.sv`, `fb_reader.sv` and `sdram.v`, with the SDRAM arbiter |
| `fb_writer.sv` | Core pixels into one of three buffers in SDRAM, rotated or not |
| `fb_reader.sv` | Latest finished buffer to the 1280x720 HDMI picture, scaled and centred, with the menu overlay |
| `sdram.v` | Controller for the GW2AR's embedded 8 MB SDRAM (32 MHz, one access at a time, byte or 32-bit word) |
| `gowin_pll_game.v` | Game PLL: 27 MHz in, 48 MHz and 32 MHz out |
| `gowin_pll_hdmi.v` | HDMI PLL: 27 MHz in, 371.25 MHz out (divided by 5 to 74.25 MHz in `top.sv`) |
| `nano20k.cst` | Pin constraints (clock, S1, LEDs, HDMI, UART, gamepads). The SDRAM is placed by the tool |
| `galaga.sdc` | Timing constraints |
| `iosys/` | TangCore IO system: `iosys_bl616.v`, `textdisp.v`, `uart_fixed.v` (copies of `fpga_tangcore/common/iosys`, kept in step by `scripts/sync_common.sh`) and `gowin_dpb_menu.v` (menu font and this core's logo, written by `scripts/font_glyphs.py`) |
| `controller_snes.v`, `controller_ds2.sv`, `dualshock_controller.v` | SNES and DualShock pads on the board's pins, from TangCore's nestang |
| `hdmi/` | HDMI encoder from hdl-util by Sameer Puri, MIT OR Apache-2.0 (licence files in `hdmi/`). Local changes are listed at the top of `hdmi/hdmi.sv` |

The core is in `rtl/` (VHDL): `galaga.vhd` (the board), `gen_video.vhd` (video timing),
`stars.vhd` and `stars_machine.vhd` (starfield), `sound_machine.vhd` (Namco waveform sound),
`mb88.vhd` (the 54XX's MB88 microcontroller), `cpu/` (T80, Z80), `gen_ram.vhd` and `dpram.vhd`
(memories written so Gowin maps them to block RAM). The changes from Dar's core are listed at
the top of each file. `sim/` has the simulations (`sim/core`: the core against Dar's
unmodified core, GHDL; `sim/fb`: the frame buffer, Verilator); their outputs go to `sim/out/`,
which git ignores.

## Build

You need the Gowin IDE or its command-line `gw_sh`, version 1.9.11.03. The Education edition
works. From the repository root:

```sh
/path/to/gowin/IDE/bin/gw_sh build.tcl nano20k
```

The core is written to `impl/pnr/galaga_nano20k.bin` (and `.fs`). Reports are in
`impl/gwsynthesis/` and `impl/pnr/`. A build takes a few minutes.

On a Linux machine without a display, `gw_sh` can fail to start with a Qt "xcb" error. Set
`QT_QPA_PLATFORM=offscreen` before running it.

`galaga.sdc` declares the four real clocks (27 MHz input, 48 and 32 MHz game, 74.25 MHz
HDMI). The 48 and 32 MHz clocks come from one PLL and are timed against each other; the HDMI
clock comes from another PLL and the tool does not time paths between it and the game clocks.
The only other line is `set_false_path -to [get_regs {*_meta*}]`: a register named `*_meta` is
the first flop of a two-flop synchroniser, where the crossing is on purpose and the value is
used only after the second flop. They are iosys's UART input; in `top.sv` the core reset, the
menu state, the controls and the DIP switches into the 48 MHz clock and the core's audio into
the HDMI clock; in `rom_stream.sv` the download handshake (both ways); in `fb_writer.sv` and
`fb_reader.sv` the frame buffer's toggles and flags, the rotate option and the menu state; in
`hdmi.sv` the master volume. Gowin uses only one `.sdc`, so the line is in this one. There are
no multicycle paths: the whole core, its three Z80s included, is timed at 48 MHz. Check
`impl/pnr/galaga_nano20k_tr_content.html` ("Max Frequency Summary") after a change; all clocks
meet timing with place options 0, 1 and 2, the 48 MHz clock with almost nothing to spare
(48.01 to 48.30 MHz), on paths inside the T80s.

The design must not depend on placement. Two things here exist for that reason, keep them
when changing the code:

- `build.tcl` puts registers that connect straight to a pin into the I/O blocks
  (`-ireg_in_iob`, `-oreg_in_iob`, `-ioreg_in_iob`). `sdram.v` registers the 32-bit DQ bus
  with nothing in front of the register, and `top.sv` drives the SDRAM clock from an ODDR.
  Without this, some placements read bad data from SDRAM (in the System SJ port this showed
  as a white screen or stray pixels).
- Each block RAM is written and read on the same clock where both ports can meet: all the
  core's memories run on the 48 MHz clock (the download port too). The frame buffer's two
  dual-clock RAMs (the writer's staging lines, the reader's line buffer) are never read and
  written at the same address at the same time (see `fb_writer.sv`, `fb_reader.sv`).

A quick check after a change: build with `-place_option` 0, 1 and 2 (`build.tcl` uses 2) and
run the game on each. All three should be free of stray pixels.

Use: logic 10,234 of 20,736 (50%), registers 4,387 (28%), block RAM 40 of 46 (87%).

## Installing on the TangCore USB drive

| Path on the drive | What |
|---|---|
| `cores/nano20k/galaga.bin` | The core: `impl/pnr/galaga_nano20k.bin` renamed |
| `arcade/Galaga (Midway, Set 1).mra` | The game: the `.mra` from `releases/` |
| `arcade/mame/galaga.zip` (or `galagamw.zip`) | Your MAME ROM set for Galaga (Midway set 1, `galagamw`): a merged `galaga.zip` or a split `galagamw.zip` |
| `arcade/mame/namco54.zip` | MAME's Namco 54XX device ROM, `54xx.bin` |

The TangCore firmware must be a version that knows this core (core ID 9, `fpga_firmware-bl616`
with `core/galaga.cpp`). ROMs are not included. You need your own MAME ROM sets, named as in
the MRA's `<rom zip=...>` (`galaga.zip|galagamw.zip|namco51.zip|namco54.zip`; `namco51.zip` is
not needed). The main menu's "Arcade" entry lists `arcade/`; choose the `.mra`. As on MiSTer,
the firmware reads the MRA (`<rbf>galaga</rbf>` selects this core), builds the ROM image from
the zips (each part found by its CRC, in the order the MRA gives), and sends it to the core
together with the MRA's DIP switch defaults. The MRA's `<rom index="3">` and `<rom index="4">`
(MiSTer's high score table) and `<nvram>` are not used.

## ROM loading

The core is TangCore core ID 9. `iosys_bl616` receives the firmware's commands over the UART
(2 Mbaud) and hands the ROM image to `rom_stream.sv` byte by byte, from image offset 0, between
`rom_loading` going 0 -> 1 and 1 -> 0. The whole image is kept in block RAM. Image layout
(offset):

| Offset | Size | Contents (MAME name) | Core memory |
|---|---|---|---|
| 0x0000 | 16 KB | CPU 1 program `3200a.bin`, `3300b.bin`, `3400c.bin`, `3500d.bin` | `galaga_cpu1` |
| 0x4000 | 4 KB | CPU 2 program `3600e.bin` | `galaga_cpu2` |
| 0x5000 | 4 KB | CPU 3 program `3700g.bin` | `galaga_cpu3` |
| 0x6000 | 8 KB | Sprite graphics `2800l.bin`, `2700k.bin` | `sp_graphx` |
| 0x8000 | 4 KB | Tile graphics `2600j.bin` | `bg_graphx` |
| 0x9000 | 1 KB | 54XX program `54xx.bin` (`namco54.zip`) | `cs54xx_prog` |
| 0x9400 | 256 B | Tile colour lookup `prom-4.2n` | `bg_palette` |
| 0x9500 | 256 B | Sprite colour lookup `prom-3.1c` | `sp_palette` |
| 0x9600 | 256 B | Sound waveforms `prom-1.1d` | `sound_samples` |
| 0x9700 | 256 B | Sound sequencer `prom-2.5c` | `sound_seq` |
| 0x9800 | 32 B | Palette `prom-5.5n` | `rgb` |

The image is 0x9820 bytes (38,944), about 0.2 s at 2 Mbaud. Bytes from 0x9820 on are ignored.
The core is held in reset from power-up until a load has ended with at least 0x9820 bytes, and
again during every new load. The reset holds the three CPUs and the 54XX; the video timing,
starfield and sound machine keep running. `rom_stream.sv` hands each byte from the 32 MHz
iosys clock to the core's 48 MHz download port with a request/acknowledge handshake.

The firmware also sends a 32-bit core configuration (iosys `core_config`) when the game loads,
and again whenever the menu's "Rotate screen" changes:

| Bits | Meaning |
|---|---|
| 7-0 | MRA switch byte 0 (MAME's `DSWA`, inverted). The core gets `dip_switch_a = ~byte`, as on MiSTer |
| 15-8 | MRA switch byte 1 (MAME's `DSWB`, inverted). The core gets `dip_switch_b = ~byte`, as on MiSTer |
| 16 | 1 = rotate the picture (the menu's "Rotate screen"), taken at the next frame |
| 31-17 | 0 |

The MRA default is `08,68`: 2-credit game for 2 players, difficulty easy, demo sounds on,
upright cabinet, 1 coin 1 credit, bonus fighters at 20K, 70K and every 70K, 3 fighters. The
meaning of each bit is in the `<switches>` block of the MRA. The coinage switches have no
effect (see "Known limitations"). The MRA's switches 16 and 17 (self-test, service) are not
sent; the core's test and service inputs are held off.

## Controls

Gamepads: USB gamepads through the BL616 firmware, and SNES and DualShock pads on the pins
TangCore's nestang uses. Pad 1 and pad 2 both drive the same controls, and those go to both
players' inputs (the two players take turns).

| Pad | Game |
|---|---|
| D-pad left, right | Move the fighter (up and down are not used) |
| B, Y or A | Fire (one shot per press) |
| SELECT | Coin |
| START on pad 1 | 1P start |
| START on pad 2, or R on either pad | 2P start |
| Board button S1 | Coin and 1P start together (debounced, about 11 ms) |

The firmware opens its menu with the key combination chosen in its options. While the menu is
shown the game is paused (sound too) and gets no buttons; the screen keeps the last picture.
The in-game menu has "Rotate screen: On / Off" (default On), saved in `tangcore.ini` as
`rotate=on|off` in the `[galaga]` section. The volume (firmware options) sets the HDMI audio
level.

## LEDs

Both LEDs are active low (on when the pin is driven low).

| LED | On means |
|---|---|
| LED0 (pin 15) | A ROM is loaded and the core is running |
| LED1 (pin 16) | A ROM is loading, or the last load ended with fewer than 0x9820 bytes (the core stays in reset) |

## How it works

**Clocks.** The game PLL makes 48 MHz and 32 MHz from the 27 MHz crystal, the HDMI PLL
371.25 MHz, divided by 5 to the 74.25 MHz pixel clock. The whole core runs on 48 MHz with clock
enables that stand for the original board's 18.432 MHz clock: `ce18` for its rising edge and
`ce18n`, on the next 48 MHz cycle, for its falling edge (the memories' read clock). 48 MHz is not
a multiple of 18.432 MHz, so `ce18` comes on 48 of every 125 cycles, every 2 or 3 cycles, spread
evenly. The core's own enables run from it as on the original board: the 6.144 MHz pixel clock,
the three Z80s at 3.072 MHz, the sound machine and the 54XX. The game's timing is the
original: 384 x 264 pixels per frame, 60.61 Hz. The SDRAM, iosys, ROM loading and gamepads run
on 32 MHz.

**Frame buffer.** The game runs at 60.61 Hz and HDMI at 60 Hz, so the picture goes through
three frame buffers in the embedded SDRAM. `fb_writer.sv` takes the core's pixels (RGB 3:3:2,
one byte each, four to a 32-bit SDRAM word): the core's 288 x 224 active picture
(`video_blankn` high), MAME's visible area. It stages 4 lines at a time in block RAM and writes
them into a free buffer in the order they will be shown, rotated or not, so the reader always
reads display rows straight through. A frame starts at the core's vertical sync. The colour,
`blankn` and `vs` are taken one 48 MHz cycle after the core's pixel enable, when the values
the core wrote at the enable are there, all three for the same pixel. Not at the enable:
the core's video mux pairs the current palette/star select with a palette colour one `ce18`
old, so the value present at the enable has the previous pixel's colour wherever the pixel
is not transparent, and one-pixel-wide strokes are lost (see `top.sv`). A finished
frame becomes the latest; at the start of each HDMI frame `fb_reader.sv` takes the latest
finished buffer and shows it whole, so a frame is never torn. About one game frame in 100 is
never shown.

**Rotation.** The original monitor is mounted on its side. With "Rotate screen" on, the picture
is turned clockwise, as the MRA says (`vertical (cw)`). Each buffer records whether it was
written rotated, so a change of the option takes effect on the next whole frame. On a cocktail
cabinet (the cabinet DIP switch), the game itself turns the picture for player 2; the frame
buffer shows it as the game draws it.

**Layout on the 1280 x 720 screen,** centred, black around it:

| Rotate | Scale | Picture |
|---|---|---|
| On | 3x across, rows alternately 2 and 3 lines down | 672 x 720 |
| Off | 3x across, 3x down | 864 x 672 |

**Menu.** The firmware's menu (iosys `textdisp`, 256 x 224 pixels) is drawn 3x across and 3x
down in a 768 x 672 window in the middle of the screen, the same window as the monitor core's
main menu and the NES and SNES cores, over the picture dimmed to a quarter. The volume bar is a
strip of it over the running game.

**Audio.** The core's 10-bit unsigned audio (the 54XX's two outputs and the Namco waveform
sound machine, mixed in the core) is used as `{audio, 6'b0}`, made signed by inverting the top
bit, and sent on both HDMI channels at 48 kHz, 16 bit: each HDMI sample takes the core's latest
value, so the pitch is unchanged. `hdmi.sv` scales it by the firmware's master volume.

**SDRAM.** One access at a time, CAS latency 2, auto precharge, at 32 MHz. The frame buffer
uses 32-bit word accesses; the writer and the reader take turns, and the SDRAM is busy about
31% of the time.

## Known limitations

- Coinage is always 1 coin, 1 credit: the core's 51XX (coin and credit chip) is emulated in
  logic and ignores the coinage switches.
- Cocktail mode is untested. With the cabinet DIP switch set to cocktail the game turns the
  picture for player 2 itself (the core's `flip_h`); whether the core turns everything (tiles,
  sprites, starfield) has not been checked.
- No high score saving.
- Rotated, the picture is 672 x 720: 3x across, and rows alternately 2 and 3 lines down, so
  rows are not all the same height. The original 3:4 tube shape would be 540 wide.
- Not rotated, the picture is 864 x 672, close to but not exactly 4:3 (896 x 672).
- No self-test or service switch: the MRA's switches 16 and 17 are not sent, and the core's
  `b_test` and `b_svce` inputs are held off.
- Only Galaga (Midway, Set 1) has an MRA. The Namco sets and the other versions in MAME's
  `galaga.zip` are not supported.
- The 54XX's third sound output is not used (as in Dar's core).
