`timescale 1ns / 1ps
`default_nettype wire

/*
 Agon Light / Console8 core for Karabas Mini before rev.G (HDMI, sigma-delta audio). Made by
 tools/mktops.py from karabas_minig_top.v (do not edit: change that one and run it): the same
 except the pins, the MCU link (MCU_SCK not on a clock pin) and the audio (AUDIO_L / AUDIO_R).
 The eZ80F92 machine (agon_ez80: the eZ80
 core on T80 + the F92 periphery, MOS from the .kg) and the VDP machine (vdp_soc: VexRiscv + the
 Console8 VDP firmware from the .kg + the scanout), joined by agon_link (docs/PLAN.md Ф1).

 Clocks: one PLL, VCO 750 MHz (50 * 15): clk_sys 75 MHz (the VDP, the MCU link, the sound), clk_sdr 75 MHz at
 225 degrees (SDR_CLK through an ODDR2), clk_pix of the video mode (agon_vclk, Ф2: 25 MHz of the PLL for
 640x480@60 / 640x400@70, DCM_CLKGEN 40 / 65 MHz for 800x600@60 / 1024x768@60; the OSD, HDMI) with
 clk_hdmi / clk_hdmi_n x5 from a DCM, clk_ez 34.09 MHz (the eZ80; 37.5 left no timing margin: user 2026-11-19; the F92 system clock 18.432 MHz as a
 clock enable from it); FT_CLK_OUT = clk_ez / 4 (8.5 MHz).
 Memory: the eZ80 in the SRAM (agon_sram: MOS, 512 KB, the on-chip 8 KB), the VDP in the SDRAM.
 The .kg ROMs: MOS at 0 (-> the SRAM flash area), the VDP firmware at 0x1000000 (-> SDRAM 0).
 SD2 = the SD card of MOS, driven by the eZ80 SPI (PB4 = /CS).
 The keyboard: the PS/2 set 2 bytes of kg_mcu2 to the VDP (MMIO KBD, the firmware injects them into
 vdp-gl), the mouse (MS_* -> vdp_soc MOUSE -> vdp-gl). The sound: VDP samples -> PCM5102 + HDMI audio.

 Soft switches (the index of the item in the osd of core.json): 0 Reset.
*/

module karabas_mini_top (
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

	input wire [7:0] VGA_R,
	input wire [7:0] VGA_G,
	input wire [7:0] VGA_B,
	input wire VGA_HS,
	input wire VGA_VS,

	output wire [3:0] TMDS_P,
	output wire [3:0] TMDS_N,

	output wire FT_SPI_CS_N,
	output wire FT_SPI_SCK,
	input wire FT_SPI_MISO,
	output wire FT_SPI_MOSI,
	input wire FT_INT_N,
	input wire FT_CLK,
	input wire FT_DE,
	input wire FT_AUDIO,
	input wire FT_DISP,
	output wire FT_RESET,
	output wire FT_CLK_OUT,

	output wire [2:0] WA,
	output wire [1:0] WCS_N,
	output wire WRD_N,
	output wire WWR_N,
	output wire WRESET_N,
	inout wire [15:0] WD,

	output wire TAPE_OUT,
	input wire TAPE_IN,

	output wire AUDIO_L,
	output wire AUDIO_R,

	output wire ADC_CLK,
	inout wire ADC_BCK,
	inout wire ADC_LRCK,
	input wire ADC_DOUT,

	input wire MCU_CS_N,
	input wire MCU_SCK,
	inout wire MCU_MOSI,
	output wire MCU_MISO,
	inout wire [3:0] MCU_IO, // [1] INT of link v2, [2] sd2 cs_n, [3] ft cs_n

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
// the ESP8266 on UART1 of the eZ80 (8N1 at the MOS rate; CTS to the module from the receive buffer)
wire u1_txd, u1_cts_n;
assign UART_RX = 1'bz;
assign UART_TX = u1_txd;
assign UART_CTS = u1_cts_n;

assign TAPE_OUT = 1'b0;
assign FT_RESET = 1'b1;
assign MIDI_TX = 1'b1;
assign MIDI_CLK = 1'b0;      // the SAM2695 is not used: in reset
assign MIDI_RESET_N = 1'b0;

// FLASH_CS_N (T3) is the SDRAM /CS of Mini G2 (rev G: tied low on the board): always selected
assign FLASH_CS_N = 1'b0;
assign FLASH_DI = 1'b1;
assign FLASH_SCK = 1'b0;
assign FLASH_WP_N = 1'b1;
assign FLASH_HOLD_N = 1'b1;

assign ADC_CLK = 1'b0;
assign ADC_BCK = 1'bz;
assign ADC_LRCK = 1'bz;

// ------------------------------------------------------------------ clocks

wire [5:0] pll_clk;
wire pll_locked;
kg_pll #(
	.CLKIN_PERIOD(20.0),
	.CLKFBOUT_MULT(15),      // VCO 750 MHz
	.CLKOUT0_DIVIDE(10),     // clk_sys 75 MHz
	.CLKOUT1_DIVIDE(10),     // clk_sdr 75 MHz, 225 degrees
	.CLKOUT1_PHASE(225.0),
	.CLKOUT2_DIVIDE(30),     // 25 MHz (no BUFG: the BUFGMUX of agon_vclk) -> clk_pix of the 25 MHz modes
	.CLKOUT3_DIVIDE(6),      // (not used since Ф2: the serial clocks come from agon_vclk)
	.CLKOUT4_DIVIDE(6),
	.CLKOUT4_PHASE(180.0),
	.CLKOUT5_DIVIDE(22),     // clk_ez 34.09 MHz
	.BUFG_MASK(6'b100011)
) pll (
	.clk_in(CLK_50MHZ),
	.rst(1'b0),
	.clk_out(pll_clk),
	.locked(pll_locked)
);
wire clk_sys = pll_clk[0];
wire clk_sdr = pll_clk[1];
wire clk_ez = pll_clk[5];
// the pixel clock of the output timing the VDP asks for (Ф2): 25 / 40 / 65 MHz (agon_vclk)
wire clk_pix, clk_hdmi, clk_hdmi_n, vclk_locked;
wire [1:0] vid_omode, vid_pmode_sys, vid_pmode;
agon_vclk #(.HDMI(1)) vclk (.clk_sys(clk_sys), .reset(~pll_locked), .clk_25(pll_clk[2]), .omode(vid_omode),
	.pmode(vid_pmode_sys), .clk_pix(clk_pix), .clk_hdmi(clk_hdmi), .clk_hdmi_n(clk_hdmi_n), .locked(vclk_locked));
kg_sync #(.W(2), .STAGES(2)) sync_pmode (.clk(clk_pix), .d(vid_pmode_sys), .q(vid_pmode));

(* KEEP = "TRUE" *) wire areset_async = ~pll_locked;
wire areset, areset_pix, areset_ez;
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_areset (.clk(clk_sys), .d(areset_async), .q(areset));
(* KEEP = "TRUE" *) wire areset_pix_async = ~pll_locked | ~vclk_locked;
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_areset_pix (.clk(clk_pix), .d(areset_pix_async), .q(areset_pix));
kg_sync #(.W(1), .STAGES(2), .INIT(1'b1)) sync_areset_ez (.clk(clk_ez), .d(areset_async), .q(areset_ez));

// FT_CLK_OUT: clk_ez / 4 (the FT812 needs a clock on Mini G, always)
reg [1:0] ft_div = 2'd0;
always @(posedge clk_ez) ft_div <= ft_div + 2'd1;
assign FT_CLK_OUT = ft_div[1];
ODDR2 oddr_sdr_clk (.Q(SDR_CLK), .C0(clk_sdr), .C1(~clk_sdr), .CE(1'b1), .D0(1'b1), .D1(1'b0), .R(1'b0), .S(1'b0));

// ------------------------------------------------------------------ MCU

// MCU_SCK is not on a clock pin before rev.G (CLOCK_DEDICATED_ROUTE = FALSE in the ucf)
wire mcu_sck = MCU_SCK, mcu_sck_ibufg = MCU_SCK;

wire mcu_int;
assign MCU_IO[1] = mcu_int;
assign MCU_IO[0] = 1'bz;
assign MCU_IO[3:2] = 2'bzz;

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
	.MCU_SPI_FT_SS(MCU_IO[3]),
	.MCU_SPI_SD2_SS(MCU_IO[2]),

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
// the VDP debug overlay (Ctrl+Alt+D) eZ80 state word: off since Ф2 (LUTs for UART1 / joysticks on the
// Mini G, user 2026-11-19); the overlay shows 0 there
wire [31:0] dbg_ez = 32'd0;
always @(posedge clk_ez) ez_reset_n <= ~(areset_ez | ez_hold);

wire [23:0] maddr;
wire mrd, mwr, sel_ram, sel_flash, sel_ext;
wire [7:0] mdo, mem_di;
wire [16:0] flash_ofs;
wire [7:0] u0_tx_data, u0_rx_data;
wire u0_tx_valid, u0_tx_ready, u0_rx_valid, u0_rx_full, u0_cts, ez_vblank;
wire ez_sd_sck, ez_sd_mosi, ez_sd_cs_n;

// joysticks to GPIO C / D as the Console8 (agon_ez80.v): kg_mcu2 bits 1 up, 2 down, 3 left, 4 right,
// 6 A = fire 1, 7 B = fire 2 (active 1) -> pins active 0; JOY_L = joystick 1, JOY_R = joystick 2
wire [11:0] joy_ez;
kg_sync #(.W(12), .STAGES(2), .INIT(12'hfff)) sync_joy (.clk(clk_ez),
	.d(~{ joy_l[4], joy_r[4], joy_l[3], joy_r[3], joy_l[2], joy_r[2], joy_l[1], joy_r[1],
	      joy_l[7], joy_r[7], joy_l[6], joy_r[6] }), .q(joy_ez));

agon_ez80 ez (
	.clk(clk_ez), .reset_n(ez_reset_n), .sys_ce(sys_ce),
	.maddr(maddr), .mrd(mrd), .mwr(mwr), .mdo(mdo), .mem_di(mem_di),
	.sel_ram(sel_ram), .sel_flash(sel_flash), .flash_ofs(flash_ofs), .sel_ext(sel_ext),
	.u0_tx_data(u0_tx_data), .u0_tx_valid(u0_tx_valid), .u0_tx_ready(u0_tx_ready),
	.u0_rx_data(u0_rx_data), .u0_rx_valid(u0_rx_valid), .u0_rx_full(u0_rx_full), .u0_cts(u0_cts),
	.sd_sck(ez_sd_sck), .sd_mosi(ez_sd_mosi), .sd_miso(SD_DO), .sd_cs_n(ez_sd_cs_n), .vsync(ez_vblank),
	.joy_pc(joy_ez[11:4]), .joy_pd(joy_ez[3:0]), .u1_rxd(UART_RX), .u1_txd(u1_txd), .u1_cts_n(u1_cts_n),
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
wire vid_hneg, vid_vneg;                    // the sync polarities of vid_pmode (clk_pix)
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
	.vid_de(vid_de), .vid_omode(vid_omode), .vid_pmode(vid_pmode), .vid_hneg(vid_hneg), .vid_vneg(vid_vneg),
	.vblank(v_vblank),
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
// HDMI audio (mono on both channels), in clk_sys (Ф2: clk_pix follows the video mode)
wire [15:0] snd_sys = { ~aud_out[7], aud_out[6:0], 8'h00 };
// the level meters of the mcu (dot matrix): the peaks of the samples (clk_sys, as kg_mcu2)
audio_peaks #(.PERIOD_BITS(20)) peaks (.clk(clk_sys), .audio_l(snd_sys), .audio_r(snd_sys),
	.cmd_wr(matrix_cmd_wr), .cmd(matrix_cmd));
// no I2S DAC on this board: sigma-delta outputs into an RC filter (offset binary)
kg_sigma_delta_dac dac_l (.clk(clk_sys), .reset(areset), .din(snd_sys ^ 16'h8000), .dout(AUDIO_L));
kg_sigma_delta_dac dac_r (.clk(clk_sys), .reset(areset), .din(snd_sys ^ 16'h8000), .dout(AUDIO_R));

// ------------------------------------------------------------------ HDMI

// the HDMI audio samples at 48 kHz: taken in clk_sys (75 MHz x 16 / 25000), a toggle to clk_pix; the
// data holds 1562 clk_sys clocks, the pixel side takes it when the toggle arrives (as kg_hdmi_ft);
// hdmi_tx measures the CTS from the pixel clock, so any mode works
reg [14:0] hacc = 15'd0;
reg h_tg = 1'b0;
reg [15:0] h_smp = 16'd0;
always @(posedge clk_sys) begin
	if (hacc >= 15'd24984) begin hacc <= hacc + 15'd16 - 15'd25000; h_tg <= ~h_tg; h_smp <= snd_sys; end
	else hacc <= hacc + 15'd16;
end
reg [2:0] h_tg_p = 3'd0;
reg aud_stb = 1'b0;
reg [15:0] snd = 16'd0;
always @(posedge clk_pix) begin
	h_tg_p <= { h_tg_p[1:0], h_tg };
	aud_stb <= h_tg_p[2] ^ h_tg_p[1];
	if (h_tg_p[2] ^ h_tg_p[1]) snd <= h_smp;
end

reg dvi_only_p = 1'b0;
always @(posedge clk_pix) dvi_only_p <= dvi_only;
reg hdmi_hs = 1'b1, hdmi_vs = 1'b1, hdmi_de = 1'b0;
reg [23:0] hdmi_rgb = 24'd0;
always @(posedge clk_pix) begin
	hdmi_hs <= osd_hs ^ vid_hneg;
	hdmi_vs <= osd_vs ^ vid_vneg;
	hdmi_de <= osd_de;
	hdmi_rgb <= osd_rgb;
end
hdmi_tx #(.SAMPLE_FREQ(48000)) hdmi (
	.clk(clk_pix), .sclk(clk_hdmi), .sclk_n(clk_hdmi_n), .reset(areset_pix),
	.rgb(hdmi_rgb), .vsync(hdmi_vs), .hsync(hdmi_hs), .de(hdmi_de),
	.audio_en(~dvi_only_p), .audio_l({ snd, 8'h00 }), .audio_r({ snd, 8'h00 }), .audio_clk(aud_stb),
	.tx_clk_n(TMDS_N[3]), .tx_clk_p(TMDS_P[3]), .tx_d_n(TMDS_N[2:0]), .tx_d_p(TMDS_P[2:0])
);

// ------------------------------------------------------------------ debug (AT+KARABAS=debug:1)

// DEBUG_ADDR: { vdp_run, VDP exited, 6'd0, the last console byte of the VDP };
// DEBUG_DATA: { ez_reset_n, 15'd0 } (the link byte counters are off since Ф2: LUTs)
reg [7:0] con_last = 8'd0;
always @(posedge clk_sys) if (vdp_con_wr) con_last <= vdp_con;
assign dbg_addr = { vdp_run, vdp_exit[8], 6'd0, con_last };
always @(posedge clk_sys) dbg_data <= { ez_reset_n, 15'd0 };

endmodule
