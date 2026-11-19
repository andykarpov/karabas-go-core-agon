`timescale 1ns / 1ps
/*
 agon_vclk.v (karabas, Ф2: the video modes, user decision 2026-11-19)

 The pixel clock of the output timing the VDP asks for (vdp_video omode): 25 MHz (640x480@60, 640x400@70)
 from the main PLL, or 40 / 65 MHz (800x600@60, 1024x768@60) from a DCM_CLKGEN programmed from clk_sys
 (75 MHz x 8 / 15, x 13 / 15), selected by a BUFGMUX; with HDMI a DCM x5 behind it makes the serial
 clocks (the scheme of kg_hdmi_ft_pll of the modules, the FT812 modes of tsconf / the boot core, which
 runs on the boards; there the frequency is measured, here it is asked for).

 The switch (clk_sys):
 - 25 MHz modes: the BUFGMUX on the PLL clock, pmode = the mode at once (0 <-> 1: no clock change).
 - 40 / 65: first the BUFGMUX back on the PLL clock (DCM_CLKGEN is never selected while it is
   programmed or unlocked: the BUFGMUX switches only between running clocks), then LoadD, LoadM, GO
   (UG382 Dynamic Frequency Synthesis, as kg_hdmi_ft_pll), then PROGDONE and LOCKED, then the BUFGMUX
   on it and pmode = the mode. No lock within ~14 ms: it stays at 25 MHz and pmode 0 (the VDP picture
   is cropped to 640 x 480) until the VDP asks for another mode.
 - The DCM x5 is reset (pll_reset) at every change of its input clock; locked = it runs.
 pmode is a clk_sys register; the pixel side takes it through a synchroniser (quasi static: it
 changes only with the clock).
 CLKFX_MD_MAX = 13 / 15: the tools time clk_pix at 65 MHz (the fastest mode).
*/
module agon_vclk #(
	parameter HDMI = 1
) (
	input wire clk_sys,          // 75 MHz (BUFG): DCM_CLKGEN input and its programming
	input wire reset,            // clk_sys
	input wire clk_25,           // 25 MHz of the main PLL before its BUFG
	input wire [1:0] omode,      // clk_sys: the asked output timing
	output reg [1:0] pmode = 2'd0, // clk_sys: the timing clk_pix runs
	output wire clk_pix,
	output wire clk_hdmi,        // x5 (HDMI only)
	output wire clk_hdmi_n,      // x5, 180 degrees
	output wire locked           // the DCM x5 runs (1 without HDMI)
);

localparam [2:0] S_IDLE = 3'd0, S_LOAD = 3'd1, S_WAIT = 3'd2, S_ON = 3'd3;
reg [2:0] st = S_IDLE;
reg [1:0] last = 2'd0;            // the last asked mode that was handled
reg [1:0] tgt = 2'd0;
reg sel = 1'b0;                   // BUFGMUX: 1 = DCM_CLKGEN
reg x5_reset = 1'b0;              // a change of the clock into the DCM x5
reg [24:0] prog_data = 25'd0, prog_en = 25'd0;
reg [19:0] tmo = 20'd0;
wire prog_done, gen_locked;

// M and D of DCM_CLKGEN (CLKFX = 75 MHz x M / D)
wire [7:0] gm = tgt == 2'd3 ? 8'd13 : 8'd8;
wire [7:0] gd = 8'd15;

always @(posedge clk_sys) begin
	x5_reset <= 1'b0;
	prog_en   <= { 1'b0, prog_en[24:1] };
	prog_data <= { 1'b0, prog_data[24:1] };
	if (reset) begin
		st <= S_IDLE; last <= 2'd0; sel <= 1'b0; pmode <= 2'd0; x5_reset <= 1'b1;
	end else case (st)
	S_IDLE:
		if (omode != last) begin
			last <= omode;
			tgt <= omode;
			if (sel) x5_reset <= 1'b1;
			sel <= 1'b0;
			if (!omode[1]) pmode <= omode;          // 25 MHz modes
			else begin pmode <= 2'd0; st <= S_LOAD; end
		end
	S_LOAD: begin
		// UG382, bit 0 first: PROGDATA 1 0 (LoadD) D-1 [0:7] 0 0, 1 1 (LoadM) M-1 [0:7] 0 0, GO
		prog_data <= { 1'b0, 2'b00, gm - 8'd1, 2'b11, 2'b00, gd - 8'd1, 2'b01 };
		prog_en   <= { 1'b1, 2'b00, 8'b11111111, 2'b11, 2'b00, 8'b11111111, 2'b11 };
		tmo <= 20'd0;
		st <= S_WAIT;
	end
	S_WAIT: begin
		tmo <= tmo + 20'd1;
		if (~|prog_en && tmo > 20'd64 && prog_done && gen_locked) st <= S_ON;
		else if (&tmo) st <= S_IDLE;                  // no lock: stays at 25 MHz, pmode 0
	end
	S_ON: begin
		sel <= 1'b1; x5_reset <= 1'b1; pmode <= tgt;
		st <= S_IDLE;
	end
	default: st <= S_IDLE;
	endcase
end

wire clkgen;
DCM_CLKGEN #(
	.CLKFXDV_DIVIDE(2),
	.CLKFX_DIVIDE(15),
	.CLKFX_MULTIPLY(8),
	.SPREAD_SPECTRUM("NONE"),
	.STARTUP_WAIT("FALSE"),
	.CLKIN_PERIOD(13.333),
	.CLKFX_MD_MAX(0.867)
) gen (
	.CLKIN(clk_sys),
	.CLKFX(clkgen),
	.CLKFX180(),
	.CLKFXDV(),
	.PROGCLK(clk_sys),
	.PROGDATA(prog_data[0]),
	.PROGEN(prog_en[0]),
	.PROGDONE(prog_done),
	.FREEZEDCM(1'b0),
	.LOCKED(gen_locked),
	.STATUS(),
	.RST(reset)
);

// the select on a net of its own (the ucf can take it out of the timing analysis)
(* KEEP = "TRUE" *) wire mux_sel = sel;
wire clk_mux;
BUFGMUX pix_mux (.I0(clk_25), .I1(clkgen), .O(clk_mux), .S(mux_sel));
assign clk_pix = clk_mux;

generate
if (HDMI) begin : g_x5
	wire x5_rst;
	pll_reset x5_rst_i (.clk(clk_sys), .i_reset(x5_reset | reset), .o_reset(x5_rst));
	wire clk0, clkfx, clkfx180, clkfb, lk;
	DCM_SP #(
		.CLKDV_DIVIDE(2.000),
		.CLKFX_DIVIDE(1),
		.CLKFX_MULTIPLY(5),
		.CLKIN_DIVIDE_BY_2("FALSE"),
		.CLKIN_PERIOD(15.385),
		.CLKOUT_PHASE_SHIFT("NONE"),
		.CLK_FEEDBACK("1X"),
		.DESKEW_ADJUST("SYSTEM_SYNCHRONOUS"),
		.PHASE_SHIFT(0),
		.STARTUP_WAIT("FALSE")
	) x5 (
		.CLKIN(clk_mux), .CLKFB(clkfb), .CLK0(clk0), .CLK90(), .CLK180(), .CLK270(), .CLK2X(), .CLK2X180(),
		.CLKFX(clkfx), .CLKFX180(clkfx180), .CLKDV(), .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
		.LOCKED(lk), .STATUS(), .RST(x5_rst), .DSSEN(1'b0)
	);
	BUFG fb_buf (.O(clkfb), .I(clk0));
	BUFG s_buf (.O(clk_hdmi), .I(clkfx));
	BUFG sn_buf (.O(clk_hdmi_n), .I(clkfx180));
	assign locked = lk;
end else begin : g_no_x5
	assign clk_hdmi = 1'b0;
	assign clk_hdmi_n = 1'b0;
	assign locked = 1'b1;
end
endgenerate

endmodule
