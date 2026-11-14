// Timing constraints for Galaga on the Tang Console 60K/138K and Primer 25K.
//
// Only the real clocks are declared. clk48 and clk32 come from the same PLL VCO
// (864 MHz / 18 and / 27), so paths between them are timed as related clocks.

// 50 MHz board oscillator, and 27 MHz from it (as fpga_nestang's Console build) for the game
// and HDMI PLLs
create_clock -name clk50 -period 20 -waveform {0 10} [get_ports {sys_clk}]
create_generated_clock -name clk27 -source [get_ports {sys_clk}] -master_clock clk50 -multiply_by 27 -divide_by 50 [get_pins {u_pll_27/PLL_inst/CLKOUT0}]

// Game PLL: 48 MHz core clock (clkm_48MHZ) and 32 MHz SDRAM/iosys clock (clkm_32MHZ)
create_generated_clock -name clk48 -source [get_pins {u_pll_27/PLL_inst/CLKOUT0}] -master_clock clk27 -multiply_by 16 -divide_by 9 [get_pins {u_pll_game/PLL_inst/CLKOUT0}]
create_generated_clock -name clk32 -source [get_pins {u_pll_27/PLL_inst/CLKOUT0}] -master_clock clk27 -multiply_by 32 -divide_by 27 [get_pins {u_pll_game/PLL_inst/CLKOUT1}]

// HDMI: 371.25 MHz serial clock from 27 MHz, divided by 5 to the 74.25 MHz pixel clock
create_generated_clock -name hclk5 -source [get_pins {u_pll_27/PLL_inst/CLKOUT0}] -master_clock clk27 -multiply_by 55 -divide_by 4 [get_pins {u_pll_hdmi/PLL_inst/CLKOUT0}]
create_generated_clock -name hclk -source [get_pins {u_pll_hdmi/PLL_inst/CLKOUT0}] -master_clock hclk5 -divide_by 5 [get_pins {u_div5/CLKOUT}]

// USB host: 12 MHz from the 50 MHz clock
create_generated_clock -name clk12 -source [get_ports {sys_clk}] -master_clock clk50 -multiply_by 6 -divide_by 25 [get_pins {u_pll_12/PLL_inst/CLKOUT0}]

// Clock crossings: a register named *_meta is the first stage of a 2-flop synchroniser (see
// tang/nano20k/galaga.sdc for the list). Gowin uses only one .sdc.
set_false_path -to [get_regs {*_meta*}]
