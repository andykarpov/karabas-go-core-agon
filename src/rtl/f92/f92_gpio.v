// karabas: one eZ80F92 GPIO port (B: 9Ah..9Dh, C: 9Eh..A1h, D: A2h..A5h): DR, DDR, ALT1, ALT2.
//
// The mode of a pin = {ALT2, ALT1, DDR, DR} bits, as the Agon emulator (gpio.rs):
//   0 / 1 output (the level = DR)    2 / 3 input    4 / 5 open drain, 6 / 7 open source (as outputs)
//   8 -    9 interrupt on both edges    10 / 11 alternate function (input level)
//   12 interrupt while low    13 while high    14 on the falling edge    15 on the rising edge
// In the interrupt modes (8..15) a DR write does not store DR: writing 1 to a bit clears its
// pending interrupt (12 / 13: only when the level no longer holds). A DDR / ALT1 / ALT2 write
// clears the pending interrupts of the bits it changes. DR read = the pin levels.
// irq[n] = the interrupt pending on pin n (vectors: B 30h + 2n, C 40h + 2n, D 50h + 2n).
module f92_gpio (
	input             clk,
	input             reset,
	input             sel,         // the port is in this GPIO port (rd / wr below)
	input       [1:0] addr,        // 0 DR, 1 DDR, 2 ALT1, 3 ALT2
	input             wr,
	input       [7:0] din,
	output reg  [7:0] dout,        // read data for addr (combinational)
	input       [7:0] pin_in,      // the input levels of the pins
	output      [7:0] pin_out,     // the output levels (DR in the output modes)
	output      [7:0] pin_oe,      // 1 = the pin drives (output modes; open drain only for 0)
	output reg  [7:0] irq,
	output      [7:0] pin_alt      // 1 = the alternate function (modes 10 / 11)
);
	reg [7:0] dr, ddr, alt1, alt2, lvl_q;

	wire [7:0] outm = ~ddr & ~alt1 & ~alt2 | ~ddr & alt1 & ~alt2 | ddr & alt1 & ~alt2;  // modes 0-7 but 2/3
	wire [7:0] lvl  = (outm & dr) | (~outm & pin_in);
	assign pin_out = dr;
	assign pin_alt = alt2 & ~alt1 & ddr;
	assign pin_oe  = (~ddr & ~alt1 & ~alt2) |                 // push-pull
	                 (~ddr & alt1 & ~alt2 & ~dr) |            // open drain: drives 0
	                 (ddr & alt1 & ~alt2 & dr);               // open source: drives 1
	wire [7:0] intm = alt2;                                   // modes 8..15
	wire [7:0] m9   = alt2 & ~alt1 & ~ddr & dr;
	wire [7:0] m12  = alt2 & alt1 & ~ddr & ~dr;
	wire [7:0] m13  = alt2 & alt1 & ~ddr & dr;
	wire [7:0] m14  = alt2 & alt1 & ddr & ~dr;
	wire [7:0] m15  = alt2 & alt1 & ddr & dr;
	wire [7:0] chg  = lvl ^ lvl_q;
	wire [7:0] set  = (m9 & chg) | (m12 & ~lvl) | (m13 & lvl) | (m14 & chg & ~lvl) | (m15 & chg & lvl);

	always @* begin
		case (addr)
		2'd0: dout = lvl;
		2'd1: dout = ddr;
		2'd2: dout = alt1;
		default: dout = alt2;
		endcase
	end

	always @(posedge clk) begin
		if (reset) begin
			dr <= 8'h00; ddr <= 8'hff; alt1 <= 8'h00; alt2 <= 8'h00; lvl_q <= 8'h00; irq <= 8'h00;
		end else begin
			lvl_q <= lvl;
			irq <= irq | set;
			if (sel && wr) begin
				case (addr)
				2'd0: begin
					dr  <= (dr & intm) | (din & ~intm);
					// clear: 9 / 14 / 15 always, 12 / 13 when the level no longer holds
					irq <= (irq | set) & ~(din & intm & ~(m12 & ~lvl) & ~(m13 & lvl));
				end
				2'd1: begin ddr  <= din; irq <= (irq | set) & ~(ddr ^ din); end
				2'd2: begin alt1 <= din; irq <= (irq | set) & ~(alt1 ^ din); end
				default: begin alt2 <= din; irq <= (irq | set) & ~(alt2 ^ din); end
				endcase
			end
		end
	end
endmodule
