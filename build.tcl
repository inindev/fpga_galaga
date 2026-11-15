# Gowin build script for the Galaga core (TangCore), run from this folder:
#
#   gw_sh build.tcl nano20k
#   gw_sh build.tcl console60k|console138k|primer25k [ds2|snes]
#
# gw_sh is in the bin directory of the Gowin IDE install (add it to PATH or give its full path).
# Results go to ./impl: impl/pnr/galaga_<board>[_snes].{fs,bin}, reports in
# impl/gwsynthesis and impl/pnr. The .bin goes on the TangCore drive as
# cores/<board>/galaga.bin (snescontroller/cores/<board>/ for a _snes build).
#
# The board layer shared by every board is in tang/nano20k/. The GW5A boards (Tang Console
# 60K/138K, Primer 25K) share tang/gw5a/ (16-bit SDRAM controller, USB host, .sdc) and have
# their own pins and board defines in tang/console/ and tang/primer25k/; tang/pll/ has the
# GW5AST-138 PLLs, tang/plla/ the GW5AT-60 and GW5A-25 ones.

set boards {nano20k console60k console138k primer25k}
set dev  [lindex $argv 0]
set ctrl [expr {$argc >= 2 ? [lindex $argv 1] : "ds2"}]
if {$argc < 1 || $argc > 2 || [lsearch $boards $dev] < 0 || [lsearch {ds2 snes} $ctrl] < 0 ||
    ($dev eq "nano20k" && $argc == 2)} {
    puts "Usage: gw_sh build.tcl nano20k"
    puts "       gw_sh build.tcl console60k|console138k|primer25k \[ds2|snes\]"
    puts "    nano20k:     Sipeed Tang Nano 20K (DualShock and SNES pads together)"
    puts "    console60k, console138k: Sipeed Tang Console, DualShock (default) or SNES pads on PMOD1"
    puts "    primer25k:   Sipeed Tang Primer 25K with the Tang SDRAM module, DualShock or SNES pads"
    exit 1
}
set brd tang/nano20k
set gw5 tang/gw5a

switch $dev {
    nano20k     { set_device GW2AR-LV18QN88C8/I7 -device_version C }
    console138k { set_device GW5AST-LV138PG484AC1/I0 -device_version B
                  set pll tang/pll;  set bdir tang/console;   set bname console }
    console60k  { set_device GW5AT-LV60PG484AC1/I0 -device_version B
                  set pll tang/plla; set bdir tang/console;   set bname console }
    primer25k   { set_device GW5A-LV25MG121NC1/I0 -device_version A
                  set pll tang/plla; set bdir tang/primer25k; set bname primer25k }
}
if {$dev ne "nano20k"} {
    # board defines, before top.sv
    set bfile [expr {$ctrl eq "snes" ? "${bname}_snescontroller" : $bname}]
    add_file -type verilog "$bdir/$bfile.v"
}

# ---- board level
add_file -type verilog "$brd/top.sv"
if {$dev eq "nano20k"} {
    add_file -type verilog "$brd/gowin_pll_hdmi.v"
    add_file -type verilog "$brd/gowin_pll_game.v"
} else {
    add_file -type verilog "$pll/gowin_pll_game.v"
    add_file -type verilog "$pll/gowin_pll_27.v"
    add_file -type verilog "$pll/gowin_pll_hdmi.v"
    add_file -type verilog "$pll/pll_12.v"
    add_file -type verilog "$pll/gowin_pll_sdram.v"
    add_file -type verilog "$gw5/usb_hid_host.v"
}
add_file -type verilog "$brd/rom_stream.sv"
add_file -type verilog "$brd/framebuffer.sv"
add_file -type verilog "$brd/fb_writer.sv"
add_file -type verilog "$brd/fb_reader.sv"
add_file -type verilog [expr {$dev eq "nano20k" ? "$brd/sdram.v" : "$gw5/sdram16.v"}]
add_file -type verilog "$brd/controller_snes.v"
add_file -type verilog "$brd/controller_ds2.sv"
add_file -type verilog "$brd/dualshock_controller.v"

# ---- TangCore IO system (shared files from fpga_tangcore/common, see scripts/sync_common.sh)
add_file -type verilog "$brd/iosys/iosys_bl616.v"
add_file -type verilog "$brd/iosys/textdisp.v"
add_file -type verilog "$brd/iosys/uart_fixed.v"
add_file -type verilog "$brd/iosys/gowin_dpb_menu.v"

# ---- HDMI encoder (hdl-util)
foreach f {audio_clock_regeneration_packet audio_info_frame audio_sample_packet \
           auxiliary_video_information_info_frame hdmi packet_assembler packet_picker \
           serializer source_product_description_info_frame tmds_channel} {
    add_file -type verilog "$brd/hdmi/$f.sv"
}

# ---- core (rtl/, VHDL), in dependency order: T80 CPU, memories, video, 54XX, sound, top
foreach f {cpu/T80_Pack cpu/T80_MCode cpu/T80_ALU cpu/T80_Reg cpu/T80 cpu/T80se gen_ram dpram \
           gen_video stars stars_machine mb88 sound_machine galaga} {
    add_file -type vhdl "rtl/$f.vhd"
}

if {$dev eq "nano20k"} {
    add_file -type cst "$brd/nano20k.cst"
    add_file -type sdc "$brd/galaga.sdc"
} else {
    add_file -type cst "$bdir/$bfile.cst"
    add_file -type sdc "$gw5/galaga.sdc"
}

set_option -synthesis_tool gowinsynthesis
set_option -top_module top
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -rw_check_on_ram 1
# place/route options (RF_PLACE / RF_ROUTE override them, for trying others). The Console
# 138K uses place 3 / route 2: its SNES-controller build missed clk48 with place 2 (-1.5 ns),
# and in a sweep of place 0-4 x route 0-2 (2026-11-15) 3/2 had the most margin (clk48 50.5 MHz).
set place_option 2
set route_option ""
if {$dev eq "console138k"} { set place_option 3; set route_option 2 }
if {[info exists ::env(RF_PLACE)]} { set place_option $::env(RF_PLACE) }
if {[info exists ::env(RF_ROUTE)]} { set route_option $::env(RF_ROUTE) }
set_option -place_option $place_option
if {$route_option ne ""} { set_option -route_option $route_option }
# registers that connect straight to a pin go into the I/O block, so the SDRAM and
# other pin timing does not change with placement
set_option -ireg_in_iob 1
set_option -oreg_in_iob 1
set_option -ioreg_in_iob 1
# dual-purpose pins used as GPIO (the MSPI flash pins are not used and stay as they are)
set_option -use_sspi_as_gpio 1
set_option -use_ready_as_gpio 1
set_option -use_done_as_gpio 1
set_option -use_i2c_as_gpio 1
set_option -use_cpu_as_gpio 1
# DS2 (and Nano 20K) builds keep the plain name the drive uses
set_option -output_base_name [expr {$ctrl eq "snes" ? "galaga_${dev}_snes" : "galaga_${dev}"}]

run all
