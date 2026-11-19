// karabas: Ф1.4 step 4 simulation top: the whole Agon: agon_ez80 (eZ80 + F92, clk_ez) and vdp_soc
// (the VDP machine + scanout, clk_vdp / clk_pix) joined by agon_link (the UART0 link, CTS, vblank to
// PB1). The eZ80 memories, the SD card and the SDRAM are C++ models (tb_agon.cpp).
module agon_sim_top (
	input             clk_ez,
	input             clk_vdp,
	input             clk_pix,
	input             reset_n,
	input             sys_ce,
	// eZ80 memory
	output     [23:0] maddr,
	output            mrd,
	output            mwr,
	output      [7:0] mdo,
	input       [7:0] mem_di,
	output            sel_ram,
	output            sel_flash,
	output     [16:0] flash_ofs,
	output            sel_ext,
	// SD
	output            sd_sck,
	output            sd_mosi,
	input             sd_miso,
	output            sd_cs_n,
	// VDP
	input             aud_ce,
	input             sim_shot_req,
	output            sim_shot_wr,
	output     [31:0] sim_shot,
	output            dbg_con_wr,
	output      [7:0] dbg_con,
	output     [12:0] sdr_a,
	output      [1:0] sdr_ba,
	input      [15:0] sdr_dq_i,
	output     [15:0] sdr_dq_o,
	output     [15:0] sdr_dq_oe_n,
	output      [1:0] sdr_dqm,
	output            sdr_ras_n,
	output            sdr_cas_n,
	output            sdr_we_n,
	output      [1:0] vid_r,
	output      [1:0] vid_g,
	output      [1:0] vid_b,
	output            vid_hs,
	output            vid_vs,
	output            vid_de,
	// debug: the bytes on the link
	output      [7:0] dbg_ez_tx,
	output            dbg_ez_tx_wr,
	output      [7:0] dbg_v_tx,
	output            dbg_v_tx_wr,
	output            dbg_v_rx_wr,
	output            dbg_cts,
	output     [31:0] dbg_viadr,
	output            dbg_vrun,
	output      [7:0] dbg_vbus,
	output    [127:0] regx,
	output            insn
);
	wire [7:0] u0_tx_data, u0_rx_data, v_rx_data, v_tx_data;
	wire u0_tx_valid, u0_tx_ready, u0_rx_valid, u0_rx_full, u0_cts, ez_vblank;
	wire v_rx_valid, v_cts, v_tx_valid, v_tx_ready, v_vblank;
	assign dbg_ez_tx = u0_tx_data;
	assign dbg_ez_tx_wr = u0_tx_valid & u0_tx_ready;
	assign dbg_v_tx = v_tx_data;
	assign dbg_v_tx_wr = v_tx_valid & v_tx_ready;
	assign dbg_v_rx_wr = v_rx_valid;
	assign dbg_cts = u0_cts;

	wire [1:0] vid_omode_w;                 // (one clk_pix for all the outputs here)
	agon_ez80 u_ez (.clk(clk_ez), .reset_n(reset_n), .sys_ce(sys_ce), .maddr(maddr), .mrd(mrd), .mwr(mwr),
		.mdo(mdo), .mem_di(mem_di), .sel_ram(sel_ram), .sel_flash(sel_flash), .flash_ofs(flash_ofs),
		.sel_ext(sel_ext), .u0_tx_data(u0_tx_data), .u0_tx_valid(u0_tx_valid), .u0_tx_ready(u0_tx_ready),
		.u0_rx_data(u0_rx_data), .u0_rx_valid(u0_rx_valid), .u0_rx_full(u0_rx_full), .u0_cts(u0_cts),
		.sd_sck(sd_sck), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs_n(sd_cs_n),
		.joy_pc(8'hff), .joy_pd(4'hf), .u1_rxd(1'b1), .u1_txd(), .u1_cts_n(), .vsync(ez_vblank),
		.insn(insn), .regx(regx), .regs(), .halt_n(), .dbg_io_rd(), .dbg_io_wr(), .dbg_io_d());

	agon_link u_link (.clk_ez(clk_ez), .clk_vdp(clk_vdp),
		.ez_tx_data(u0_tx_data), .ez_tx_valid(u0_tx_valid), .ez_tx_ready(u0_tx_ready),
		.ez_rx_data(u0_rx_data), .ez_rx_valid(u0_rx_valid), .ez_rx_full(u0_rx_full), .ez_cts(u0_cts),
		.ez_vblank(ez_vblank),
		.vdp_rx_data(v_rx_data), .vdp_rx_valid(v_rx_valid), .vdp_cts(v_cts),
		.vdp_tx_data(v_tx_data), .vdp_tx_valid(v_tx_valid), .vdp_tx_ready(v_tx_ready), .vdp_vblank(v_vblank));

	vdp_soc #(.SDRAM_INIT_CLOCKS(15'd100)) u_vdp (.clk(clk_vdp), .reset(!reset_n),
		.ld_active(1'b0), .ld_addr(25'd0), .ld_data(8'd0), .ld_wr(1'b0), .ld_ready(),
		.ez_rx_data(v_rx_data), .ez_rx_valid(v_rx_valid), .ez_cts(v_cts),
		.ez_tx_data(v_tx_data), .ez_tx_valid(v_tx_valid), .ez_tx_ready(v_tx_ready),
		.clk_pix(clk_pix), .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b), .vid_hs(vid_hs), .vid_vs(vid_vs),
		.vid_de(vid_de), .vid_omode(vid_omode_w), .vid_pmode(vid_omode_w), .vid_hneg(), .vid_vneg(),
		.vblank(v_vblank),
		.ps2_code(8'd0), .ps2_wr(1'b0),
		.ms_x(8'd0), .ms_y(8'd0), .ms_z(8'd0), .ms_b(8'd0), .ms_wr(1'b0), .dbg_ez(32'd0),
		.aud_ce(aud_ce), .aud_out(), .sim_shot_req(sim_shot_req), .sim_req(1'b0),
		.sim_shot_wr(sim_shot_wr), .sim_shot(sim_shot),
		.dbg_con_wr(dbg_con_wr), .dbg_con(dbg_con), .dbg_exit(), .dbg_mark_wr(), .dbg_mark(), .cpu_run(dbg_vrun),
		.dbg_rx_poll(), .dbg_iadr(dbg_viadr), .dbg_io(), .dbg_bus(dbg_vbus),
		.sdr_a(sdr_a), .sdr_ba(sdr_ba), .sdr_dq_i(sdr_dq_i), .sdr_dq_o(sdr_dq_o), .sdr_dq_oe_n(sdr_dq_oe_n),
		.sdr_dqm(sdr_dqm), .sdr_ras_n(sdr_ras_n), .sdr_cas_n(sdr_cas_n), .sdr_we_n(sdr_we_n));
endmodule
