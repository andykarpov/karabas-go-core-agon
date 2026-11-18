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

reg [9:0] hc = 10'd0, vc = 10'd0;
reg row_tg = 1'b0;                     // toggles at the start of each row (hc 0)
always @(posedge clk_pix) begin
	if (hc == 10'd799) begin
		hc <= 10'd0;
		vc <= (vc == 10'd524) ? 10'd0 : vc + 10'd1;
	end else
		hc <= hc + 10'd1;
	if (hc == 10'd0) row_tg <= ~row_tg;
end

// ------------------------------------------------------------------ geometry (clk, quasi static)

reg [3:0] fmt = 4'd0;                  // 0 none, 1 2 colours, 2 4, 3 8, 4 16, 6 direct RGB222
reg [10:0] sw = 11'd0, sh = 11'd0;     // the source size
reg xsh = 1'b0, ysh = 1'b0;            // doubling
reg [9:0] x0 = 10'd0, y0 = 10'd0;      // the top left of the picture on the output
reg [10:0] vw = 11'd0, vh = 11'd0;     // the visible output size (cropped to 640 x 480)
reg [31:0] rows_a = 32'd0, rowpal_a = 32'd0, pals_a = 32'd0;

// ------------------------------------------------------------------ line buffers (clk write, clk_pix read)

reg [5:0] lb [0:2047];                 // { buffer, x[9:0] }: two lines of up to 1024 RGB222 pixels
reg [10:0] lb_wa = 11'd0;
reg [5:0] lb_wd = 6'd0;
reg lb_we = 1'b0;
always @(posedge clk) if (lb_we) lb[lb_wa] <= lb_wd;

// ------------------------------------------------------------------ clk_pix: the picture

wire [10:0] ry = { 1'b0, vc } - { 1'b0, y0 };
wire [10:0] rx = { 1'b0, hc } - { 1'b0, x0 };
wire in_y = vc >= y0 && ry < vh;
wire in_x = hc >= x0 && rx < vw;
wire [10:0] sy = ysh ? { 1'b0, ry[10:1] } : ry;
wire [10:0] sx = xsh ? { 1'b0, rx[10:1] } : rx;
reg [5:0] px = 6'd0;
reg act1 = 1'b0, pic1 = 1'b0, hs1 = 1'b0, vs1 = 1'b0;
always @(posedge clk_pix) begin
	px <= lb[{ sy[0], sx[9:0] }];
	act1 <= hc < 10'd640 && vc < 10'd480;
	pic1 <= in_x && in_y && fmt != 4'd0;
	hs1 <= hc >= 10'd656 && hc < 10'd752;
	vs1 <= vc >= 10'd490 && vc < 10'd492;
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
reg [9:0] vc_s = 10'd0;
always @(posedge clk) if (row_start) vc_s <= vc;
assign vblank_sys = vc_s >= 10'd480;

// ------------------------------------------------------------------ clk: the fetch engine

localparam [3:0] S_IDLE = 4'd0, S_DESC = 4'd1, S_GEOM = 4'd2, S_ROW = 4'd3, S_RPAL = 4'd4, S_PAL = 4'd5,
	S_RAW = 4'd6, S_DEC = 4'd7, S_DEC2 = 4'd8;
reg [3:0] st = S_IDLE;
reg [2:0] n = 3'd0;                    // words of the current access
reg [31:0] d0 = 32'd0;
reg [10:0] line = 11'd0;               // the source line being made
reg [31:0] row_a = 32'd0;
reg [7:0] cur_p = 8'hff;               // the palette in pal[]
wire [7:0] rp_byte = m_dat >> { line[1:0], 3'b000 };   // the palette of the line (S_RPAL)
reg [5:0] pal [0:15];
reg [31:0] raw [0:271];                // the bytes of the line: 34 lines of 32 bytes
reg [8:0] raw_wa = 9'd0;
reg [10:0] nbytes = 11'd0;             // the bytes of a line
reg [31:0] fetch_a = 32'd0, fetch_end = 32'd0;
reg [10:0] x = 11'd0;                  // the pixel being decoded
reg [11:0] boff = 12'd0;               // byte offset of the row in raw[] (row_a & 31)
reg pend = 1'b0;                       // a line to make (pend_line)
reg [10:0] pend_line = 11'd0;
reg frame_pend = 1'b0;

// the next row: does it start a source line?
wire [10:0] nvc = (vc == 10'd524) ? 11'd0 : { 1'b0, vc } + 11'd1;   // (valid at row_start)
wire [10:0] nry = nvc - { 1'b0, y0 };
wire n_in = nvc >= { 1'b0, y0 } && nry < vh;
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
reg [31:0] rw0 = 32'd0, rw1 = 32'd0;   // raw words at dba >> 2 and the next one
reg [3:0] idx;
reg [23:0] v24;
always @(*) begin
	// the bytes from the two words (for fmt 3 three bytes may cross a word)
	v24 = { rw1, rw0 } >> { dba[1:0], 3'b000 };
	case (fmt)
	4'd1: idx = { 3'd0, v24[7 - x[2:0]] };
	4'd2: idx = { 2'd0, v24[7:0] >> (6 - { x[1:0], 1'b0 }) } & 4'd3;
	4'd3: idx = (v24 >> (21 - x[2:0] * 3)) & 24'd7;
	4'd4: idx = x[0] ? v24[3:0] : v24[7:4];
	default: idx = 4'd0;
	endcase
end

always @(posedge clk) begin
	lb_we <= 1'b0;
	if (row_start) begin
		if (vc == 10'd480 && scan_adr != 32'd0) frame_pend <= 1'b1;     // row 480 starts: the description
		if (n_new && fmt != 4'd0) begin pend <= 1'b1; pend_line <= n_line; end
	end
	if (reset) begin
		st <= S_IDLE; m_cyc <= 1'b0; fmt <= 4'd0; pend <= 1'b0; frame_pend <= 1'b0; cur_p <= 8'hff;
	end else case (st)
	S_IDLE:
		if (frame_pend) begin
			frame_pend <= 1'b0; pend <= 1'b0;
			st <= S_DESC; n <= 3'd0;
			m_cyc <= 1'b1; m_adr <= scan_adr[31:2]; m_cti <= 3'd0;
		end else if (pend) begin
			pend <= 1'b0; line <= pend_line;
			st <= S_ROW;
			m_cyc <= 1'b1; m_adr <= rows_a[31:2] + { 19'd0, pend_line }; m_cti <= 3'd0;
		end
	S_DESC:
		if (m_ack) begin
			case (n)
			3'd0: d0 <= m_dat;
			3'd1: sh <= m_dat[10:0];
			3'd2: rows_a <= m_dat;
			3'd3: rowpal_a <= m_dat;
			default: pals_a <= m_dat;
			endcase
			n <= n + 3'd1;
			m_adr <= m_adr + 30'd1;
			if (n == 3'd4) begin m_cyc <= 1'b0; st <= S_GEOM; end
		end
	S_GEOM: begin
		fmt <= (d0[3:0] >= 4'd1 && d0[3:0] <= 4'd4) || d0[3:0] == 4'd6 ? d0[3:0] : 4'd0;
		sw <= d0[26:16];
		xsh <= d0[26:16] <= 11'd320;
		ysh <= sh <= 11'd240;
		begin : geo
			reg [11:0] dw, dh;
			dw = d0[26:16] <= 11'd320 ? { d0[26:16], 1'b0 } : { 1'b0, d0[26:16] };
			dh = sh <= 11'd240 ? { sh, 1'b0 } : { 1'b0, sh };
			vw <= dw > 12'd640 ? 11'd640 : dw[10:0];
			vh <= dh > 12'd480 ? 11'd480 : dh[10:0];
			x0 <= dw >= 12'd640 ? 10'd0 : (12'd640 - dw) >> 1;
			y0 <= dh >= 12'd480 ? 10'd0 : (12'd480 - dh) >> 1;
		end
		case (d0[3:0])
		4'd1: nbytes <= (d0[26:16] + 11'd7) >> 3;
		4'd2: nbytes <= (d0[26:16] + 11'd3) >> 2;
		4'd3: nbytes <= ((d0[26:16] + 11'd7) >> 3) * 11'd3;
		4'd4: nbytes <= (d0[26:16] + 11'd1) >> 1;
		default: nbytes <= d0[26:16];
		endcase
		cur_p <= 8'hff;
		st <= S_IDLE;
	end
	S_ROW:
		if (m_ack) begin
			row_a <= m_dat;
			m_adr <= rowpal_a[31:2] + { 21'd0, line[10:2] };
			st <= S_RPAL;
		end
	S_RPAL:
		if (m_ack) begin
			if (fmt != 4'd6 && rp_byte != cur_p) begin
				cur_p <= rp_byte;
				m_adr <= pals_a[31:2] + { 20'd0, rp_byte, 2'b00 };
				n <= 3'd0;
				st <= S_PAL;
			end else begin
				m_adr <= { row_a[31:5], 3'b000 };
				m_cti <= 3'b010; n <= 3'd0; raw_wa <= 9'd0;
				fetch_a <= { row_a[31:5], 5'd0 };
				fetch_end <= row_a + { 21'd0, nbytes } + 32'd4;
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
				m_adr <= { row_a[31:5], 3'b000 };
				m_cti <= 3'b010; n <= 3'd0; raw_wa <= 9'd0;
				fetch_a <= { row_a[31:5], 5'd0 };
				fetch_end <= row_a + { 21'd0, nbytes } + 32'd4;
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
				fetch_a <= fetch_a + 32'd32;
				m_cti <= 3'b010;
				if (fetch_a + 32'd32 >= fetch_end) begin
					m_cyc <= 1'b0; x <= 11'd0; st <= S_DEC;
				end
			end
		end
	S_DEC: begin
		// read the two raw words of pixel x (registered: S_DEC2 has them)
		rw0 <= raw[dba >> 2];
		rw1 <= raw[(dba >> 2) + 12'd1];
		st <= S_DEC2;
	end
	S_DEC2: begin
		lb_we <= 1'b1;
		lb_wa <= { line[0], x[9:0] };
		lb_wd <= fmt == 4'd6 ? v24[5:0] : pal[idx];
		if (x + 11'd1 >= sw) st <= S_IDLE;
		else begin x <= x + 11'd1; st <= S_DEC; end
	end
	default: st <= S_IDLE;
	endcase
end

endmodule
