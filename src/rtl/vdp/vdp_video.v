`timescale 1ns / 1ps
`default_nettype none
/*
 vdp_video.v (karabas, Ф1.4)

 The scanout of the VDP: the frame the firmware describes (src/vdp/kg_scanout.cpp, MMIO_SCAN) shown on
 one 640x480@60 output (800 x 525, clk_pix 25 MHz; user decision 2026-11-18): a source 320 wide or
 240 high is doubled that way, a smaller picture is centred, a bigger one cropped (top left).

 clk side (the VDP SoC clock): at the start of the vertical blank (row 480) the description at
 scan_adr is read (5 words); before each output row that starts a new source line, that line is
 made in line buffer (line & 1): its row address (d[2] + 4 y), its palette (d[3] byte y; the 16
 bytes of d[4] + 16 p when p changes), its bytes (32-byte bursts from the 32-byte line of the row
 address, into the raw buffer), then the pixels decoded (formats of kg_scanout.cpp) into RGB222.
 Then the sprites of the line (d[5], read into a table of 32 at the frame start; kg_scanout.cpp:
 the text cursor, hardware sprites, the mouse cursor, as vdp-gl drawSpriteScanLine): for each one
 on the line its pixels (RGBA2222 / RGBA8888, 32-byte bursts into raw[]) over the line buffer where
 alpha is not 0 (RGBA2222 XOR: the colour XORed into it); the firmware clips the entries to the
 picture (RGBA8888 rows to 256 pixels). A new line to make stops the sprites (the rest of them lost
 on that line: a late line would be worse).
 Memory port: a wishbone master as the VexRiscv buses (CTI 010 = more words of the burst).
 clk_pix side: the counters, the line buffer read (with the doubling), the syncs (high active),
 de. The geometry is quasi static: made in the vertical blank, read in the picture.
*/
module vdp_video (
	input wire clk,
	input wire reset,
	input wire [31:0] scan_adr,         // MMIO_SCAN (0: no picture)
	// memory (the SDRAM; byte addresses of the CPU map, 0x10000000 = SDRAM 0)
	output reg m_cyc = 1'b0,
	output reg [29:0] m_adr = 30'd0,     // word address
	output reg [2:0] m_cti = 3'd0,
	input wire m_ack,
	input wire [31:0] m_dat,
	output wire vblank_sys,              // the vertical blank (clk side, for FRAME and the eZ80 PB1)
	output reg [1:0] omode = 2'd0,       // the output the firmware asks for (clk side; d[6]): 0 640x480@60,
	                                     // 1 640x400@70, 2 800x600@60, 3 1024x768@60 (the pixel clock follows)
	input wire [1:0] pmode,              // the output clk_pix runs now (from the clock switch, clk_pix side)
	output reg hneg = 1'b1,              // the sync polarities of pmode (VESA), clk_pix side
	output reg vneg = 1'b1,
	// the picture
	input wire clk_pix,
	output reg [1:0] r = 2'd0,
	output reg [1:0] g = 2'd0,
	output reg [1:0] b = 2'd0,
	output reg hs = 1'b0,
	output reg vs = 1'b0,
	output reg de = 1'b0
);

// ------------------------------------------------------------------ clk_pix: counters

// the timing of each output (VESA / VGA): visible, sync start, sync end, total; polarity
reg [10:0] h_act, h_ss, h_se, h_tot, v_act, v_ss, v_se, v_tot;
always @(posedge clk_pix) begin
	case (pmode)
	2'd0: begin h_act <= 11'd640;  h_ss <= 11'd656;  h_se <= 11'd752;  h_tot <= 11'd800;
	            v_act <= 11'd480;  v_ss <= 11'd490;  v_se <= 11'd492;  v_tot <= 11'd525; hneg <= 1'b1; vneg <= 1'b1; end
	2'd1: begin h_act <= 11'd640;  h_ss <= 11'd656;  h_se <= 11'd752;  h_tot <= 11'd800;
	            v_act <= 11'd400;  v_ss <= 11'd412;  v_se <= 11'd414;  v_tot <= 11'd449; hneg <= 1'b1; vneg <= 1'b0; end
	2'd2: begin h_act <= 11'd800;  h_ss <= 11'd840;  h_se <= 11'd968;  h_tot <= 11'd1056;
	            v_act <= 11'd600;  v_ss <= 11'd601;  v_se <= 11'd605;  v_tot <= 11'd628; hneg <= 1'b0; vneg <= 1'b0; end
	default: begin h_act <= 11'd1024; h_ss <= 11'd1048; h_se <= 11'd1184; h_tot <= 11'd1344;
	            v_act <= 11'd768;  v_ss <= 11'd771;  v_se <= 11'd777;  v_tot <= 11'd806; hneg <= 1'b1; vneg <= 1'b1; end
	endcase
end

reg [10:0] hc = 11'd0, vc = 11'd0;
reg row_tg = 1'b0;                     // toggles at the start of each row (hc 0)
always @(posedge clk_pix) begin
	if (hc >= h_tot - 11'd1) begin
		hc <= 11'd0;
		vc <= (vc >= v_tot - 11'd1) ? 11'd0 : vc + 11'd1;
	end else
		hc <= hc + 11'd1;
	if (hc == 11'd0) row_tg <= ~row_tg;
end

// ------------------------------------------------------------------ geometry (clk, quasi static)

reg [3:0] fmt = 4'd0;                  // 0 none, 1 2 colours, 2 4, 3 8, 4 16, 6 direct RGB222
reg [10:0] sw = 11'd0, sh = 11'd0;     // the source size
reg xsh = 1'b0, ysh = 1'b0;            // doubling
reg [10:0] x0 = 11'd0, y0 = 11'd0;     // the top left of the picture on the output (d[7])
reg [10:0] vw = 11'd0, vh = 11'd0;     // the visible output size (d[8])
reg [10:0] vact_c = 11'd480;           // the visible lines of pmode for the clk side (quasi static)
reg [24:0] rows_a = 25'd0, rowpal_a = 25'd0, pals_a = 25'd0;   // (SDRAM byte addresses: 32 MB)

// ------------------------------------------------------------------ line buffers (clk write, clk_pix read)

reg [5:0] lb [0:2047];                 // { buffer, x[9:0] }: two lines of up to 1024 RGB222 pixels
reg [10:0] lb_wa = 11'd0;
reg [5:0] lb_wd = 6'd0, lb_q = 6'd0;
reg lb_we = 1'b0;
always @(posedge clk) begin
	if (lb_we) lb[lb_wa] <= lb_wd;
	lb_q <= lb[lb_wa];                 // (the sprites XOR: read through the same port)
end

// ------------------------------------------------------------------ clk_pix: the picture

wire [10:0] ry = vc - y0;
wire [10:0] rx = hc - x0;
wire in_y = vc >= y0 && ry < vh;
wire in_x = hc >= x0 && rx < vw;
wire [10:0] sy = ysh ? { 1'b0, ry[10:1] } : ry;
wire [10:0] sx = xsh ? { 1'b0, rx[10:1] } : rx;
reg [5:0] px = 6'd0;
reg act1 = 1'b0, pic1 = 1'b0, hs1 = 1'b0, vs1 = 1'b0;
always @(posedge clk_pix) begin
	px <= lb[{ sy[0], sx[9:0] }];
	act1 <= hc < h_act && vc < v_act;
	pic1 <= in_x && in_y && fmt != 4'd0;
	hs1 <= hc >= h_ss && hc < h_se;
	vs1 <= vc >= v_ss && vc < v_se;
	de <= act1;
	hs <= hs1;
	vs <= vs1;
	{ b, g, r } <= pic1 ? px : 6'd0;
end

// ------------------------------------------------------------------ clk: row starts from clk_pix

reg [2:0] row_s = 3'd0;
always @(posedge clk) row_s <= { row_s[1:0], row_tg };
wire row_start = row_s[2] ^ row_s[1];
// vc is the new row already when the row start arrives here (it changed a clk_pix before the toggle)
// and stays for the whole row: read directly at row_start, then held in vc_s
reg [10:0] vc_s = 11'd0;
always @(posedge clk) if (row_start) begin vc_s <= vc; vact_c <= v_act; end
assign vblank_sys = vc_s >= vact_c;

// ------------------------------------------------------------------ clk: the fetch engine

localparam [3:0] S_IDLE = 4'd0, S_DESC = 4'd1, S_GEOM = 4'd2, S_ROW = 4'd3, S_RPAL = 4'd4, S_PAL = 4'd5,
	S_RAW = 4'd6, S_DEC = 4'd7, S_DEC2 = 4'd8, S_SLIST = 4'd9, S_SPR = 4'd10, S_SPH = 4'd11,
	S_SPM = 4'd12, S_SPF = 4'd13, S_SPX = 4'd14, S_SPW = 4'd15;
reg [3:0] st = S_IDLE;
reg [3:0] n = 4'd0;                    // words of the current access
reg [31:0] d5 = 32'd0, d6 = 32'd0;     // the sprite list, the output / doubling / bytes of a line
reg [31:0] d0 = 32'd0;
reg [10:0] line = 11'd0;               // the source line being made
reg [24:0] row_a = 25'd0;
reg [7:0] cur_p = 8'hff;               // the palette in pal[]
wire [7:0] rp_byte = m_dat >> { line[1:0], 3'b000 };   // the palette of the line (S_RPAL)
reg [5:0] pal [0:15];
reg [31:0] raw [0:271];                // the bytes of the line: 34 lines of 32 bytes
reg [8:0] raw_wa = 9'd0;
reg [10:0] nbytes = 11'd0;             // the bytes of a line
reg [24:0] fetch_a = 25'd0, fetch_end = 25'd0;
reg [10:0] x = 11'd0;                  // the pixel being decoded
reg [11:0] boff = 12'd0;               // byte offset of the row in raw[] (row_a & 31)
reg pend = 1'b0;                       // a line to make (pend_line)
reg [10:0] pend_line = 11'd0;
reg frame_pend = 1'b0;

// the sprites: the table (4 words each: xy, wh, address, flags), read at the frame start
reg spr_f = 1'b0;                      // S_RAW: the bytes of a sprite (then S_SPW)
reg [31:0] stbl [0:127];
reg [6:0] st_wa = 7'd0, st_ra = 7'd0;
reg [31:0] st_q = 32'd0;
reg st_we = 1'b0;
reg [31:0] st_wd = 32'd0;
always @(posedge clk) begin
	if (st_we) stbl[st_wa] <= st_wd;
	st_q <= stbl[st_ra];
end
reg [5:0] ns = 6'd0;                   // sprites in the table
reg [7:0] sl_n = 8'd0;                 // S_SLIST: words read
reg [4:0] si = 5'd0;                   // the sprite of the line
reg [2:0] sk = 3'd0;                   // S_SPR: words of its entry
// an entry (clipped by kg_scanout.cpp): its first line, lines, first x, pixels, the address of its
// first pixel, the bytes of its rows
reg [10:0] s_y = 11'd0, s_h = 11'd0, s_xs = 11'd0, s_dw = 11'd0, s_p = 11'd0, s_oy = 11'd0;
reg [24:0] s_da = 25'd0;
reg [15:0] s_st = 16'd0;
reg [1:0] s_fl = 2'd0;                 // bit 0 RGBA8888, bit 1 XOR
reg [24:0] s_prod = 25'd0;
reg [31:0] sw0 = 32'd0;                // the raw word of the pixel (S_SPW)
wire [11:0] s_ba = boff + (s_fl[0] ? { s_p[9:0], 2'b00 } : { 1'b0, s_p });
reg [1:0] s_bl = 2'd0;                 // the byte of the pixel in sw0 (s_ba[1:0], registered at phase 0)
wire [7:0] s_b8 = sw0 >> { s_bl, 3'b000 };
wire s_on = s_fl[0] ? sw0[31:24] != 8'd0 : s_b8[7:6] != 2'd0;
wire [5:0] s_rgb = s_fl[0] ? { sw0[23:22], sw0[15:14], sw0[7:6] } : s_b8[5:0];
wire s_stop = pend || frame_pend;      // a new line to make (or the frame): the sprites stop

// the next row: does it start a source line?
wire [10:0] nvc = (vc >= v_tot - 11'd1) ? 11'd0 : vc + 11'd1;   // (valid at row_start)
wire [10:0] nry = nvc - y0;
wire n_in = nvc >= y0 && nry < vh;
wire n_new = n_in && (!ysh || !nry[0]);
wire [10:0] n_line = ysh ? { 1'b0, nry[10:1] } : nry;

// decoding: the byte address of pixel x in raw[] and the pixel index
reg [11:0] dba;
always @(*) begin
	case (fmt)
	4'd1: dba = boff + { 4'd0, x[10:3] };
	4'd2: dba = boff + { 3'd0, x[10:2] };
	4'd3: dba = boff + { 4'd0, x[10:3] } * 12'd3;
	4'd4: dba = boff + { 2'd0, x[10:1] };
	default: dba = boff + { 1'b0, x[10:2], ~x[1], x[0] };   // fmt 6: the byte of pixel x is at x ^ 2
	endcase
end
// the decode is a pipeline of one pixel a clock (Ф2: 1024 pixels in the ~1550 clocks of a 1024 x 768
// row): S_DEC reads the raw words of pixel x, the next clock decodes them (xd, dlo: x and dba[1:0] of
// those words) into the line buffer
reg [31:0] rw0 = 32'd0, rw1 = 32'd0;   // raw words at dba >> 2 and the next one
reg [10:0] xd = 11'd0;
reg [1:0] dlo = 2'd0;
reg dv = 1'b0;                         // rw0 / rw1 hold pixel xd
reg [3:0] idx;
reg [23:0] v24;
always @(*) begin
	// the bytes from the two words (for fmt 3 three bytes may cross a word)
	v24 = { rw1, rw0 } >> { dlo, 3'b000 };
	case (fmt)
	4'd1: idx = { 3'd0, v24[7 - xd[2:0]] };
	4'd2: idx = { 2'd0, v24[7:0] >> (6 - { xd[1:0], 1'b0 }) } & 4'd3;
	4'd3: idx = (v24 >> (21 - xd[2:0] * 3)) & 24'd7;
	4'd4: idx = xd[0] ? v24[3:0] : v24[7:4];
	default: idx = 4'd0;
	endcase
end

always @(posedge clk) begin
	lb_we <= 1'b0;
	st_we <= 1'b0;
	if (row_start) begin
		if (vc == v_act && scan_adr != 32'd0) frame_pend <= 1'b1;     // the first blank row: the description
		if (n_new && fmt != 4'd0) begin pend <= 1'b1; pend_line <= n_line; end
	end
	if (reset) begin
		st <= S_IDLE; m_cyc <= 1'b0; fmt <= 4'd0; pend <= 1'b0; frame_pend <= 1'b0; cur_p <= 8'hff;
	end else case (st)
	S_IDLE:
		if (frame_pend) begin
			frame_pend <= 1'b0; pend <= 1'b0;
			st <= S_DESC; n <= 4'd0;
			m_cyc <= 1'b1; m_adr <= scan_adr[31:2]; m_cti <= 3'd0;
		end else if (pend) begin
			pend <= 1'b0; line <= pend_line;
			st <= S_ROW;
			m_cyc <= 1'b1; m_adr <= { 7'd0, rows_a[24:2] + { 12'd0, pend_line } }; m_cti <= 3'd0;
		end
	S_DESC:
		if (m_ack) begin
			case (n)
			4'd0: d0 <= m_dat;
			4'd1: sh <= m_dat[10:0];
			4'd2: rows_a <= m_dat[24:0];
			4'd3: rowpal_a <= m_dat[24:0];
			4'd4: pals_a <= m_dat[24:0];
			4'd5: d5 <= m_dat;
			4'd6: d6 <= m_dat;
			4'd7: begin x0 <= m_dat[10:0]; y0 <= m_dat[26:16]; end
			default: ;
			endcase
			n <= n + 4'd1;
			m_adr <= m_adr + 30'd1;
			if (n == 4'd8) begin
				vw <= m_dat[10:0]; vh <= m_dat[26:16];
				// the sprite list: its count, then the table
				ns <= 6'd0; sl_n <= 8'd0;
				if (d5 == 32'd0) begin m_cyc <= 1'b0; st <= S_GEOM; end
				else begin m_adr <= d5[31:2]; st <= S_SLIST; end
			end
		end
	S_SLIST:
		if (m_ack) begin
			sl_n <= sl_n + 8'd1;
			m_adr <= m_adr + 30'd1;
			if (sl_n == 8'd0) begin
				ns <= m_dat > 32'd32 ? 6'd32 : m_dat[5:0];
				if (m_dat == 32'd0) begin m_cyc <= 1'b0; st <= S_GEOM; end
			end else begin
				st_we <= 1'b1; st_wa <= sl_n[6:0] - 7'd1; st_wd <= m_dat;
				if (sl_n == { ns, 2'b00 }) begin m_cyc <= 1'b0; st <= S_GEOM; end
			end
		end
	S_GEOM: begin
		fmt <= (d0[3:0] >= 4'd1 && d0[3:0] <= 4'd4) || d0[3:0] == 4'd6 ? d0[3:0] : 4'd0;
		sw <= d0[26:16];
		// the geometry comes made (kg_scanout.cpp d[6..8]: Ф2)
		xsh <= d6[2];
		ysh <= d6[3];
		nbytes <= d6[26:16];
		omode <= d6[1:0];
		cur_p <= 8'hff;
		st <= S_IDLE;
	end
	S_ROW:
		if (m_ack) begin
			row_a <= m_dat[24:0];
			m_adr <= { 7'd0, rowpal_a[24:2] + { 14'd0, line[10:2] } };
			st <= S_RPAL;
		end
	S_RPAL:
		if (m_ack) begin
			if (fmt != 4'd6 && rp_byte != cur_p) begin
				cur_p <= rp_byte;
				m_adr <= { 7'd0, pals_a[24:2] + { 13'd0, rp_byte, 2'b00 } };
				n <= 3'd0;
				st <= S_PAL;
			end else begin
				m_adr <= { 7'd0, row_a[24:5], 3'b000 };
				m_cti <= 3'b010; n <= 3'd0; raw_wa <= 9'd0;
				fetch_a <= { row_a[24:5], 5'd0 };
				fetch_end <= row_a + { 14'd0, nbytes } + 25'd4; spr_f <= 1'b0;
				boff <= { 7'd0, row_a[4:0] };
				st <= S_RAW;
			end
		end
	S_PAL:
		if (m_ack) begin
			pal[{ n[1:0], 2'd0 }] <= m_dat[5:0];
			pal[{ n[1:0], 2'd1 }] <= m_dat[13:8];
			pal[{ n[1:0], 2'd2 }] <= m_dat[21:16];
			pal[{ n[1:0], 2'd3 }] <= m_dat[29:24];
			n <= n + 3'd1;
			m_adr <= m_adr + 30'd1;
			if (n == 3'd3) begin
				m_adr <= { 7'd0, row_a[24:5], 3'b000 };
				m_cti <= 3'b010; n <= 3'd0; raw_wa <= 9'd0;
				fetch_a <= { row_a[24:5], 5'd0 };
				fetch_end <= row_a + { 14'd0, nbytes } + 25'd4; spr_f <= 1'b0;
				boff <= { 7'd0, row_a[4:0] };
				st <= S_RAW;
			end
		end
	S_RAW:
		if (m_ack) begin
			raw[raw_wa] <= m_dat;
			raw_wa <= raw_wa + 9'd1;
			n <= n + 3'd1;
			m_adr <= m_adr + 30'd1;
			if (n == 3'd6) m_cti <= 3'b111;                     // the last word of the burst next
			if (n == 3'd7) begin
				fetch_a <= fetch_a + 25'd32;
				m_cti <= 3'b010;
				if (fetch_a + 25'd32 >= fetch_end) begin
					m_cyc <= 1'b0; x <= 11'd0; s_p <= 11'd0; dv <= 1'b0; st <= spr_f ? S_SPW : S_DEC;
				end
			end
		end
	S_DEC: begin
		// pixel x: its two raw words (registered); pixel xd of the clock before: decoded
		dv <= x < sw;
		if (x < sw) begin
			rw0 <= raw[dba >> 2];
			rw1 <= raw[(dba >> 2) + 12'd1];
			xd <= x; dlo <= dba[1:0];
			x <= x + 11'd1;
		end
		if (dv) begin
			lb_we <= 1'b1;
			lb_wa <= { line[0], xd[9:0] };
			lb_wd <= fmt == 4'd6 ? v24[5:0] : pal[idx];
		end
		if (x >= sw && !dv) begin
			si <= 5'd0; sk <= 3'd0; st_ra <= 7'd0;
			st <= ns != 6'd0 ? S_SPR : S_IDLE;
		end
	end
	// ---- the sprites of the line
	S_SPR: begin
		// the entry of sprite si: st_ra runs ahead, st_q a clock later
		sk <= sk + 3'd1;
		st_ra <= { si, 2'b00 } + { 4'd0, sk } + 7'd1;
		case (sk)
		3'd1: begin s_y <= st_q[10:0]; s_h <= st_q[26:16]; end
		3'd2: begin s_xs <= st_q[10:0]; s_dw <= st_q[26:16]; end
		3'd3: s_da <= st_q[24:0];
		3'd4: begin s_st <= st_q[15:0]; s_fl <= st_q[17:16]; st <= S_SPH; end
		default: ;
		endcase
	end
	S_SPH: begin
		// on this line?
		s_oy <= line - s_y;
		st <= line >= s_y && line - s_y < s_h ? S_SPM : S_SPX;
	end
	S_SPM: begin
		s_prod <= s_oy * s_st;
		st <= S_SPF;
	end
	S_SPF:
		// the bytes s_da + s_oy * s_st .. + (s_dw << bpp) into raw[] (S_RAW, then S_SPW)
		begin : sa
			reg [24:0] a;
			a = s_da + s_prod;
			m_cyc <= 1'b1; m_adr <= { 7'd0, a[24:5], 3'b000 }; m_cti <= 3'b010; n <= 3'd0; raw_wa <= 9'd0;
			fetch_a <= { a[24:5], 5'd0 };
			fetch_end <= a + (s_fl[0] ? { 12'd0, s_dw, 2'b00 } : { 14'd0, s_dw });
			boff <= { 7'd0, a[4:0] };
			spr_f <= 1'b1;
			st <= S_RAW;
		end
	S_SPW: begin
		// a pixel in 3 clocks (x: 0 address, 1 the reads, 2 the write)
		x <= x + 11'd1;
		case (x[1:0])
		2'd0: begin
			if (s_stop) st <= S_IDLE;
			sw0 <= raw[s_ba >> 2];
			s_bl <= s_ba[1:0];
			lb_wa <= { line[0], s_xs[9:0] + s_p[9:0] };
		end
		2'd1: ;
		default: begin
			x <= 11'd0;
			if (s_on) begin
				lb_we <= 1'b1;
				lb_wd <= s_fl[1] ? lb_q ^ s_rgb : s_rgb;
			end
			s_p <= s_p + 11'd1;
			if (s_p + 11'd1 >= s_dw) st <= S_SPX;
		end
		endcase
	end
	S_SPX: begin
		// the next sprite
		sk <= 3'd0; st_ra <= { si + 5'd1, 2'b00 };
		si <= si + 5'd1;
		st <= (s_stop || { 1'b0, si } + 6'd1 >= ns) ? S_IDLE : S_SPR;
	end
	default: st <= S_IDLE;
	endcase
end

endmodule
