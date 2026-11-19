`timescale 1ns / 1ps
`default_nettype none
/*
 agon_sram.v (karabas, Ф1.5)

 The board SRAM (2M x 16, 10 ns, asynchronous) as the memory of the eZ80, the low byte lane only
 (a halfword per byte: 2 MB of bytes, plenty):
   halfword 0x000000..0x01ffff  the flash of the F92 (MOS, 128 KB; written by the loader only)
   halfword 0x080000..0x0fffff  the external RAM (512 KB, CS0)
   halfword 0x100000..0x101fff  the on-chip SRAM of the F92 (8 KB)
 The eZ80 side is combinational on its bus (agon_ez80: the address is held through the cycle, mrd
 a read cycle, mwr the one-clock write strobe): /OE low except while writing, /WE = the write strobe
 to the RAM areas; the data of a read are taken by the core at its T2 clock (a whole clock after the
 address: 29.3 ns at 34.09 MHz against 10 ns + the pads).
 The loader (kg_mcu2 LD_*, clk_sys, the eZ80 in reset): a byte to the flash area at ld_addr, as
 address, data, /WE low two clocks, /WE high; ld_busy meanwhile. ld_own (clk_sys, while ld_active)
 gives the pins to the loader.
*/
module agon_sram (
	// eZ80 (clk_ez domain, combinational)
	input wire [23:0] maddr,
	input wire mrd,
	input wire mwr,
	input wire [7:0] mdo,
	input wire sel_ram,
	input wire sel_flash,
	input wire [16:0] flash_ofs,
	input wire sel_ext,
	output wire [7:0] mem_di,
	// loader (clk_sys)
	input wire clk_sys,
	input wire ld_own,
	input wire ld_wr,                   // a byte for the flash area
	input wire [16:0] ld_addr,
	input wire [7:0] ld_data,
	output wire ld_busy,
	// pins
	output wire [20:0] MA,
	input wire [15:0] MD_I,
	output wire [15:0] MD_O,
	output wire [15:0] MD_OE_N,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N
);
	// ---------------------------------------------------------------- the loader
	reg [1:0] lst = 2'd0;
	reg [16:0] la = 17'd0;
	reg [7:0] ld = 8'd0;
	assign ld_busy = lst != 2'd0;
	always @(posedge clk_sys) begin
		case (lst)
		2'd0: if (ld_wr) begin la <= ld_addr; ld <= ld_data; lst <= 2'd1; end
		2'd1: lst <= 2'd2;                   // /WE low
		2'd2: lst <= 2'd3;                   // /WE low
		default: lst <= 2'd0;                // /WE high, address and data held
		endcase
	end
	wire l_we = lst == 2'd1 || lst == 2'd2;

	// ---------------------------------------------------------------- the eZ80
	wire [20:0] ez_a = sel_ram ? { 8'h80, maddr[12:0] } :
	                   sel_flash ? { 4'd0, flash_ofs } :
	                   { 2'b01, maddr[18:0] };
	wire ez_we = mwr & (sel_ram | sel_ext);
	assign mem_di = (sel_ram | sel_flash | sel_ext) ? MD_I[7:0] : 8'hf5;

	assign MA      = ld_own ? { 4'd0, la } : ez_a;
	assign MD_O    = { 8'h00, ld_own ? ld : mdo };
	wire drive     = ld_own ? (lst != 2'd0) : ez_we;
	assign MD_OE_N = { 8'hff, {8{~drive}} };
	assign MWR_N   = { 1'b1, ld_own ? ~l_we : ~ez_we };
	assign MRD_N   = { 1'b1, drive };       // /OE low except while driving
endmodule
