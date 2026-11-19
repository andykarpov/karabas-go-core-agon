`timescale 1ns / 1ps
`default_nettype wire

/*
 Agon Light / Console8 core for Karabas Go (VGA, PCM5102). Made by tools/mktops.py from
 karabas_minig_top.v (do not edit: change that one and run it): the same except the pins, the MCU
 link (MCU_SCK not on a clock pin) and the video: 24 bit RGB to the VGA DAC with its pixel clock
 on V_CLK (clk_pix), the FT812 off that bus (FT_OE_N = 1), no HDMI. The floppy connector is not
 used (its outputs 0).
 The eZ80F92 machine (agon_ez80: the eZ80
 core on T80 + the F92 periphery, MOS from the .kg) and the VDP machine (vdp_soc: VexRiscv + the
 Console8 VDP firmware from the .kg + the scanout), joined by agon_link (docs/PLAN.md Ф1).

 Clocks: one PLL, VCO 750 MHz (50 * 15): clk_sys 75 MHz (the VDP, the MCU link), clk_sdr 75 MHz at
 225 degrees (SDR_CLK through an ODDR2), clk_pix 25 MHz (640 x 480 at 60 Hz, the OSD, HDMI),
 clk_hdmi / clk_hdmi_n 125 MHz, clk_ez 34.09 MHz (the eZ80; 37.5 left no timing margin: user 2026-11-19; the F92 system clock 18.432 MHz as a
 clock enable from it); FT_CLK_OUT = clk_ez / 4 (8.5 MHz).
 Memory: the eZ80 in the SRAM (agon_sram: MOS, 512 KB, the on-chip 8 KB), the VDP in the SDRAM.
 The .kg ROMs: MOS at 0 (-> the SRAM flash area), the VDP firmware at 0x1000000 (-> SDRAM 0).
 SD2 = the SD card of MOS, driven by the eZ80 SPI (PB4 = /CS).
 The keyboard: the PS/2 set 2 bytes of kg_mcu2 to the VDP (MMIO KBD, the firmware injects them into
 vdp-gl), the mouse (MS_* -> vdp_soc MOUSE -> vdp-gl). The sound: VDP samples -> PCM5102 + HDMI audio.

 Soft switches (the index of the item in the osd of core.json): 0 Reset.
*/

module karabas_go_top (
	input wire CLK_50MHZ,

	inout wire UART_RX,
	inout wire UART_TX,
	inout wire UART_CTS,
	inout wire ESP_RESET_N,
	inout wire ESP_BOOT_N,

	output wire [20:0] MA,
	inout wire [15:0] MD,
	output wire [1:0] MWR_N,
	output wire [1:0] MRD_N,

	output wire [1:0] SDR_BA,
	output wire [12:0] SDR_A,
	output wire SDR_CLK,
	output wire [1:0] SDR_DQM,
	output wire SDR_WE_N,
	output wire SDR_CAS_N,
	output wire SDR_RAS_N,
	inout wire [15:0] SDR_DQ,

	output wire SD_CS_N,
	output wire SD_CLK,
	output wire SD_DI,
	input wire SD_DO,
	input wire SD_DET_N,

	output wire [7:0] VGA_R,
	output wire [7:0] VGA_G,
	output wire [7:0] VGA_B,
	output wire VGA_HS,
	output wire VGA_VS,
	output wire V_CLK,

	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	output wire FT_OE_N,

	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,

	input wire FDC_INDEX,
	output wire [1:0] FDC_DRIVE,
	output wire FDC_MOTOR,
	output wire FDC_DIR,
	output wire FDC_STEP,
	output wire FDC_WDATA,
	output wire FDC_WGATE,
	input wire FDC_TR00,
	input wire FDC_WPRT,
	input wire FDC_RDATA,
	output wire FDC_SIDE_N,

	output wire TAPE_OUT,
	input wire TAPE_IN,
	output wire BEEPER,

	output wire DAC_LRCK,
	output wire DAC_DAT,
	output wire DAC_BCK,
	output wire DAC_MUTE,

	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO,
	input wire MCU_SPI_FT_CS_N,
	input wire MCU_SPI_SD2_CS_N,
	inout wire [1:0] MCU_SPI_IO, // [0] INT of link v2 (firmware IO1, GPIO2), [1] unused (IO0, GPIO14)

	output wire MIDI_TX,
	output wire MIDI_CLK,
	output wire MIDI_RESET_N,

	output wire FLASH_CS_N,
	input wire FLASH_DO,
	output wire FLASH_DI,
	output wire FLASH_SCK,
	output wire FLASH_WP_N,
	output wire FLASH_HOLD_N
);

// ------------------------------------------------------------------ unused

assign WA = 3'b000;
assign WCS_N = 2'b11;
assign WRD_N = 1'b1;
assign WWR_N = 1'b1;
assign WRESET_N = 1'b1;
assign WD = 16'bz;

assign ESP_RESET_N = 1'bz;
assign ESP_BOOT_N = 1'bz;
assign UART_RX = 1'bz;
assign UART_TX = 1'bz;
assign UART_CTS = 1'bz;

assign TAPE_OUT = 1'b0;
assign FT_OE_N = 1'b1;     // the FT812 does not drive the video DAC
assign BEEPER = 1'b0;
assign DAC_MUTE = 1'b1;    // soft mute of the PCM5102: 1 = sound on

// the floppy connector is not used: its outputs 0 (the board inverts them: high = active)
assign FDC_DRIVE = 2'b00;
assign FDC_MOTOR = 1'b0;
assign FDC_DIR = 1'b0;
assign FDC_STEP = 1'b0;
assign FDC_WDATA = 1'b0;
assign FDC_WGATE = 1'b0;
assign FDC_SIDE_N = 1'b0;
assign MIDI_TX = 1'b1;
assign MIDI_CLK = 1'b0;      // the SAM2695 is not used: in reset
assign MIDI_RESET_N = 1'b0;

// the flash chip (the SDRAM /CS is hard wired on Go): not selected
assign FLASH_CS_N = 1'b1;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;


// ------------------------------------------------------------------ clocks

wire [5:0] pll_clk;
wire pll_locked;
kg_pll #(
	.CLKIN_PERIOD(20.0),
	.CLKFBOUT_MULT(15),      // VCO 750 MHz
	.CLKOUT0_DIVIDE(10),     // clk_sys 75 MHz
	.CLKOUT1_DIVIDE(10),     // clk_sdr 75 MHz, 225 degrees
	.CLKOUT1_PHASE(225.0),
	.CLKOUT2_DIVIDE(30),     // clk_pix 25 MHz
	.CLKOUT3_DIVIDE(6),      // clk_hdmi 125 MHz
	.CLKOUT4_DIVIDE(6),      // clk_hdmi_n 125 MHz, 180 degrees
	.CLKOUT4_PHASE(180.0),
	.CLKOUT5_DIVIDE(22)      // clk_ez 34.09 MHz
) pll (
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked(pll_locked)
);
wire clk_sys = pll_clk[0];
wire clk_sdr = pll_clk[1];
wire clk_pix = pll_clk[2];
wire clk_hdmi = pll_clk[3];
wire clk_hdmi_n = pll_clk[4];
wire clk_ez = pll_clk[5];

(* KEEP = "TRUE" *) wire areset_async = ~pll_locked;
wire areset, areset_pix, areset_ez;
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_areset (.clk(clk_sys), .d(areset_async), .q(areset));
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_areset_pix (.clk(clk_pix), .d(areset_async), .q(areset_pix));
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_areset_ez (.clk(clk_ez), .d(areset_async), .q(areset_ez));

// FT_CLK_OUT: clk_ez / 4 (the FT812 needs a clock on Mini G, always)
reg [1:0] ft_div = 2'd0;
always @(posedge clk_ez) ft_div <= ft_div + 2'd1;
// the pixel clock of the VGA DAC (no FT_CLK_OUT on Go: the FT812 has its crystal)
ODDR2 oddr_v_clk (.Q(V_CLK), .C0(clk_pix), .C1(~clk_pix), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));
ODDR2 oddr_sdr_clk (.Q(SDR_CLK), .C0(clk_sdr), .C1(~clk_sdr), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

// ------------------------------------------------------------------ MCU

// MCU_SCK is not on a clock pin before rev.G (CLOCK_DEDICATED_ROUTE = FALSE in the ucf)
wire mcu_sck = MCU_SCK, mcu_sck_ibufg = MCU_SCK;

wire mcu_int;
assign MCU_SPI_IO[0] = mcu_int;   // INT of link v2 on N9 (IO1 of the firmware)
assign MCU_SPI_IO[1] = 1'bz;

wire [55:0] kbd;
wire [7:0] ps2_code;
wire ps2_kind, ps2_wr;
wire kbd_wr;
wire [15:0] joy_l, joy_r;
wire [7:0] ms_x, ms_y, ms_z, ms_b;
wire ms_wr;
wire [23:0] matrix_cmd;
wire matrix_cmd_wr;
wire [1:0] ld_kind;
wire [7:0] ld_slot, ld_data;
wire [31:0] ld_addr;
wire ld_start, ld_active, ld_end, ld_wr, ld_ready;
wire [8*1-1:0] sw;
wire [7:0] sdc_img_mounted, sdc_rd, sdc_wr, sdc_byte_in_data, sdc_byte_out_data, img_flush, bk_kind, bk_result;
wire [63:0] sdc_img_size;
wire [31:0] sdc_sector, bk_size;
wire sdc_busy, sdc_done, sdc_error, sdc_byte_in_strobe, bk_mount, bk_flushed;
wire [2:0] sdc_slot;
wire [8:0] sdc_byte_addr;
wire dvi_only;
wire ft_cs_n, ft_mosi, ft_spi_on;
wire [15:0] dbg_addr;
reg [15:0] dbg_data = 16'd0;
wire osd_wr, osd_en, osd_zoom;
wire [11:0] osd_waddr;
wire [7:0] osd_wdata;
wire [23:0] osd_fg, osd_bg;
wire [1:0] osd_alpha, osd_place;
wire [4:0] osd_px, osd_ph;
wire [3:0] osd_py;
wire [5:0] osd_pw;

kg_mcu2 #(
	.SW_N(1),
	.CS_FILTER(3),
	.CAPS(16'h0010),     // bit 4: the core drives LD_READY
	.ENABLE_OSD(1),
	.ENABLE_IMG(0),
	.ENABLE_AUX(1),      // DEBUG_*: the state of the core (AT+KARABAS=debug:1, kg_board.py log)
	.ENABLE_FT(1),
	.ENABLE_SD2(0)       // SD2 is the card of MOS: the eZ80 SPI drives it
) mcu (
	.CLK(clk_sys),
	.N_RESET(~areset),

	.MCU_SCK(mcu_sck),
	.MCU_MOSI(MCU_MOSI),
	.MCU_MISO(MCU_MISO),
	.MCU_SS(MCU_CS_N),
	.MCU_INT(mcu_int),
	.MCU_SPI_FT_SS(MCU_SPI_FT_CS_N),
	.MCU_SPI_SD2_SS(MCU_SPI_SD2_CS_N),

	.SW(sw), .SW_WR(), .SW_INDEX(), .SW_VALUE(), .HW_ID(), .DVI_ONLY(dvi_only), .CORE_BUILD(), .FW_BUILD(),
	.BUSY(), .BTNS(), .RELOAD_REQ(1'b0), .RELOAD_CORE(8'd0),

	.KBD(kbd), .KBD_WR(kbd_wr),
	.PS2_CODE(ps2_code), .PS2_KIND(ps2_kind), .PS2_WR(ps2_wr),
	.MS_X(ms_x), .MS_Y(ms_y), .MS_Z(ms_z), .MS_B(ms_b), .MS_WR(ms_wr),
	.JOY_L(joy_l), .JOY_R(joy_r), .JOY_WR(),
	.PS2_CMD(16'h0000), .PS2_CMD_WR(1'b0),

	.LD_KIND(ld_kind), .LD_SLOT(ld_slot), .LD_SIZE(), .LD_EXT(), .LD_START(ld_start), .LD_ACTIVE(ld_active), .LD_END(ld_end),
	.LD_ADDR(ld_addr), .LD_DATA(ld_data), .LD_WR(ld_wr), .LD_READY(ld_ready),

	.OSD_WR(osd_wr), .OSD_WADDR(osd_waddr), .OSD_WDATA(osd_wdata), .OSD_EN(osd_en),
	.OSD_FG(osd_fg), .OSD_BG(osd_bg), .OSD_ALPHA(osd_alpha), .OSD_PX(osd_px), .OSD_PY(osd_py),
	.OSD_PW(osd_pw), .OSD_PH(osd_ph), .OSD_PLACE(osd_place), .OSD_ZOOM(osd_zoom),

	.SDC_IMG_MOUNTED(sdc_img_mounted), .SDC_IMG_SIZE(sdc_img_size), .SDC_RD(sdc_rd), .SDC_WR(sdc_wr),
	.SDC_SECTOR(sdc_sector), .SDC_BUSY(sdc_busy), .SDC_DONE(sdc_done), .SDC_ERROR(sdc_error), .SDC_SLOT(sdc_slot),
	.SDC_BYTE_IN_STROBE(sdc_byte_in_strobe), .SDC_BYTE_ADDR(sdc_byte_addr), .SDC_BYTE_IN_DATA(sdc_byte_in_data),
	.SDC_BYTE_OUT_DATA(sdc_byte_out_data), .IMG_WP(), .IMG_PHYS_WR(), .IMG_PHYS(), .IMG_FLUSH(img_flush), .FDD_CHNG_WR(), .FDD_CHNG(),
	.BK_MOUNT(bk_mount), .BK_FLUSHED(bk_flushed), .BK_SLOT(3'd1), .BK_SIZE(bk_size), .BK_KIND(bk_kind), .BK_RESULT(bk_result),
	.FDD_CHNG_REQ(1'b0), .FDD_CHNG_DS(2'd0), .IMG_ACTIVE(),
	.PORT_OUT_DATA(), .PORT_OUT_WR(), .PORT_OUT_READY(4'b1111), .PORT_IN_DATA(32'd0), .PORT_IN_WR(4'd0),
	.PORT_CFG(128'd0), .PORT_IN_FULL(), .PORT_STAT(), .PORT_STAT_WR(),
	.RTC_A(8'd0), .RTC_DI(8'd0), .RTC_CS(1'b0), .RTC_WR_N(1'b1), .MATRIX_CMD(matrix_cmd), .MATRIX_CMD_WR(matrix_cmd_wr),
	.DEBUG_ADDR(dbg_addr), .DEBUG_DATA(dbg_data), .RTC_DO(),

	.FT_SPI_ON(ft_spi_on), .FT_VGA_ON(), .FT_RESET(), .FT_SCK(), .FT_MOSI(ft_mosi), .FT_MISO(FT_SPI_MISO),
	.FT_CS_N(ft_cs_n),
	.SD2_SCK(), .SD2_MOSI(), .SD2_MISO(1'b1), .SD2_CS_N()
);

assign FT_SPI_CS_N = ft_spi_on ? ft_cs_n : 1'b1;
assign FT_SPI_SCK = ft_spi_on ? mcu_sck_ibufg : 1'b1;
assign FT_SPI_MOSI = ft_spi_on ? ft_mosi : 1'b1;

wire sw_reset = sw[0];                // OSD Reset (item index 0)


// (no image / backup RAM: their inputs of kg_mcu2 idle)
assign sdc_busy = 1'b0;
assign sdc_done = 1'b0;
assign sdc_error = 1'b0;
assign sdc_byte_out_data = 8'd0;
assign bk_flushed = 1'b0;

// ------------------------------------------------------------------ the loader

// the .kg ROMs: below 0x1000000 MOS (the SRAM flash area), from there the VDP firmware (SDRAM 0)
wire ld_rom = ld_kind == 2'd0;
wire ld_hi = ld_addr[24];
wire sr_busy, vdp_ld_ready;
assign ld_ready = ~sr_busy & vdp_ld_ready;

// ------------------------------------------------------------------ the eZ80 machine

reg [15:0] nco = 16'd0;                  // the F92 system clock: 18.432 / 34.09 of the clocks
reg sys_ce = 1'b0;
always @(posedge clk_ez) { sys_ce, nco } <= { 1'b0, nco } + 17'd35434;
wire ez_hold;
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_ez_hold (.clk(clk_ez), .d(areset | ld_active | sw_reset), .q(ez_hold));
reg ez_reset_n = 1'b0;
wire [127:0] ez_regx;
wire ez_halt_n;
reg [31:0] dbg_ez = 32'd0;                 // the VDP debug overlay (Ctrl+Alt+D): eZ80 state
always @(posedge clk_ez) dbg_ez <= { ez_reset_n, ez_halt_n, 6'd0, ez_regx[23:0] };
always @(posedge clk_ez) ez_reset_n <= ~(areset_ez | ez_hold);

wire [23:0] maddr;
wire mrd, mwr, sel_ram, sel_flash, sel_ext;
wire [7:0] mdo, mem_di;
wire [16:0] flash_ofs;
wire [7:0] u0_tx_data, u0_rx_data;
wire u0_tx_valid, u0_tx_ready, u0_rx_valid, u0_rx_full, u0_cts, ez_vblank;
wire ez_sd_sck, ez_sd_mosi, ez_sd_cs_n;

agon_ez80 ez (
	.clk(clk_ez), .reset_n(ez_reset_n), .sys_ce(sys_ce),
	.maddr(maddr), .mrd(mrd), .mwr(mwr), .mdo(mdo), .mem_di(mem_di),
	.sel_ram(sel_ram), .sel_flash(sel_flash), .flash_ofs(flash_ofs), .sel_ext(sel_ext),
	.u0_tx_data(u0_tx_data), .u0_tx_valid(u0_tx_valid), .u0_tx_ready(u0_tx_ready),
	.u0_rx_data(u0_rx_data), .u0_rx_valid(u0_rx_valid), .u0_rx_full(u0_rx_full), .u0_cts(u0_cts),
	.sd_sck(ez_sd_sck), .sd_mosi(ez_sd_mosi), .sd_miso(SD_DO), .sd_cs_n(ez_sd_cs_n), .vsync(ez_vblank),
	.insn(), .regx(ez_regx), .regs(), .halt_n(ez_halt_n), .dbg_io_rd(), .dbg_io_wr(), .dbg_io_d()
);
assign SD_CS_N = ez_sd_cs_n;
assign SD_CLK = ez_sd_sck;
assign SD_DI = ez_sd_mosi;

wire [15:0] md_o, md_oe_n;
agon_sram sram (
	.maddr(maddr), .mrd(mrd), .mwr(mwr), .mdo(mdo), .sel_ram(sel_ram), .sel_flash(sel_flash),
	.flash_ofs(flash_ofs), .sel_ext(sel_ext), .mem_di(mem_di),
	.clk_sys(clk_sys), .ld_own(ld_active), .ld_wr(ld_wr & ld_rom & ~ld_hi), .ld_addr(ld_addr[16:0]),
	.ld_data(ld_data), .ld_busy(sr_busy),
	.MA(MA), .MD_I(MD), .MD_O(md_o), .MD_OE_N(md_oe_n), .MWR_N(MWR_N), .MRD_N(MRD_N)
);

// ------------------------------------------------------------------ the link

wire [7:0] v_rx_data, v_tx_data;
wire v_rx_valid, v_cts, v_tx_valid, v_tx_ready, v_vblank;
agon_link link (.clk_ez(clk_ez), .clk_vdp(clk_sys),
	.ez_tx_data(u0_tx_data), .ez_tx_valid(u0_tx_valid), .ez_tx_ready(u0_tx_ready),
	.ez_rx_data(u0_rx_data), .ez_rx_valid(u0_rx_valid), .ez_rx_full(u0_rx_full), .ez_cts(u0_cts),
	.ez_vblank(ez_vblank),
	.vdp_rx_data(v_rx_data), .vdp_rx_valid(v_rx_valid), .vdp_cts(v_cts),
	.vdp_tx_data(v_tx_data), .vdp_tx_valid(v_tx_valid), .vdp_tx_ready(v_tx_ready), .vdp_vblank(v_vblank));

// ------------------------------------------------------------------ the VDP machine

wire [15:0] sdr_dq_o, sdr_dq_oe_n;
genvar gi;
generate
	for (gi = 0; gi < 16; gi = gi + 1) begin : g_io
		assign SDR_DQ[gi] = sdr_dq_oe_n[gi] ? 1'bz : sdr_dq_o[gi];
		assign MD[gi] = md_oe_n[gi] ? 1'bz : md_o[gi];
	end
endgenerate

// 16384 Hz for the audio FIFO: + 16384 per clock of 75 MHz modulo 75000000
reg [26:0] aud_acc = 27'd0;
reg aud_ce = 1'b0;
always @(posedge clk_sys) begin
	aud_ce <= 1'b0;
	if (aud_acc >= 27'd75000000 - 27'd16384) begin aud_acc <= aud_acc + 27'd16384 - 27'd75000000; aud_ce <= 1'b1; end
	else aud_acc <= aud_acc + 27'd16384;
end

wire [1:0] vid_r, vid_g, vid_b;
wire vid_hs, vid_vs, vid_de, vdp_run;
wire [7:0] vdp_con, aud_out;
wire [8:0] vdp_exit;
wire vdp_con_wr;
vdp_soc vdp (
	.clk(clk_sys), .reset(areset | sw_reset),
	.ld_active(ld_active & ld_rom), .ld_addr(ld_addr[24:0] - 25'h1000000), .ld_data(ld_data),
	.ld_wr(ld_wr & ld_rom & ld_hi), .ld_ready(vdp_ld_ready),
	.ez_rx_data(v_rx_data), .ez_rx_valid(v_rx_valid), .ez_cts(v_cts),
	.ez_tx_data(v_tx_data), .ez_tx_valid(v_tx_valid), .ez_tx_ready(v_tx_ready),
	.clk_pix(clk_pix), .vid_r(vid_r), .vid_g(vid_g), .vid_b(vid_b), .vid_hs(vid_hs), .vid_vs(vid_vs),
	.vid_de(vid_de), .vblank(v_vblank),
	.ps2_code(ps2_code), .ps2_wr(ps2_wr & ~ps2_kind),
	.ms_x(ms_x), .ms_y(ms_y), .ms_z(ms_z), .ms_b(ms_b), .ms_wr(ms_wr), .dbg_ez(dbg_ez),
	.aud_ce(aud_ce), .aud_out(aud_out), .sim_shot_req(1'b0), .sim_req(1'b0), .sim_shot_wr(), .sim_shot(),
	.dbg_con_wr(vdp_con_wr), .dbg_con(vdp_con), .dbg_exit(vdp_exit), .dbg_mark_wr(), .dbg_mark(),
	.cpu_run(vdp_run), .dbg_rx_poll(), .dbg_iadr(), .dbg_io(), .dbg_bus(),
	.sdr_a(SDR_A), .sdr_ba(SDR_BA), .sdr_dq_i(SDR_DQ), .sdr_dq_o(sdr_dq_o), .sdr_dq_oe_n(sdr_dq_oe_n),
	.sdr_dqm(SDR_DQM), .sdr_ras_n(SDR_RAS_N), .sdr_cas_n(SDR_CAS_N), .sdr_we_n(SDR_WE_N)
);

// ------------------------------------------------------------------ video: OSD, HDMI

wire [23:0] vid_rgb = { vid_r, vid_r, vid_r, vid_r, vid_g, vid_g, vid_g, vid_g, vid_b, vid_b, vid_b, vid_b };
wire [23:0] osd_rgb;
wire osd_hs, osd_vs, osd_de;
kg_l2_osd_overlay osd (
	.wclk(clk_sys),
	.osd_wr(osd_wr), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata), .osd_en(osd_en),
	.osd_fg(osd_fg), .osd_bg(osd_bg), .osd_alpha(osd_alpha), .osd_px(osd_px), .osd_py(osd_py),
	.osd_pw(osd_pw), .osd_ph(osd_ph), .osd_place(osd_place), .osd_zoom(osd_zoom),
	.icon_on(8'd0), .icon_act(8'd0),
	.clk(clk_pix),
	.rgb_i(vid_rgb), .hs_i(vid_hs), .vs_i(vid_vs), .de_i(vid_de),
	.rgb_o(osd_rgb), .hs_o(osd_hs), .vs_o(osd_vs), .de_o(osd_de)
);

// the sound: the VDP samples (8-bit unsigned, 16384 Hz, vdp-gl SoundGenerator) to the PCM5102 and the
// HDMI audio (mono on both channels). aud_out changes at the aud_ce clock (clk_sys) and holds ~4500
// clocks: a toggle per sample crosses to clk_pix, the sample is taken when it arrives.
reg aud_tg = 1'b0;
always @(posedge clk_sys) if (aud_ce) aud_tg <= ~aud_tg;
reg [2:0] aud_tg_p = 3'd0;
reg [15:0] snd = 16'd0;
always @(posedge clk_pix) begin
	aud_tg_p <= { aud_tg_p[1:0], aud_tg };
	if (aud_tg_p[2] ^ aud_tg_p[1]) snd <= { ~aud_out[7], aud_out[6:0], 8'h00 };
end
// the level meters of the mcu (dot matrix): the peaks of the samples (clk_sys, as kg_mcu2)
wire [15:0] snd_sys = { ~aud_out[7], aud_out[6:0], 8'h00 };
audio_peaks #(.PERIOD_BITS(20)) peaks (.clk(clk_sys), .audio_l(snd_sys), .audio_r(snd_sys),
	.cmd_wr(matrix_cmd_wr), .cmd(matrix_cmd));
kg_pcm5102 #(.DIV_BITS(2)) dac (.clk(clk_pix), .reset(areset_pix), .left(snd), .right(snd),
	.din(DAC_DAT), .bck(DAC_BCK), .lrck(DAC_LRCK));
// ------------------------------------------------------------------ VGA

// 640 x 480 at 60 Hz: negative syncs as on HDMI, black outside de (the DAC has no blank input); the
// OSD output is registered with them
reg vga_hs = 1'b1, vga_vs = 1'b1;
reg [23:0] vga_rgb = 24'd0;
always @(posedge clk_pix) begin
	vga_hs <= ~osd_hs;
	vga_vs <= ~osd_vs;
	vga_rgb <= osd_de ? osd_rgb : 24'd0;
end
assign VGA_R = vga_rgb[23:16];
assign VGA_G = vga_rgb[15:8];
assign VGA_B = vga_rgb[7:0];
assign VGA_HS = vga_hs;
assign VGA_VS = vga_vs;

// ------------------------------------------------------------------ debug (AT+KARABAS=debug:1)

// DEBUG_ADDR: { vdp_run, VDP exited, 6'd0, the last console byte of the VDP };
// DEBUG_DATA: { ez_reset_n, eZ80 bytes to the VDP (low 7 bits), VDP bytes to the eZ80 }
reg [6:0] n_ez = 7'd0;
reg [7:0] n_vdp = 8'd0;
always @(posedge clk_ez) if (u0_tx_valid & u0_tx_ready) n_ez <= n_ez + 7'd1;
always @(posedge clk_sys) if (v_tx_valid & v_tx_ready) n_vdp <= n_vdp + 8'd1;
reg [7:0] con_last = 8'd0;
always @(posedge clk_sys) if (vdp_con_wr) con_last <= vdp_con;
assign dbg_addr = { vdp_run, vdp_exit[8], 6'd0, con_last };
always @(posedge clk_sys) dbg_data <= { ez_reset_n, n_ez, n_vdp };

endmodule
