// Galaga on the Tang Console 60K/138K, DualShock controllers: board defines, read before top.sv
`define GW5A                    // 50 MHz clock, GW5A PLLs (tang/pll, tang/plla), no Nano onboard parts
`define S1_ACTIVE_LOW           // board button S1
`define SDRAM16                 // Tang SDRAM module (16-bit): tang/gw5a/sdram16.v
`define USB2                    // two front USB-A ports (USB host on the FPGA)
`define CONTROLLER_DS2          // DualShock pads on PMOD1
