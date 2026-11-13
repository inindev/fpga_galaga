# [Galaga](https://en.wikipedia.org/wiki/Galaga)

A port of Dar's Galaga core (release 0.3, as collected by Somhi in the DECAfpga
`Arcade_Galaga` repository) to the Sipeed Tang Nano 20K, with HDMI output, as a
<a href="https://github.com/nand2mario/tangcore">TangCore</a> core: the TangCore BL616 firmware
loads it from the USB drive and sends it the game's ROMs. The picture goes through a frame
buffer in SDRAM, so it can be shown rotated (an option in the in-game menu).

<p>Galaga was released by Namco in 1981, and by Midway in North America. The player's fighter
moves left and right along the bottom of the screen and shoots at the Galaga aliens, which fly
in formation and dive at it. A Boss Galaga can capture the fighter with a tractor beam; shooting
that boss frees the fighter, and the two then fight side by side.</p>

<strong>CPUs:</strong> three Z80 at 3.072 MHz (main, sub, sound)<br>
<strong>Sound:</strong> Namco 3-voice waveform sound generator, and a Namco 54XX (a Fujitsu MB88 4-bit microcontroller) for the explosions<br>
<strong>Video resolution:</strong> 288 x 224 visible, 6.144 MHz pixel clock, 60.61 Hz, vertical (rotated) monitor<br>
<strong>Video hardware:</strong> a tile layer, 64 sprites and the Namco 05XX starfield; 32 colours from a palette PROM<br>

<h2>Compatible Platforms</h2>
<li>Sipeed Tang Nano 20K with the TangCore firmware (HDMI, 1280x720 at 60 Hz)</li>

<h2>Building</h2>
<p><code>gw_sh build.tcl nano20k</code> in this folder (Gowin 1.9.11.03) writes the core to <code>impl/pnr/galaga_nano20k.bin</code>.
See <a href="tang/nano20k/BUILD.md">tang/nano20k/BUILD.md</a> for the build, where the core and the ROM zips go on the USB drive,
the controls and how the port works.</p>

<h2>Compatible Games</h2>
<blockquote>
<p dir="auto"><strong>ROMs NOT INCLUDED:</strong> By using this core you agree to provide your own roms.</p>
</blockquote>

<li>Galaga (Midway, Set 1), MAME set <code>galagamw</code> (in a merged <code>galaga.zip</code> or a split <code>galagamw.zip</code>), with the 54XX program from <code>namco54.zip</code>: <code>releases/Galaga (Midway, Set 1).mra</code>, the MiSTer MRA with the ROM image changed for this core (the changes are listed in a comment in the MRA)</li>

<h2>Issues</h2>
<li>Coinage is always 1 coin, 1 credit: the core emulates the Namco 51XX (coins and credits) in logic, and it ignores the coinage switches.</li>
<li>Cocktail mode (the cabinet DIP switch set to cocktail, where the game turns the picture for player 2) has not been tested.</li>
<li>No high score saving.</li>
<li>Rotated, the picture is 672 x 720 on the HDMI screen: each pixel 3x across, and rows alternately 2 and 3 lines down, so rows are not all the same height. The original 3:4 tube shape would be 540 wide.</li>
<li>The game runs at its original 60.61 Hz and HDMI at 60 Hz: about one game frame in 100 is never shown.</li>
<li>No self-test or service switch (the MRA's switches 16 and 17 are not sent to the core).</li>

<h2>Credits</h2>
<li>Galaga core: Dar (darfpga), <a href="http://darfpga.blogspot.fr">darfpga.blogspot.fr</a></li>
<li>Collection and ports to other boards: Somhi and DECAfpga (<a href="https://github.com/DECAfpga/Arcade_Galaga">Arcade_Galaga</a>)</li>
<li>Z80: T80 core by Daniel Wallner (<code>rtl/cpu/</code>, BSD-style licence in each file)</li>
<li><code>rtl/gen_ram.vhd</code>: Peter Wendrich (Syntiac)</li>
<li>The MRA: the MiSTer project's <code>Galaga (Midway, Set 1).mra</code></li>
<li>TangCore IO system (<code>tang/nano20k/iosys/</code>) and the SNES/DualShock pad modules: nand2mario's TangCore and NESTang</li>
<li>HDMI encoder: hdl-util HDMI by Sameer Puri (MIT OR Apache-2.0, in <code>tang/nano20k/hdmi/</code>)</li>
<li>The board files (<code>tang/nano20k/</code>: frame buffer, SDRAM controller, ROM loading, top level) are adapted from this project's BurgerTime port</li>

<p>The core's source files say: "Educational use only. Do not redistribute synthetized file with
roms. Do not redistribute roms whatever the form. Use at your own risk."</p>
