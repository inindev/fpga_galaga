// Galaga on the Tang Primer 25K (dock, Tang SDRAM module), SNES controllers: board defines, read before top.sv
`define GW5A                    // 50 MHz clock, GW5A PLLs (tang/plla), no Nano onboard parts
`define SDRAM16                 // Tang SDRAM module (16-bit) on the 40-pin header: tang/gw5a/sdram16.v
`define CONTROLLER_SNES         // SNES pads on the PMOD
