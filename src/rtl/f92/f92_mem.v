// karabas: the eZ80F92 memory map of the Agon (as the oracle / agon_machine.rs and the testbench):
//   on-chip SRAM 8 KB at {RAM_ADDR_U}:E000 while RAM_CTL.7 (first), flash 128 KB at
//   {FLASH_ADDR_U}:0000 (read only), external RAM 512 KB (A18..A0) when the address is in the CS0
//   window LBR..UBR, else nothing (reads F5).
// Ports: F7 FLASH_ADDR_U, F8 FLASH_CTRL, B4 RAM_CTL, B5 RAM_ADDR_U, A8..B3 CS0..CS3 LBR / UBR / CTL
// (stored and read back; only CS0 maps). Reset values: RAM_CTL 80, RAM_ADDR_U FF, CS0 00..FF.
module f92_mem (
	input             clk,
	input             reset,
	input      [23:0] a,           // the memory address
	output            sel_ram,     // on-chip SRAM, offset a[12:0]
	output            sel_flash,   // flash, offset fofs
	output     [16:0] fofs,
	output            sel_ext,     // external RAM, offset a[18:0]
	// the map ports
	input             psel,        // a port of this block (see pmine)
	input       [7:0] paddr,       // the port (low byte)
	input             wr,
	input       [7:0] din,
	output reg  [7:0] dout,
	output            pmine        // paddr is one of the ports above
);
	reg [7:0] flash_u, flash_ctl, ram_ctl, ram_u;
	reg [7:0] cs [0:11];           // A8 + 3n: LBR, UBR, CTL

	wire [23:0] ro = a - {ram_u, 16'he000};
	wire [23:0] fo = a - {flash_u, 16'h0000};
	assign sel_ram   = ram_ctl[7] && ro[23:13] == 11'd0;
	assign sel_flash = !sel_ram && fo[23:17] == 7'd0;
	assign fofs      = fo[16:0];
	assign sel_ext   = !sel_ram && !sel_flash && a[23:16] >= cs[0] && a[23:16] <= cs[1];

	assign pmine = paddr == 8'hf7 || paddr == 8'hf8 || paddr == 8'hb4 || paddr == 8'hb5 ||
	               (paddr >= 8'ha8 && paddr <= 8'hb3);
	wire [7:0] ci = paddr - 8'ha8;
	always @* begin
		case (paddr)
		8'hf7: dout = flash_u;
		8'hf8: dout = flash_ctl;
		8'hb4: dout = ram_ctl;
		8'hb5: dout = ram_u;
		default: dout = (paddr >= 8'ha8 && paddr <= 8'hb3) ? cs[ci[3:0]] : 8'hff;
		endcase
	end

	integer i;
	always @(posedge clk) begin
		if (reset) begin
			flash_u <= 8'h00; flash_ctl <= 8'h88; ram_ctl <= 8'h80; ram_u <= 8'hff;
			for (i = 0; i < 12; i = i + 1) cs[i] <= 8'h00;
			cs[1] <= 8'hff;
		end else if (psel && wr) begin
			case (paddr)
			8'hf7: flash_u <= din;
			8'hf8: flash_ctl <= din;
			8'hb4: ram_ctl <= din;
			8'hb5: ram_u <= din;
			default: if (paddr >= 8'ha8 && paddr <= 8'hb3) cs[ci[3:0]] <= din;
			endcase
		end
	end
endmodule
