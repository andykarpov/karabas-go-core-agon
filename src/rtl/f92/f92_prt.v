// karabas: eZ80F92 programmable reload timers PRT0..PRT5 (ports 80h..91h, 3 per timer).
//
// Behaviour as the Agon emulator (agon-ez80-emulator prt_timer.rs) and the MOS drivers (timer.c,
// misc.asm __wait_timer0) use it:
//   TMRx_CTL  (80 + 3x): 7 PRT_IRQ (set at the count to 0, cleared by a CTL read), 6 IRQ_EN,
//             4 PRT_MODE (1 continuous: reload at 0, 0 single pass: stop at 0), 3:2 CLK_DIV
//             (4 / 16 / 64 / 256 system clocks), 1 RST_EN (load the reload value, self-clearing),
//             0 PRT_EN
//   TMRx_DR_L (81 + 3x) read: counter low, latches the high byte for the DR_H read
//   TMRx_DR_H (82 + 3x) read: the latched high byte
//   TMRx_RR_L / RR_H write: the reload value
// The counter steps on sys_ce (the 18.432 MHz system clock of the F92 as a clock enable, so MOS
// delays keep real time whatever the CPU clock). irq[x] = PRT_IRQ and IRQ_EN.
module f92_prt (
	input             clk,
	input             reset,
	input             sys_ce,      // one pulse per F92 system clock
	input             sel,         // the port is in 80h..91h (rd / wr below)
	input       [4:0] addr,        // port - 80h
	input             rd,          // one-clock read strobe (taken with the data)
	input             wr,          // one-clock write strobe
	input       [7:0] din,
	output reg  [7:0] dout,        // read data for addr (combinational)
	output      [5:0] irq
);
	wire [2:0] t  = addr / 5'd3;
	wire [1:0] rg = addr % 5'd3;
	wire [7:0] c0, c1, c2, c3, c4, c5;
	wire [7:0] l0, l1, l2, l3, l4, l5;
	wire [7:0] h0, h1, h2, h3, h4, h5;

	f92_prt1 u0 (clk, reset, sys_ce, sel && t == 3'd0, rg, rd, wr, din, c0, l0, h0, irq[0]);
	f92_prt1 u1 (clk, reset, sys_ce, sel && t == 3'd1, rg, rd, wr, din, c1, l1, h1, irq[1]);
	f92_prt1 u2 (clk, reset, sys_ce, sel && t == 3'd2, rg, rd, wr, din, c2, l2, h2, irq[2]);
	f92_prt1 u3 (clk, reset, sys_ce, sel && t == 3'd3, rg, rd, wr, din, c3, l3, h3, irq[3]);
	f92_prt1 u4 (clk, reset, sys_ce, sel && t == 3'd4, rg, rd, wr, din, c4, l4, h4, irq[4]);
	f92_prt1 u5 (clk, reset, sys_ce, sel && t == 3'd5, rg, rd, wr, din, c5, l5, h5, irq[5]);

	reg [7:0] c, l, h;
	always @* begin
		case (t)
		3'd0: begin c = c0; l = l0; h = h0; end
		3'd1: begin c = c1; l = l1; h = h1; end
		3'd2: begin c = c2; l = l2; h = h2; end
		3'd3: begin c = c3; l = l3; h = h3; end
		3'd4: begin c = c4; l = l4; h = h4; end
		default: begin c = c5; l = l5; h = h5; end
		endcase
		dout = rg == 2'd0 ? c : rg == 2'd1 ? l : h;
	end
endmodule

// one timer
module f92_prt1 (
	input             clk,
	input             reset,
	input             sys_ce,
	input             me,
	input       [1:0] rg,          // 0 CTL, 1 DR_L / RR_L, 2 DR_H / RR_H
	input             rd,
	input             wr,
	input       [7:0] din,
	output reg  [7:0] ctl,
	output      [7:0] dr_l,
	output reg  [7:0] dr_h,        // the latched high byte
	output            irq
);
	reg [15:0] rld, cnt;
	reg  [7:0] pre;
	assign dr_l = cnt[7:0];
	assign irq = ctl[7] & ctl[6];
	wire [7:0] div = ctl[3:2] == 2'd0 ? 8'd3 : ctl[3:2] == 2'd1 ? 8'd15 :
	                 ctl[3:2] == 2'd2 ? 8'd63 : 8'd255;

	always @(posedge clk) begin
		if (reset) begin
			ctl <= 8'h00; rld <= 16'h0000; cnt <= 16'h0000; pre <= 8'h00; dr_h <= 8'h00;
		end else begin
			if (sys_ce && ctl[0]) begin
				if (ctl[1]) begin
					cnt <= rld; pre <= 8'h00; ctl[1] <= 1'b0;
				end else if (pre == div) begin
					pre <= 8'h00;
					if (cnt == 16'h0001) begin
						ctl[7] <= 1'b1;
						if (ctl[4]) cnt <= rld;
						else begin cnt <= 16'h0000; ctl[1:0] <= 2'b00; end
					end else
						cnt <= cnt - 16'h0001;
				end else
					pre <= pre + 8'h01;
			end
			// the CPU after the counter: its write wins
			if (me && rd && rg == 2'd0) ctl[7] <= 1'b0;
			if (me && rd && rg == 2'd1) dr_h <= cnt[15:8];
			if (me && wr) begin
				case (rg)
				2'd0: ctl <= {1'b0, din[6:0]};
				2'd1: rld[7:0] <= din;
				default: rld[15:8] <= din;
				endcase
			end
		end
	end
endmodule
