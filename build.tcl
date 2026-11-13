# Gowin build script for the Galaga core (TangCore), run from this folder:
#
#   gw_sh build.tcl nano20k
#
# gw_sh is in the bin directory of the Gowin IDE install (add it to PATH or give its full path).
# Results go to ./impl: impl/pnr/galaga_nano20k.{fs,bin}, reports in impl/gwsynthesis and
# impl/pnr. The .bin goes on the TangCore USB drive as cores/nano20k/galaga.bin.

if {$argc != 1 || [lindex $argv 0] ne "nano20k"} {
    puts "Usage: gw_sh build.tcl nano20k"
    puts "    nano20k: Sipeed Tang Nano 20K (the only board for now)"
    exit 1
}
set dev [lindex $argv 0]
set brd tang/nano20k

set_device GW2AR-LV18QN88C8/I7 -device_version C

# ---- board level
add_file -type verilog "$brd/top.sv"
add_file -type verilog "$brd/gowin_pll_hdmi.v"
add_file -type verilog "$brd/gowin_pll_game.v"
add_file -type verilog "$brd/rom_stream.sv"
add_file -type verilog "$brd/framebuffer.sv"
add_file -type verilog "$brd/fb_writer.sv"
add_file -type verilog "$brd/fb_reader.sv"
add_file -type verilog "$brd/sdram.v"
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

add_file -type cst "$brd/nano20k.cst"
add_file -type sdc "$brd/galaga.sdc"

set_option -synthesis_tool gowinsynthesis
set_option -top_module top
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -rw_check_on_ram 1
set_option -place_option 2
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
set_option -output_base_name galaga_${dev}

run all
