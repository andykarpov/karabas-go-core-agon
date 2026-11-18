`timescale 1ns / 1ps
`default_nettype none
/*
 vdp_soc.v (karabas, Ф1.4)

 The VDP machine of the Agon: VexRiscv (rv32im, I$ 16K, D$ 16K, src/rtl/vexriscv/VexRiscv_16k.v)
 running the Console8 VDP firmware (src/vdp) from the SDRAM (vdp_sdram = core-doom doom_sdram), the
 MMIO of src/vdp/mmio.h, the byte link to the eZ80 UART0 (FIFOs both ways) and the audio FIFO.
 After core-doom doom_soc.v, without the SRAM (the eZ80 owns it). One clock (clk, 75 MHz).

 CPU memory map: 0x10000000 SDRAM 32 MB (the firmware at 0); 0x80000000 MMIO (VexRiscv IO range =
 bit 31, uncached); anything else reads 0. MMIO (word registers, mmio.h):
   00 W CON: debug console byte (dbg_con)          08 W EXIT: dbg_exit = { 1, code }
   0c R CYCLES: clocks since reset                 10 / 14 R US: microseconds since reset (64 bit)
   18 R FRAME: vblank starts of the scanout                  1c R MS: milliseconds since reset
   40 R EZ_RX: { valid, byte } from the eZ80 (pops) 44 W EZ_TX: a byte to the eZ80
   48 R EZ_STAT: bit 0 a byte waiting, bit 1 room for a byte to the eZ80
   50 W MARK (dbg_mark)                            54 SHOT, 58 SIMREQ: simulation only (sim_* ports)
   5c R AUDIO: free places of the audio FIFO; W: one 8-bit sample (unsigned)
   60 W SCAN: the address of the frame description (src/vdp/kg_scanout.cpp) for vdp_video
 Link: ez_rx_* = bytes from the eZ80 (into RX_DEPTH bytes), ez_cts = room above CTS_ROOM; ez_tx_* =
 bytes to the eZ80 (16). Audio: AUD_DEPTH samples, one leaves on each aud_ce (16384 Hz) as aud_out.
 Loader: the SDRAM is written from ld_* (a byte per write) while the CPU is held in reset.
*/
module vdp_soc #(
	parameter SDRAM_INIT_CLOCKS = 15'd16000,
	parameter [6:0] US_DIV = 7'd75,       // clocks per microsecond
	parameter [31:0] RESET_VECTOR = 32'h10000000,
	parameter RX_LOG2 = 8,                // the FIFO of bytes from the eZ80: 256
	parameter [8:0] CTS_ROOM = 9'd64,     // CTS while more room than this
	parameter AUD_LOG2 = 9                // the audio FIFO: 512 samples
) (
	input wire clk,
	input wire reset,
	// loader
	input wire ld_active,
	input wire [24:0] ld_addr,
	input wire [7:0] ld_data,
	input wire ld_wr,
	output wire ld_ready,
	// the link to the eZ80
	input wire [7:0] ez_rx_data,
	input wire ez_rx_valid,
	output wire ez_cts,
	output wire [7:0] ez_tx_data,
	output wire ez_tx_valid,
	input wire ez_tx_ready,
	// the picture (vdp_video: 640x480@60 on clk_pix 25 MHz); vblank (clk) for the eZ80 PB1
	input wire clk_pix,
	output wire [1:0] vid_r,
	output wire [1:0] vid_g,
	output wire [1:0] vid_b,
	output wire vid_hs,
	output wire vid_vs,
	output wire vid_de,
	output wire vblank,
	// audio
	input wire aud_ce,
	output reg [7:0] aud_out = 8'h80,
	// simulation
	input wire sim_shot_req,
	input wire sim_req,
	output reg sim_shot_wr = 1'b0,
	output reg [31:0] sim_shot = 32'd0,
	// debug
	output reg dbg_con_wr = 1'b0,
	output reg [7:0] dbg_con = 8'd0,
	output reg [8:0] dbg_exit = 9'd0,
	output reg dbg_mark_wr = 1'b0,
	output reg [31:0] dbg_mark = 32'd0,
	output wire cpu_run,
	output reg dbg_rx_poll = 1'b0,        // an EZ_RX / EZ_STAT read
	output wire [31:0] dbg_iadr,          // the instruction fetch address
	output reg [8:0] dbg_io = 9'd0,       // the last MMIO access { we, offset }
	// SDRAM pins (the top makes the tristate)
	output wire [12:0] sdr_a,
	output wire [1:0] sdr_ba,
	input wire [15:0] sdr_dq_i,
	output wire [15:0] sdr_dq_o,
	output wire [15:0] sdr_dq_oe_n,
	output wire [1:0] sdr_dqm,
	output wire sdr_ras_n,
	output wire sdr_cas_n,
	output wire sdr_we_n
);

// ------------------------------------------------------------------ reset / loader

wire sdram_ready;
reg cpu_reset = 1'b1;
assign cpu_run = ~cpu_reset;
always @(posedge clk)
	cpu_reset <= reset | ld_active | ~sdram_ready;

reg ld_pend = 1'b0;
reg [24:0] ld_a = 25'd0;
reg [7:0] ld_d = 8'd0;
assign ld_ready = ~ld_pend;

// ------------------------------------------------------------------ CPU

wire i_cyc, i_stb, d_cyc, d_stb, d_we;
wire [29:0] i_adr, d_adr;
wire [31:0] d_dat_o;
wire [3:0] d_sel;
wire [2:0] i_cti, d_cti;
reg [31:0] i_dat_i, d_dat_i;
reg i_ack, d_ack;

VexRiscv cpu (
	.externalResetVector(RESET_VECTOR),
	.timerInterrupt(1'b0),
	.softwareInterrupt(1'b0),
	.externalInterruptArray(32'd0),
	.iBusWishbone_CYC(i_cyc), .iBusWishbone_STB(i_stb), .iBusWishbone_ACK(i_ack), .iBusWishbone_WE(),
	.iBusWishbone_ADR(i_adr), .iBusWishbone_DAT_MISO(i_dat_i), .iBusWishbone_DAT_MOSI(),
	.iBusWishbone_SEL(), .iBusWishbone_ERR(1'b0), .iBusWishbone_CTI(i_cti), .iBusWishbone_BTE(),
	.dBusWishbone_CYC(d_cyc), .dBusWishbone_STB(d_stb), .dBusWishbone_ACK(d_ack), .dBusWishbone_WE(d_we),
	.dBusWishbone_ADR(d_adr), .dBusWishbone_DAT_MISO(d_dat_i), .dBusWishbone_DAT_MOSI(d_dat_o),
	.dBusWishbone_SEL(d_sel), .dBusWishbone_ERR(1'b0), .dBusWishbone_CTI(d_cti), .dBusWishbone_BTE(),
	.clk(clk), .reset(cpu_reset)
);

wire d_req = d_cyc & d_stb;
assign dbg_iadr = { i_adr, 2'b00 };
wire i_req = i_cyc & i_stb;
wire d_io = d_adr[29];                                  // 0x80000000
wire d_sd = ~d_io & d_adr[29:23] == 7'b0001000;         // 0x10000000..0x11ffffff (address bits 31..25)
wire d_none = ~d_io & ~d_sd;

// ------------------------------------------------------------------ SDRAM and its owner

localparam [2:0] O_NONE = 3'd0, O_D = 3'd1, O_I = 3'd2, O_LD = 3'd3, O_V = 3'd4;
reg [2:0] own = O_NONE;
wire v_cyc;
wire [29:0] v_adr;
wire [2:0] v_cti;
wire sd_ack;
wire [31:0] sd_dat;
reg sd_cyc, sd_we;
reg [3:0] sd_sel;
reg [24:2] sd_adr;
reg [2:0] sd_cti;
reg [31:0] sd_wdat;

always @(*) begin
	sd_cyc = 1'b0; sd_we = 1'b0; sd_sel = 4'hF; sd_adr = 23'd0; sd_cti = 3'd0; sd_wdat = 32'd0;
	case (own)
	O_D: begin sd_cyc = d_req; sd_we = d_we; sd_sel = d_sel; sd_adr = d_adr[22:0]; sd_cti = d_cti; sd_wdat = d_dat_o; end
	O_I: begin sd_cyc = i_req; sd_we = 1'b0; sd_sel = 4'hF; sd_adr = i_adr[22:0]; sd_cti = i_cti; end
	O_V: begin sd_cyc = v_cyc; sd_we = 1'b0; sd_sel = 4'hF; sd_adr = v_adr[22:0]; sd_cti = v_cti; end
	O_LD: begin sd_cyc = ld_pend; sd_we = 1'b1; sd_sel = 4'b0001 << ld_a[1:0]; sd_adr = ld_a[24:2]; sd_cti = 3'd0; sd_wdat = {4{ld_d}}; end
	default: ;
	endcase
end

// the owner: kept to the last ack of a transaction (an ack with CTI not 010)
always @(posedge clk) begin
	if (cpu_reset) begin
		own <= ld_pend ? O_LD : O_NONE;
		if (own == O_LD && sd_ack) own <= O_NONE;
	end else if (own == O_NONE) begin
		if (v_cyc) own <= O_V;                   // the scanout first: it has a deadline
		else if (d_req && d_sd) own <= O_D;
		else if (i_req) own <= O_I;
	end else if (sd_ack && sd_cti != 3'b010)
		own <= O_NONE;
end

vdp_sdram #(.INIT_CLOCKS(SDRAM_INIT_CLOCKS)) sdram (
	.clk(clk), .reset(reset), .ready(sdram_ready),
	.wb_cyc(sd_cyc), .wb_stb(sd_cyc), .wb_we(sd_we), .wb_sel(sd_sel), .wb_adr(sd_adr), .wb_cti(sd_cti),
	.wb_dat_i(sd_wdat), .wb_dat_o(sd_dat), .wb_ack(sd_ack),
	.sdr_a(sdr_a), .sdr_ba(sdr_ba), .sdr_dq_i(sdr_dq_i), .sdr_dq_o(sdr_dq_o), .sdr_dq_oe_n(sdr_dq_oe_n),
	.sdr_dqm(sdr_dqm), .sdr_ras_n(sdr_ras_n), .sdr_cas_n(sdr_cas_n), .sdr_we_n(sdr_we_n)
);

// ------------------------------------------------------------------ the link FIFOs

// from the eZ80
reg [7:0] rxf [0:(1 << RX_LOG2) - 1];
reg [RX_LOG2-1:0] rx_wp = 0, rx_rp = 0;
reg [RX_LOG2:0] rx_n = 0;
wire rx_full = rx_n[RX_LOG2];
wire rx_push = ez_rx_valid & ~rx_full;
assign ez_cts = ((1 << RX_LOG2) - rx_n) > CTS_ROOM;
reg [7:0] rx_head;
always @(posedge clk) rx_head <= rxf[rx_rp];      // (the head, read a clock after a pop moved rx_rp)

// to the eZ80
reg [7:0] txf [0:15];
reg [3:0] tx_wp = 4'd0, tx_rp = 4'd0;
reg [4:0] tx_n = 5'd0;
assign ez_tx_data = txf[tx_rp];
assign ez_tx_valid = tx_n != 5'd0;
wire tx_pop = ez_tx_valid & ez_tx_ready;

// audio
reg [7:0] audf [0:(1 << AUD_LOG2) - 1];
reg [AUD_LOG2-1:0] aud_wp = 0, aud_rp = 0;
reg [AUD_LOG2:0] aud_n = 0;
wire aud_pop = aud_ce & (aud_n != 0);

// ------------------------------------------------------------------ MMIO

reg [31:0] cycles = 32'd0, ms = 32'd0, frame = 32'd0;
reg [31:0] scan_adr = 32'd0;
reg [63:0] us = 64'd0;
reg [6:0] us_div = 7'd0;
reg [9:0] ms_div = 10'd0;
reg [2:0] vs_q = 3'd0;
reg io_ack = 1'b0, io_wait = 1'b0;
reg [31:0] io_dat = 32'd0;
wire [7:0] io_off = { d_adr[5:0], 2'b00 };
wire io_go = d_req && d_io && !io_ack && !io_wait && !cpu_reset;
reg rx_pop = 1'b0, tx_push = 1'b0, aud_push = 1'b0;
reg [7:0] tx_d = 8'd0, aud_d = 8'd0;

always @(posedge clk) begin
	io_ack <= 1'b0;
	rx_pop <= 1'b0; tx_push <= 1'b0; aud_push <= 1'b0;
	dbg_con_wr <= 1'b0; dbg_mark_wr <= 1'b0; sim_shot_wr <= 1'b0;
	dbg_rx_poll <= io_go && !d_we && (io_off == 8'h40 || io_off == 8'h48);
	if (io_go) dbg_io <= { d_we, io_off };
	vs_q <= { vs_q[1:0], vblank };
	if (cpu_reset) begin
		cycles <= 32'd0; us <= 64'd0; us_div <= 7'd0; ms <= 32'd0; ms_div <= 10'd0; frame <= 32'd0;
	end else begin
		cycles <= cycles + 32'd1;
		if (us_div == US_DIV - 7'd1) begin
			us_div <= 7'd0; us <= us + 64'd1;
			if (ms_div == 10'd999) begin ms_div <= 10'd0; ms <= ms + 32'd1; end
			else ms_div <= ms_div + 10'd1;
		end else
			us_div <= us_div + 7'd1;
		if (vs_q[1] && !vs_q[2]) frame <= frame + 32'd1;
	end

	// an EZ_RX read waits a clock for the FIFO head (io_wait)
	io_wait <= 1'b0;
	if (io_wait) begin
		io_ack <= 1'b1;
		io_dat <= { 23'd0, rx_n != 0, rx_head };
		if (rx_n != 0) rx_pop <= 1'b1;
	end else if (io_go) begin
		if (d_we) begin
			io_ack <= 1'b1;
			case (io_off)
			8'h00: begin dbg_con <= d_dat_o[7:0]; dbg_con_wr <= 1'b1; end
			8'h08: dbg_exit <= { 1'b1, d_dat_o[7:0] };
			8'h44: begin tx_d <= d_dat_o[7:0]; tx_push <= tx_n != 5'd16; end
			8'h50: begin dbg_mark <= d_dat_o; dbg_mark_wr <= 1'b1; end
			8'h54: begin sim_shot <= d_dat_o; sim_shot_wr <= 1'b1; end
			8'h5c: begin aud_d <= d_dat_o[7:0]; aud_push <= !aud_n[AUD_LOG2]; end
			8'h60: scan_adr <= d_dat_o;
			default: ;
			endcase
		end else if (io_off == 8'h40) begin
			io_wait <= 1'b1;
		end else begin
			io_ack <= 1'b1;
			case (io_off)
			8'h0c: io_dat <= cycles;
			8'h10: io_dat <= us[31:0];
			8'h14: io_dat <= us[63:32];
			8'h18: io_dat <= frame;
			8'h1c: io_dat <= ms;
			8'h48: io_dat <= { 30'd0, tx_n != 5'd16, rx_n != 0 };
			8'h54: io_dat <= { 31'd0, sim_shot_req };
			8'h58: io_dat <= { 31'd0, sim_req };
			8'h5c: io_dat <= (1 << AUD_LOG2) - aud_n;
			default: io_dat <= 32'd0;
			endcase
		end
	end

	// the FIFOs (rx_pop / tx_push / aud_push take effect a clock after the access: the next one sees it)
	if (rx_push) begin rxf[rx_wp] <= ez_rx_data; rx_wp <= rx_wp + 1'b1; end
	if (rx_pop) rx_rp <= rx_rp + 1'b1;
	rx_n <= rx_n + (rx_push ? 1'b1 : 1'b0) - (rx_pop ? 1'b1 : 1'b0);
	if (tx_push) begin txf[tx_wp] <= tx_d; tx_wp <= tx_wp + 4'd1; end
	if (tx_pop) tx_rp <= tx_rp + 4'd1;
	tx_n <= tx_n + (tx_push ? 5'd1 : 5'd0) - (tx_pop ? 5'd1 : 5'd0);
	if (aud_push) begin audf[aud_wp] <= aud_d; aud_wp <= aud_wp + 1'b1; end
	if (aud_pop) begin aud_out <= audf[aud_rp]; aud_rp <= aud_rp + 1'b1; end
	aud_n <= aud_n + (aud_push ? 1'b1 : 1'b0) - (aud_pop ? 1'b1 : 1'b0);

	// loader
	if (ld_wr && !ld_pend) begin ld_pend <= 1'b1; ld_d <= ld_data; ld_a <= ld_addr; end
	if (own == O_LD && sd_ack) ld_pend <= 1'b0;
end

// ------------------------------------------------------------------ the scanout

vdp_video video (
	.clk(clk), .reset(cpu_reset), .scan_adr(scan_adr),
	.m_cyc(v_cyc), .m_adr(v_adr), .m_cti(v_cti), .m_ack((own == O_V) & sd_ack), .m_dat(sd_dat),
	.vblank_sys(vblank),
	.clk_pix(clk_pix), .r(vid_r), .g(vid_g), .b(vid_b), .hs(vid_hs), .vs(vid_vs), .de(vid_de)
);

// ------------------------------------------------------------------ CPU bus answers

reg none_ack = 1'b0;
always @(posedge clk) none_ack <= d_req & d_none & ~none_ack & ~cpu_reset;

always @(*) begin
	i_ack = (own == O_I) & sd_ack;
	i_dat_i = sd_dat;
	d_ack = ((own == O_D) & sd_ack) | io_ack | none_ack;
	d_dat_i = d_io ? io_dat : d_sd ? sd_dat : 32'd0;
end

endmodule
